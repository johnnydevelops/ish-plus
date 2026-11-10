//
//  AppDelegate.m
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import "AboutViewController.h"
#import "AppDelegate.h"
#import "BackgroundKeepAlive.h"
#import "SceneDelegate.h"
#import "NSObject+SaneKVO.h"
#import "Terminal.h"
#import "TerminalViewController.h"
#import "UserPreferences.h"

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application willFinishLaunchingWithOptions:(NSDictionary<UIApplicationLaunchOptionsKey,id> *)launchOptions {
    // iSH+ runs Linux in a QEMU virtual machine (see VirtualMachine.swift),
    // started when the first session opens.
    return YES;
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    [BackgroundKeepAlive start];

    [UserPreferences.shared observe:@[@"shouldDisableDimming"] options:NSKeyValueObservingOptionInitial
                              owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIApplication.sharedApplication.idleTimerDisabled = UserPreferences.shared.shouldDisableDimming;
        });
    }];

    if (self.window != nil) {
        // For iOS <13, where the app delegate owns the window instead of the scene
        TerminalViewController *vc = (TerminalViewController *) self.window.rootViewController;
        currentTerminalViewController = vc;
        [vc startNewSession];
    }
    return YES;
}

- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions API_AVAILABLE(ios(13.0)) {
    for (UISceneSession *sceneSession in sceneSessions) {
        NSDictionary *userInfo = sceneSession.stateRestorationActivity.userInfo;
        NSString *terminalUUID = userInfo[@"TerminalUUID"];
        if (terminalUUID != nil)
            [[Terminal terminalWithUUID:[[NSUUID alloc] initWithUUIDString:terminalUUID]] destroy];
        NSArray *sessions = userInfo[@"TerminalSessions"];
        if ([sessions isKindOfClass:NSArray.class]) {
            for (NSDictionary *session in sessions) {
                if (![session isKindOfClass:NSDictionary.class] || ![session[@"uuid"] isKindOfClass:NSString.class])
                    continue;
                [[Terminal terminalWithUUID:[[NSUUID alloc] initWithUUIDString:session[@"uuid"]]] destroy];
            }
        }
    }
}

@end
