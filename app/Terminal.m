//
//  Terminal.m
//  iSH
//
//  Created by Theodore Dubois on 10/18/17.
//

#import "Terminal.h"
#import "DelayedUITask.h"
#import "UserPreferences.h"
#import "UIApplication+OpenURL.h"
#import "iSHSwift.h"

@interface Terminal () <ISHTerminalSurfaceHost>

// Output waiting to be drawn; guarded by @synchronized(self)
@property (nonatomic) NSMutableData *pendingData;
// Drawing happens on the main thread; this keeps it from happening twice at once
@property (nonatomic) BOOL outputInProgress;

@property DelayedUITask *refreshTask;
@property DelayedUITask *scrollToBottomTask;

@property NSNumber *terminalsKey;
@property NSUUID *uuid;

@end

@implementation Terminal
@synthesize surface = _surface;

static const int BUF_SIZE = 1<<14;

static NSMapTable<NSNumber *, Terminal *> *terminals;
static NSMapTable<NSUUID *, Terminal *> *terminalsByUUID;

- (instancetype)initWithType:(int)type number:(int)num {
    @synchronized (Terminal.class) {
        self.terminalsKey = @(((uint64_t) type << 32) | (uint32_t) num);
        Terminal *terminal = [terminals objectForKey:self.terminalsKey];
        if (terminal)
            return terminal;

        if (self = [super init]) {
            self.pendingData = [[NSMutableData alloc] initWithCapacity:BUF_SIZE];
            self.refreshTask = [[DelayedUITask alloc] initWithTarget:self action:@selector(refresh)];
            self.scrollToBottomTask = [[DelayedUITask alloc] initWithTarget:self action:@selector(scrollToBottom)];
            [terminals setObject:self forKey:self.terminalsKey];
            self.uuid = [NSUUID UUID];
            [terminalsByUUID setObject:self forKey:self.uuid];
        }
        return self;
    }
}

- (ISHTerminalSurface *)surface {
    NSAssert(NSThread.isMainThread, @"terminal surfaces are UI objects");
    if (_surface == nil) {
        // Start at a reasonable size so programs that write before the terminal is displayed don't wrap too badly.
        CGFloat fontSize = UserPreferences.shared.fontSize.doubleValue;
        _surface = [[ISHTerminalSurface alloc] initWithFrame:CGRectMake(0, 0, 1024, 768) fontSize:fontSize];
        _surface.host = self;
    }
    return _surface;
}

- (BOOL)loaded {
    return YES;
}

- (void)setResizeHandler:(void (^)(int, int))resizeHandler {
    _resizeHandler = [resizeHandler copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self syncWindowSize];
    });
}

#pragma mark Surface host

- (void)surfaceSendInput:(NSData *)data {
    [self sendInput:data];
}

- (void)surfaceDidResizeWithColumns:(NSInteger)columns rows:(NSInteger)rows {
    [self syncWindowSize];
}

- (void)surfaceSetTitle:(NSString *)title {
}

- (void)surfaceOpenLink:(NSString *)link {
    [UIApplication openURL:link];
}

- (void)syncWindowSize {
    if (_surface == nil)
        return;
    int cols = (int) _surface.columns;
    int rows = (int) _surface.rows;
    if (cols <= 0 || rows <= 0)
        return;
    void (^resizeHandler)(int, int) = self.resizeHandler;
    if (resizeHandler != nil)
        resizeHandler(cols, rows);
}

- (void)setEnableVoiceOverAnnounce:(BOOL)enableVoiceOverAnnounce {
    // SwiftTerm exposes the terminal to VoiceOver itself.
    _enableVoiceOverAnnounce = enableVoiceOverAnnounce;
}

- (int)sendOutput:(const void *)buf length:(int)len {
    @synchronized (self) {
        [_pendingData appendData:[NSData dataWithBytes:buf length:len]];
        [_refreshTask schedule];
    }
    return len;
}

- (void)sendInput:(NSData *)input {
    void (^inputHandler)(NSData *) = self.inputHandler;
    if (inputHandler != nil)
        inputHandler(input);
    [self.scrollToBottomTask schedule];
}

- (void)scrollToBottom {
    [_surface scrollToBottom];
}

- (NSString *)arrow:(char)direction {
    BOOL applicationCursor = _surface != nil && _surface.applicationCursor;
    return [NSString stringWithFormat:@"\x1b%c%c", applicationCursor ? 'O' : '[', direction];
}

- (void)refresh {
    NSData *data;
    @synchronized (self) {
        if (_outputInProgress) {
            [self.refreshTask schedule];
            return;
        }
        data = _pendingData;
        _pendingData = [[NSMutableData alloc] initWithCapacity:BUF_SIZE];
        _outputInProgress = YES;
    }
    [self.surface feedData:data];
    @synchronized (self) {
        _outputInProgress = NO;
    }
}

+ (Terminal *)terminalWithType:(int)type number:(int)number {
    return [[Terminal alloc] initWithType:type number:number];
}

+ (Terminal *)terminalWithUUID:(NSUUID *)uuid {
    @synchronized (Terminal.class) {
        return [terminalsByUUID objectForKey:uuid];
    }
}

- (void)destroy {
    void (^destroyHandler)(void) = self.destroyHandler;
    self.destroyHandler = nil;
    if (destroyHandler != nil)
        destroyHandler();
    @synchronized (Terminal.class) {
        [terminals removeObjectForKey:self.terminalsKey];
    }
}

+ (void)initialize {
    if (self == Terminal.class) {
        terminals = [NSMapTable strongToWeakObjectsMapTable];
        terminalsByUUID = [NSMapTable strongToWeakObjectsMapTable];
    }
}

@end
