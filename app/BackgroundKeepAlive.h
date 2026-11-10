//
//  BackgroundKeepAlive.h
//  iSH+
//
//  Keeps the app running in the background, like Termux's wakelock, by playing
//  an inaudible looping sound mixed with other audio. Controlled by the
//  keepAliveInBackground preference.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BackgroundKeepAlive : NSObject

// Starts following the preference. Call once at launch.
+ (void)start;

@end

NS_ASSUME_NONNULL_END
