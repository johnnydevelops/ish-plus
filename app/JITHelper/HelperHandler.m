//
//  HelperHandler.m
//  iSH+ helper extension
//
//  The extension's two jobs: enabling JIT (JITHelperHandler.swift), and
//  donating memory. A process's memory counts toward its own limit, which
//  iOS ends it for, so iSH+ starts this extension (it has a limit of its
//  own) to allocate Linux's RAM; iSH+ maps that memory, then ends the
//  extension, after which the memory counts toward neither (see RamDonor.m).
//
//  The memory donor technique is MeloNX's (Stossy11, MIT License):
//  https://starforgejo.dev/projects/MeloNX
//
//  A donor request's NSExtensionItem.userInfo["ishplus-donor-endpoint"] is an
//  NSXPCListenerEndpoint wrapping an XPC endpoint of iSH+'s; the donor
//  connects to it, says hello, then answers:
//      { op: "available" }            -> { available: bytes it may allocate }
//      { op: "create", size: bytes }  -> { shmem: the memory } or { error }
//

#import <Foundation/Foundation.h>
#import <mach/mach.h>
#import <objc/runtime.h>
#import <os/proc.h>
#import <xpc/xpc.h>

extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address,
                                      mach_vm_size_t size, int flags);

static NSString *const kDonorEndpointKey = @"ishplus-donor-endpoint";

@interface NSXPCListenerEndpoint (ISHPrivate)
@property (nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end

// Extension requests are decoded with an allow list that NSXPCListenerEndpoint
// is not on, so a donor request would arrive without its endpoint: allow it.
__attribute__((constructor))
static void ISHAllowEndpointDecoding(void) {
    Class decoder = NSClassFromString(@"NSXPCDecoder");
    SEL selector = NSSelectorFromString(@"_validateAllowedClass:forKey:allowingInvocations:");
    Method method = class_getInstanceMethod(decoder, selector);
    if (method == NULL) {
        NSLog(@"[iSH+ donor] NSXPCDecoder's class check not found");
        return;
    }
    typedef BOOL (*Validate)(id, SEL, Class, id, BOOL);
    Validate original = (Validate)method_getImplementation(method);
    method_setImplementation(method, imp_implementationWithBlock(^BOOL(id decoder, Class class, id key, BOOL invocations) {
        if (class == NSXPCListenerEndpoint.class)
            return YES;
        return original(decoder, selector, class, key, invocations);
    }));
}

#pragma mark - Donor

@interface ISHRamDonorService : NSObject
@property (nonatomic) xpc_connection_t connection;
@end

@implementation ISHRamDonorService

static ISHRamDonorService *donorService; // lives as long as the process

+ (BOOL)beginRequest:(NSExtensionContext *)context {
    NSExtensionItem *item = context.inputItems.firstObject;
    id wrapper = item.userInfo[kDonorEndpointKey];
    if (wrapper == nil)
        return NO;
    xpc_object_t endpoint = [wrapper isKindOfClass:NSXPCListenerEndpoint.class] ? [wrapper _endpoint] : nil;
    if (endpoint == nil || xpc_get_type(endpoint) != XPC_TYPE_ENDPOINT) {
        NSLog(@"[iSH+ donor] the request has no usable endpoint (%@)", [wrapper class]);
        return YES;
    }
    donorService = [ISHRamDonorService new];
    [donorService connect:endpoint];
    return YES;
}

- (void)connect:(xpc_object_t)endpoint {
    xpc_connection_t connection = xpc_connection_create_from_endpoint(endpoint);
    self.connection = connection;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR) {
            // iSH+ went away: nothing left to donate to
            exit(0);
        }
        [self handle:event];
    });
    xpc_connection_resume(connection);
    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(hello, "op", "hello");
    xpc_dictionary_set_int64(hello, "pid", getpid());
    xpc_connection_send_message(connection, hello);
    NSLog(@"[iSH+ donor] ready, pid %d, %zu MB available", getpid(), os_proc_available_memory() >> 20);
}

- (void)handle:(xpc_object_t)message {
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY)
        return;
    const char *op = xpc_dictionary_get_string(message, "op");
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (op == NULL || reply == NULL)
        return;
    if (strcmp(op, "available") == 0) {
        xpc_dictionary_set_uint64(reply, "available", os_proc_available_memory());
    } else if (strcmp(op, "create") == 0) {
        uint64_t size = xpc_dictionary_get_uint64(message, "size");
        mach_vm_address_t address = 0;
        // Purgeable (nonvolatile) memory has an owner, this process, whose
        // footprint it counts toward; once this process ends, nobody's.
        kern_return_t kr = size ? mach_vm_allocate(mach_task_self(), &address, size,
                                                   VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE) : KERN_INVALID_ARGUMENT;
        xpc_object_t shmem = kr == KERN_SUCCESS ? xpc_shmem_create((void *) address, size) : NULL;
        if (shmem) {
            xpc_dictionary_set_value(reply, "shmem", shmem);
        } else {
            xpc_dictionary_set_string(reply, "error", kr == KERN_SUCCESS ? "xpc_shmem_create failed" : mach_error_string(kr));
        }
    } else {
        xpc_dictionary_set_string(reply, "error", "unknown operation");
    }
    xpc_connection_send_message(self.connection, reply);
}

@end

#pragma mark - Principal class

@interface ISHHelperHandler : NSObject <NSExtensionRequestHandling>
@property (nonatomic) id jitHandler;
@end

@implementation ISHHelperHandler

- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    if ([ISHRamDonorService beginRequest:context])
        return;
    self.jitHandler = [NSClassFromString(@"ISHJITHelperHandler") new];
    [self.jitHandler beginRequestWithExtensionContext:context];
}

@end
