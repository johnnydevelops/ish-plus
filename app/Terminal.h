//
//  Terminal.h
//  iSH
//
//  Created by Theodore Dubois on 10/18/17.
//

#import <UIKit/UIKit.h>

struct tty;
@class ISHTerminalSurface;

@interface Terminal : NSObject

+ (Terminal *)terminalWithType:(int)type number:(int)number;
#if !ISH_LINUX
// Returns a strong struct tty and a Terminal that has a weak reference to the same tty
+ (Terminal *)createPseudoTerminal:(struct tty **)tty;
#endif

+ (Terminal *)terminalWithUUID:(NSUUID *)uuid;
@property (readonly) NSUUID *uuid;

+ (void)convertCommand:(NSArray<NSString *> *)command toArgs:(char *)argv limitSize:(size_t)maxSize;

- (int)sendOutput:(const void *)buf length:(int)len;
- (void)sendInput:(NSData *)input;

- (NSString *)arrow:(char)direction;

// Make this terminal no longer be the singleton terminal with its type and number. Will happen eventually if all references go away, but sometimes you want it to happen now.
- (void)destroy;

// The native terminal that renders this session. Created on first use; main thread only.
@property (readonly) ISHTerminalSurface *surface;
@property (nonatomic) BOOL enableVoiceOverAnnounce;
// Always YES now that the terminal is native; kept for KVO compatibility.
@property (readonly) BOOL loaded;

@end

extern struct tty_driver ios_console_driver;
