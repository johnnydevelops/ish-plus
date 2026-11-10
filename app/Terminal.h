//
//  Terminal.h
//  iSH
//
//  Created by Theodore Dubois on 10/18/17.
//

#import <UIKit/UIKit.h>

@class ISHTerminalSurface;

@interface Terminal : NSObject

+ (Terminal *)terminalWithType:(int)type number:(int)number;

+ (Terminal *)terminalWithUUID:(NSUUID *)uuid;
@property (readonly) NSUUID *uuid;

- (int)sendOutput:(const void *)buf length:(int)len;
- (void)sendInput:(NSData *)input;

// Each terminal is a console of the Linux VM: inputHandler receives what the
// user types, and destroyHandler runs when the terminal is destroyed (its
// session closed).
@property (copy) void (^inputHandler)(NSData *data);
@property (copy) void (^destroyHandler)(void);
// Called with the terminal's size whenever it changes.
@property (copy) void (^resizeHandler)(int columns, int rows);

- (NSString *)arrow:(char)direction;

// Make this terminal no longer be the singleton terminal with its type and number. Will happen eventually if all references go away, but sometimes you want it to happen now.
- (void)destroy;

// The native terminal that renders this session. Created on first use; main thread only.
@property (readonly) ISHTerminalSurface *surface;
@property (nonatomic) BOOL enableVoiceOverAnnounce;
// Always YES now that the terminal is native; kept for KVO compatibility.
@property (readonly) BOOL loaded;

@end

