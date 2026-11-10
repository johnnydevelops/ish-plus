//
//  ViewController.h
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import <UIKit/UIKit.h>
#import "Terminal.h"

@interface TerminalViewController : UIViewController

@property (nonatomic) Terminal *terminal;

- (void)startNewSession;
- (void)reconnectSessionFromTerminalUUID:(NSUUID *)uuid;
// Restores the sessions saved with `savedSessions`, showing the one with currentUUID.
- (void)reconnectSessions:(NSArray<NSDictionary *> *)savedSessions currentUUID:(NSUUID *)currentUUID;
// Property-list description of this window's sessions for state restoration.
@property (readonly) NSArray<NSDictionary *> *savedSessions;
@property (readonly) NSUUID *sessionTerminalUUID; // 0 means invalid
@property UISceneSession *sceneSession API_AVAILABLE(ios(13.0));

@end

extern struct tty_driver ios_tty_driver;
