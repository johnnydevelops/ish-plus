//
//  JITHelperLauncher.h
//  iSH+
//
//  Starts iSH+'s JIT helper extension (iSHJITHelper.appex), which attaches a
//  debugger to iSH+ through LocalDevVPN using the imported pairing file.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ISHJITHelperLauncher : NSObject

// Whether the helper extension is installed with the app.
@property (class, readonly) BOOL available;

// Asks the helper to enable JIT for this process. completion runs on the main
// queue when the helper finishes (after iSH+ tells the debugger to detach) or
// fails; error is nil on success. JIT itself is usable as soon as the
// debugger has attached, long before completion.
+ (void)enableJITWithPairingData:(NSData *)pairing
                      completion:(void (^)(NSString *_Nullable error, NSArray<NSString *> *log))completion;

@end

NS_ASSUME_NONNULL_END
