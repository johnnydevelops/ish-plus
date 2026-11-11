//
//  RamDonor.m
//  iSH+
//
//  Linux's RAM from memory donors (MeloNX's technique, by Stossy11, MIT
//  License: https://starforgejo.dev/projects/MeloNX).
//
//  iOS ends a process whose memory footprint passes its limit. iSH+ starts
//  its helper extension as donors: each is its own process with its own
//  limit, allocates purgeable memory (which counts toward its owner) and
//  shares it with iSH+ over XPC. iSH+ maps it where QEMU wants Linux's RAM,
//  then ends the donors: the memory stays mapped in iSH+ and, its owner gone,
//  counts toward no process's limit. iOS can still reclaim it under memory
//  pressure by ending iSH+, as with any app's memory.
//
//  Whatever the donors cannot cover stays ordinary memory of iSH+'s.
//

#import "RamDonor.h"
#import <dlfcn.h>
#import <mach/mach.h>
#import <signal.h>
#import <xpc/xpc.h>

extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address,
                                      mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address,
                                        mach_vm_size_t size);
extern kern_return_t mach_vm_remap(vm_map_t target, mach_vm_address_t *address,
                                   mach_vm_size_t size, mach_vm_offset_t mask, int flags,
                                   vm_map_t source, mach_vm_address_t sourceAddress,
                                   boolean_t copy, vm_prot_t *currentProtection,
                                   vm_prot_t *maxProtection, vm_inherit_t inheritance);

#ifndef VM_FLAGS_OVERWRITE
#define VM_FLAGS_OVERWRITE 0x4000
#endif

// Shares are asked for in chunks, each a separate memory object
static const uint64_t kChunk = 256ull << 20;
// What each donor keeps for itself below its limit
static const uint64_t kHeadroom = 128ull << 20;
static const int kMaxDonors = 6;
static const NSTimeInterval kTimeout = 10;

static NSString *const kHelperFile = @"iSHJITHelper.appex";
static NSString *const kDonorEndpointKey = @"ishplus-donor-endpoint";
// QEMU's name for the virt machine's main RAM
static const char *const kMainRAM = "mach-virt.ram";

@interface NSObject (ISHPrivateNSExtension)
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)inputItems completion:(void (^)(NSUUID *requestIdentifier))completion;
- (int)pidForRequestIdentifier:(NSUUID *)identifier;
- (void)_kill:(int)signal;
@end

@interface NSXPCListenerEndpoint (ISHPrivate)
@property (nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end

static NSString *gStatus;
static void vmLog(NSString *line) {
    fprintf(stderr, "[%s] iSH+: %s\n", NSDate.date.description.UTF8String, line.UTF8String);
}

#pragma mark - Donors

@interface ISHDonors : NSObject
@property (nonatomic) xpc_connection_t listener;
@property (nonatomic) dispatch_queue_t queue;
@property (nonatomic) NSMutableArray *extensions;
@property (nonatomic) NSMutableArray *connections; // hello received
@property (nonatomic) dispatch_semaphore_t arrived;
@end

@implementation ISHDonors

- (instancetype)init {
    self = [super init];
    _queue = dispatch_queue_create("app.ishplus.ram-donors", DISPATCH_QUEUE_SERIAL);
    _extensions = [NSMutableArray array];
    _connections = [NSMutableArray array];
    _arrived = dispatch_semaphore_create(0);
    _listener = xpc_connection_create(NULL, _queue);
    __weak ISHDonors *weakSelf = self;
    xpc_connection_set_event_handler(_listener, ^(xpc_object_t peer) {
        if (xpc_get_type(peer) != XPC_TYPE_CONNECTION)
            return;
        xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
            if (xpc_get_type(message) == XPC_TYPE_DICTIONARY &&
                strcmp(xpc_dictionary_get_string(message, "op") ?: "", "hello") == 0) {
                vmLog([NSString stringWithFormat:@"memory donor pid %lld connected",
                       xpc_dictionary_get_int64(message, "pid")]);
                [weakSelf.connections addObject:peer];
                dispatch_semaphore_signal(weakSelf.arrived);
            }
        });
        xpc_connection_resume(peer);
    });
    xpc_connection_resume(_listener);
    return self;
}

/// Starts one more donor; its connection, or nil.
- (nullable xpc_connection_t)startDonor {
    NSURL *url = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:kHelperFile];
    NSString *identifier = [NSBundle bundleWithURL:url].bundleIdentifier;
    if (identifier == nil) {
        vmLog(@"memory donors: the helper extension is missing");
        return nil;
    }
    dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
    NSError *error = nil;
    id extension = [NSClassFromString(@"NSExtension") extensionWithIdentifier:identifier error:&error];
    if (extension == nil) {
        vmLog([NSString stringWithFormat:@"memory donors: %@", error.localizedDescription]);
        return nil;
    }
    NSXPCListenerEndpoint *wrapper = [NSXPCListenerEndpoint new];
    wrapper._endpoint = xpc_endpoint_create(self.listener);
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{kDonorEndpointKey: wrapper};

    __block NSUInteger before;
    dispatch_sync(self.queue, ^{ before = self.connections.count; });
    [self.extensions addObject:extension];
    [extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *uuid) {
        if (uuid == nil)
            vmLog(@"memory donors: the extension request was refused");
        else
            vmLog([NSString stringWithFormat:@"memory donor started, pid %d",
                   [extension pidForRequestIdentifier:uuid]]);
    }];
    if (dispatch_semaphore_wait(self.arrived, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTimeout * NSEC_PER_SEC))) != 0) {
        vmLog(@"memory donors: a donor did not connect in time");
        return nil;
    }
    __block xpc_connection_t connection = nil;
    dispatch_sync(self.queue, ^{
        if (self.connections.count > before)
            connection = self.connections.lastObject;
    });
    return connection;
}

- (nullable xpc_object_t)send:(xpc_object_t)request to:(xpc_connection_t)donor {
    __block xpc_object_t answer = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    xpc_connection_send_message_with_reply(donor, request, self.queue, ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_DICTIONARY)
            answer = reply;
        dispatch_semaphore_signal(done);
    });
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC))) != 0)
        return nil;
    return answer;
}

- (uint64_t)availableIn:(xpc_connection_t)donor {
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "op", "available");
    xpc_object_t reply = [self send:request to:donor];
    return reply ? xpc_dictionary_get_uint64(reply, "available") : 0;
}

/// Maps `length` bytes of a donor's memory at `target`, replacing what is there.
- (BOOL)map:(uint64_t)length from:(xpc_connection_t)donor at:(mach_vm_address_t)target {
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(request, "op", "create");
    xpc_dictionary_set_uint64(request, "size", length);
    xpc_object_t reply = [self send:request to:donor];
    xpc_object_t shmem = reply ? xpc_dictionary_get_value(reply, "shmem") : nil;
    if (shmem == nil || xpc_get_type(shmem) != XPC_TYPE_SHMEM) {
        const char *error = reply ? xpc_dictionary_get_string(reply, "error") : "no answer";
        vmLog([NSString stringWithFormat:@"memory donors: no memory from a donor: %s", error ?: "?"]);
        return NO;
    }
    void *mapped = NULL;
    size_t size = xpc_shmem_map(shmem, &mapped);
    if (mapped == NULL || size < length) {
        if (mapped)
            mach_vm_deallocate(mach_task_self(), (mach_vm_address_t) mapped, size);
        return NO;
    }
    vm_prot_t current, maximum;
    mach_vm_address_t address = target;
    kern_return_t kr = mach_vm_remap(mach_task_self(), &address, length, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE,
                                     mach_task_self(), (mach_vm_address_t) mapped, FALSE,
                                     &current, &maximum, VM_INHERIT_NONE);
    mach_vm_deallocate(mach_task_self(), (mach_vm_address_t) mapped, size);
    if (kr != KERN_SUCCESS) {
        vmLog([NSString stringWithFormat:@"memory donors: remap failed: %s", mach_error_string(kr)]);
        return NO;
    }
    return YES;
}

/// Ends the donors: their memory stays mapped here, and counts toward no one.
- (void)end {
    for (id extension in self.extensions) {
        if ([extension respondsToSelector:@selector(_kill:)])
            [extension _kill:SIGKILL];
    }
    [self.extensions removeAllObjects];
    xpc_connection_cancel(self.listener);
}

@end

#pragma mark - Linux's RAM

// Aligned for QEMU's RAM (QEMU_VMALLOC_ALIGN is at most 2 MB)
static const uint64_t kAlign = 2ull << 20;
static mach_vm_address_t gBase;
static uint64_t gSize;

uint64_t ISHRamDonorPrepare(uint64_t bytes) {
    if (gBase != 0 || bytes == 0)
        return 0;
    // An aligned range of ordinary memory first (reserved, not yet used);
    // donated chunks replace it from the start.
    mach_vm_address_t reserved = 0;
    if (mach_vm_allocate(mach_task_self(), &reserved, bytes + kAlign, VM_FLAGS_ANYWHERE) != KERN_SUCCESS)
        return 0;
    mach_vm_address_t base = (reserved + kAlign - 1) & ~(kAlign - 1);
    if (base > reserved)
        mach_vm_deallocate(mach_task_self(), reserved, base - reserved);
    if (reserved + kAlign > base)
        mach_vm_deallocate(mach_task_self(), base + bytes, reserved + kAlign - base);

    NSDate *start = NSDate.date;
    ISHDonors *donors = [ISHDonors new];
    uint64_t offset = 0;
    int count = 0;
    while (offset < bytes && count < kMaxDonors) {
        xpc_connection_t donor = [donors startDonor];
        if (donor == nil)
            break;
        count++;
        uint64_t available = [donors availableIn:donor];
        uint64_t budget = available > kHeadroom ? available - kHeadroom : 0;
        vmLog([NSString stringWithFormat:@"memory donor %d may allocate %llu MB", count, available >> 20]);
        while (offset < bytes && budget > 0) {
            uint64_t length = MIN(MIN(kChunk, bytes - offset), budget);
            length &= ~((uint64_t) vm_page_size - 1);
            if (length == 0 || ![donors map:length from:donor at:base + offset])
                break;
            offset += length;
            budget -= length;
        }
        if (budget > 0 && offset < bytes)
            break; // this donor failed early; more would too
    }
    [donors end];
    gBase = base;
    gSize = bytes;
    gStatus = offset ? [NSString stringWithFormat:@"%llu of %llu MB from %d donor%s", offset >> 20, bytes >> 20,
                        count, count == 1 ? "" : "s"]
                     : @"no memory donated";
    vmLog([NSString stringWithFormat:@"Linux's RAM: %@ (%.1f s)", gStatus, -start.timeIntervalSinceNow]);
    return offset;
}

static void *ProvideRAM(const char *name, uint64_t size, uint64_t align) {
    if (strcmp(name, kMainRAM) != 0 || gBase == 0 || size > gSize || align > kAlign || gBase % align != 0)
        return NULL;
    if (size < gSize)
        mach_vm_deallocate(mach_task_self(), gBase + size, gSize - size);
    mach_vm_address_t base = gBase;
    gBase = 0; // QEMU's now
    return (void *) base;
}

void ISHRamDonorInstall(void *qemuHandle) {
    typedef void (*SetProvider)(void *(*)(const char *, uint64_t, uint64_t));
    SetProvider setProvider = (SetProvider) dlsym(qemuHandle, "ishplus_ram_set_provider");
    if (setProvider == NULL) {
        vmLog(@"memory donors: this QEMU cannot use them");
        return;
    }
    setProvider(ProvideRAM);
}

NSString *ISHRamDonorStatus(void) {
    return gStatus;
}
