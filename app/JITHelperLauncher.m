//
//  JITHelperLauncher.m
//  iSH+
//
//  Uses NSExtension, the (private) API behind app extensions, to start the
//  helper by bundle identifier and send it a request, as Madeira does.
//

#import "JITHelperLauncher.h"
#import <dlfcn.h>
#import <unistd.h>
#import <signal.h>

@interface NSObject (ISHPrivateNSExtension)
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)inputItems completion:(void (^)(NSUUID *requestIdentifier))completion;
- (void)setRequestCompletionBlock:(void (^)(NSUUID *requestIdentifier, NSArray *extensionItems))block;
- (void)setRequestCancellationBlock:(void (^)(NSUUID *requestIdentifier, NSError *error))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID *requestIdentifier))block;
- (void)_kill:(int)signal;
@end

static NSString *const kHelperFile = @"iSHJITHelper.appex";
static NSString *const kRequestKey = @"ishplus-jit-request";
static NSString *const kResponseKey = @"ishplus-jit-response";

@implementation ISHJITHelperLauncher

static id currentExtension; // keep the extension alive while it works

+ (NSString *)helperIdentifier {
    NSURL *url = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:kHelperFile];
    return [NSBundle bundleWithURL:url].bundleIdentifier;
}

+ (BOOL)available {
    return [self helperIdentifier] != nil;
}

+ (void)enableJITWithPairingData:(NSData *)pairing
                      completion:(void (^)(NSString *, NSArray<NSString *> *))completion {
    void (^finish)(NSString *, NSArray *) = ^(NSString *error, NSArray *log) {
        // In qemu.log (stderr) once the VM runs
        fprintf(stderr, "[%s] iSH+: JIT helper finished: %s (%s)\n", NSDate.date.description.UTF8String,
                error ? error.UTF8String : "ok", [log componentsJoinedByString:@" | "].UTF8String ?: "");
        dispatch_async(dispatch_get_main_queue(), ^{
            // The helper is done (it detached): end its process, which iOS
            // would otherwise keep around idle
            if ([currentExtension respondsToSelector:@selector(_kill:)])
                [currentExtension _kill:SIGKILL];
            currentExtension = nil;
            completion(error, log ?: @[]);
        });
    };

    NSString *identifier = [self helperIdentifier];
    if (identifier == nil)
        return finish(@"The JIT helper is not included in this build of iSH+.", nil);

    // NSExtension lives in ExtensionFoundation on current iOS.
    dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
    Class extensionClass = NSClassFromString(@"NSExtension");
    if (extensionClass == nil)
        return finish(@"App extensions are not available.", nil);
    NSError *error = nil;
    id extension = [extensionClass extensionWithIdentifier:identifier error:&error];
    if (extension == nil)
        return finish([NSString stringWithFormat:@"Could not start the JIT helper: %@",
                       error.localizedDescription ?: @"not registered"], nil);

    NSDictionary *request = @{
        @"pid": @(getpid()),
        @"pairing": [pairing base64EncodedStringWithOptions:0],
    };
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = @{kRequestKey: [NSJSONSerialization dataWithJSONObject:request options:0 error:nil]};

    [extension setRequestCompletionBlock:^(NSUUID *uuid, NSArray *items) {
        NSDictionary *response = nil;
        NSExtensionItem *reply = items.firstObject;
        NSData *data = reply.userInfo[kResponseKey];
        if ([data isKindOfClass:NSData.class])
            response = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![response isKindOfClass:NSDictionary.class])
            return finish(@"The JIT helper returned no answer.", nil);
        NSString *message = [response[@"ok"] boolValue] ? nil : (response[@"error"] ?: @"Unknown error");
        finish(message, response[@"log"]);
    }];
    [extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *cancelError) {
        finish(cancelError.localizedDescription ?: @"The JIT helper was cancelled.", nil);
    }];
    [extension setRequestInterruptionBlock:^(NSUUID *uuid) {
        finish(@"The JIT helper stopped unexpectedly. Try again.", nil);
    }];
    currentExtension = extension;
    [extension beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *uuid) {
        if (uuid == nil)
            finish(@"The JIT helper did not start.", nil);
    }];
}

@end
