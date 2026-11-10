//
//  ViewController.m
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import "TerminalViewController.h"
#import "AppDelegate.h"
#import "TerminalView.h"
#import "BarButton.h"
#import "ArrowBarButton.h"
#import "UserPreferences.h"
#import "AboutViewController.h"
#import "CurrentRoot.h"
#import "NSObject+SaneKVO.h"
#import "LinuxInterop.h"
#import "iSHSwift.h"
#include "kernel/init.h"
#include "kernel/task.h"
#include "kernel/calls.h"
#include "fs/devices.h"

// One shell running in its own pseudo terminal. A window can hold several.
@interface TerminalSession : NSObject
@property Terminal *terminal;
@property int pid;
@property int number; // shown to the user, stable for the life of the session
@end
@implementation TerminalSession
@end

@interface TerminalViewController () <UIGestureRecognizerDelegate>

@property UITapGestureRecognizer *tapRecognizer;
@property (weak, nonatomic) IBOutlet TerminalView *termView;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *bottomConstraint;

@property (weak, nonatomic) IBOutlet UIButton *tabKey;
@property (weak, nonatomic) IBOutlet UIButton *controlKey;
@property (weak, nonatomic) IBOutlet UIButton *escapeKey;
@property (strong, nonatomic) IBOutletCollection(id) NSArray *barButtons;
@property (strong, nonatomic) IBOutletCollection(id) NSArray *barControls;

@property (weak, nonatomic) IBOutlet UIInputView *barView;
@property (weak, nonatomic) IBOutlet UIStackView *bar;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barTop;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barBottom;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barLeading;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barTrailing;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barButtonWidth;
@property (weak, nonatomic) IBOutlet NSLayoutConstraint *barHeight;
@property (weak, nonatomic) IBOutlet UIView *settingsBadge;

@property (weak, nonatomic) IBOutlet UIButton *infoButton;
@property (weak, nonatomic) IBOutlet UIButton *pasteButton;
@property (weak, nonatomic) IBOutlet UIButton *hideKeyboardButton;

@property NSMutableArray<TerminalSession *> *sessions;
@property (nonatomic) TerminalSession *currentSession;
@property int nextSessionNumber;
@property UIButton *sessionsButton;
@property BOOL showingJITScreen;
@property BOOL pendingJITScreen;
@property (readonly) int sessionPid;
@property (readonly, nonatomic) Terminal *sessionTerminal;

@property BOOL ignoreKeyboardMotion;
@property (nonatomic) BOOL hasExternalKeyboard;

@end

@implementation TerminalViewController

- (void)viewDidLoad {
    [super viewDidLoad];

#if !ISH_LINUX
    int bootError = [AppDelegate bootError];
    if (bootError < 0) {
        NSString *message = [NSString stringWithFormat:@"could not boot"];
        NSString *subtitle = [NSString stringWithFormat:@"error code %d", bootError];
        if (bootError == _EINVAL)
            subtitle = [subtitle stringByAppendingString:@"\n(try reinstalling the app, see release notes for details)"];
        [self showMessage:message subtitle:subtitle];
        NSLog(@"boot failed with code %d", bootError);
    }
#endif

    self.terminal = self.terminal;
    [self.termView becomeFirstResponder];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(keyboardDidSomething:)
                   name:UIKeyboardWillChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(keyboardDidSomething:)
                   name:UIKeyboardDidChangeFrameNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(_updateBadge)
                   name:FsUpdatedNotification
                 object:nil];


    [self _updateStyleFromPreferences:NO];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        [self.bar removeArrangedSubview:self.hideKeyboardButton];
        [self.hideKeyboardButton removeFromSuperview];
    }
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        self.barHeight.constant = 36;
    } else {
        self.barHeight.constant = 43;
    }
    
    // SF Symbols is cool
    if (@available(iOS 13, *)) {
        [self.infoButton setImage:[UIImage systemImageNamed:@"gear"] forState:UIControlStateNormal];
        [self.pasteButton setImage:[UIImage systemImageNamed:@"doc.on.clipboard"] forState:UIControlStateNormal];
        [self.hideKeyboardButton setImage:[UIImage systemImageNamed:@"keyboard.chevron.compact.down"] forState:UIControlStateNormal];
        
        [self.tabKey setTitle:nil forState:UIControlStateNormal];
        [self.tabKey setImage:[UIImage systemImageNamed:@"arrow.right.to.line.alt"] forState:UIControlStateNormal];
        [self.controlKey setTitle:nil forState:UIControlStateNormal];
        [self.controlKey setImage:[UIImage systemImageNamed:@"control"] forState:UIControlStateNormal];
        [self.escapeKey setTitle:nil forState:UIControlStateNormal];
        [self.escapeKey setImage:[UIImage systemImageNamed:@"escape"] forState:UIControlStateNormal];
    }
    
    [self _setupSessionsButton];
    [UserPreferences.shared observe:@[@"hideStatusBar"] options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setNeedsStatusBarAppearanceUpdate];
        });
    }];
    [UserPreferences.shared observe:@[@"colorScheme", @"theme", @"hideExtraKeysWithExternalKeyboard"]
                            options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateStyleFromPreferences:YES];
        });
    }];
    [self _updateBadge];
}

- (void)awakeFromNib {
    [super awakeFromNib];
#if !ISH_LINUX
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(processExited:)
                                               name:ProcessExitedNotification
                                             object:nil];
#else
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(kernelPanicked:)
                                               name:KernelPanicNotification
                                             object:nil];
#endif
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.pendingJITScreen) {
        self.pendingJITScreen = NO;
        [self presentJITScreenThenStartSession];
    }
}

// "Enabling JIT…", then start the session the way the user chose.
- (void)presentJITScreenThenStartSession {
    if (self.showingJITScreen)
        return;
    if (self.view.window == nil || self.presentedViewController != nil) {
        self.pendingJITScreen = YES;
        return;
    }
    self.showingJITScreen = YES;
    __weak typeof(self) weakSelf = self;
    ISHJITViewController *jit = [[ISHJITViewController alloc] initWithCompletion:^(ISHJITChoice choice) {
        weakSelf.showingJITScreen = NO;
        switch (choice) {
            case ISHJITChoiceInterpreted:
                ISHVirtualMachine.shared.interpreted = YES;
                break;
            case ISHJITChoiceJit:
                break;
        }
        [weakSelf startNewSession];
    }];
    [self presentViewController:jit animated:NO completion:nil];
}

- (void)startNewSession {
    int err = [self startSession];
    if (err < 0) {
        [self showMessage:@"could not start session"
                 subtitle:[NSString stringWithFormat:@"error code %d", err]];
    }
}

- (void)reconnectSessions:(NSArray<NSDictionary *> *)savedSessions currentUUID:(NSUUID *)currentUUID {
    TerminalSession *toShow = nil;
    for (NSDictionary *saved in savedSessions) {
        if (![saved isKindOfClass:NSDictionary.class] || ![saved[@"uuid"] isKindOfClass:NSString.class])
            continue;
        NSUUID *uuid = [[NSUUID alloc] initWithUUIDString:saved[@"uuid"]];
        Terminal *terminal = uuid ? [Terminal terminalWithUUID:uuid] : nil;
        if (terminal == nil)
            continue;
        TerminalSession *session = [self addSessionWithTerminal:terminal pid:[saved[@"pid"] intValue]];
        if ([uuid isEqual:currentUUID])
            toShow = session;
    }
    if (self.sessions.count == 0) {
        // Older saved state only had the current terminal.
        Terminal *terminal = currentUUID ? [Terminal terminalWithUUID:currentUUID] : nil;
        if (terminal != nil)
            [self addSessionWithTerminal:terminal pid:0];
    }
    if (self.sessions.count == 0) {
        [self startNewSession];
        return;
    }
    if (toShow != nil)
        self.currentSession = toShow;
}

- (void)reconnectSessionFromTerminalUUID:(NSUUID *)uuid {
    [self reconnectSessions:@[] currentUUID:uuid];
}

- (NSArray<NSDictionary *> *)savedSessions {
    NSMutableArray *saved = [NSMutableArray new];
    for (TerminalSession *session in self.sessions) {
        [saved addObject:@{@"uuid": session.terminal.uuid.UUIDString, @"pid": @(session.pid)}];
    }
    return saved;
}

#pragma mark Sessions

- (TerminalSession *)addSessionWithTerminal:(Terminal *)terminal pid:(int)pid {
    if (self.sessions == nil)
        self.sessions = [NSMutableArray new];
    TerminalSession *session = [TerminalSession new];
    session.terminal = terminal;
    session.pid = pid;
    session.number = ++self.nextSessionNumber;
    [self.sessions addObject:session];
    self.currentSession = session;
    return session;
}

- (Terminal *)sessionTerminal {
    return self.currentSession.terminal;
}

- (int)sessionPid {
    return self.currentSession.pid;
}

- (void)setCurrentSession:(TerminalSession *)currentSession {
    BOOL showingSession = _terminal == nil || _terminal == _currentSession.terminal;
    _currentSession = currentSession;
    if (showingSession)
        self.terminal = currentSession.terminal;
    [self _updateSessionsButton];
}

- (void)switchToSessionAtOffset:(NSInteger)offset {
    NSInteger count = (NSInteger) self.sessions.count;
    if (count < 2)
        return;
    NSInteger index = (NSInteger) [self.sessions indexOfObject:self.currentSession];
    if (index == NSNotFound)
        index = 0;
    index = ((index + offset) % count + count) % count;
    self.currentSession = self.sessions[index];
}

- (void)newSession:(id)sender {
    [self startNewSession];
}

- (void)nextSession:(id)sender {
    [self switchToSessionAtOffset:1];
}

- (void)previousSession:(id)sender {
    [self switchToSessionAtOffset:-1];
}

- (void)closeSession:(TerminalSession *)session {
    // Hanging up the terminal sends SIGHUP to the shell; processExited: cleans up.
    [session.terminal destroy];
}

- (NSString *)titleForSession:(TerminalSession *)session {
    return [NSString stringWithFormat:@"Session %d", session.number];
}

- (NSArray<UIMenuElement *> *)sessionsMenuElements {
    __weak typeof(self) weakSelf = self;
    NSMutableArray<UIMenuElement *> *sessionItems = [NSMutableArray new];
    for (TerminalSession *session in self.sessions) {
        UIAction *action = [UIAction actionWithTitle:[self titleForSession:session]
                                               image:[UIImage systemImageNamed:@"terminal"]
                                          identifier:nil
                                             handler:^(UIAction *action) {
            weakSelf.currentSession = session;
        }];
        action.state = session == self.currentSession ? UIMenuElementStateOn : UIMenuElementStateOff;
        [sessionItems addObject:action];
    }
    UIAction *new = [UIAction actionWithTitle:@"New Session"
                                        image:[UIImage systemImageNamed:@"plus"]
                                   identifier:nil
                                      handler:^(UIAction *action) {
        [weakSelf startNewSession];
    }];
    UIAction *close = [UIAction actionWithTitle:@"Close Session"
                                          image:[UIImage systemImageNamed:@"xmark"]
                                     identifier:nil
                                        handler:^(UIAction *action) {
        [weakSelf closeSession:weakSelf.currentSession];
    }];
    close.attributes = UIMenuElementAttributesDestructive;
    return @[
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:sessionItems],
        [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[new, close]],
    ];
}

- (void)_setupSessionsButton {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    __weak typeof(self) weakSelf = self;
    button.menu = [UIMenu menuWithChildren:@[[UIDeferredMenuElement elementWithUncachedProvider:^(void (^completion)(NSArray<UIMenuElement *> *)) {
        completion(weakSelf.sessionsMenuElements ?: @[]);
    }]]];
    button.showsMenuAsPrimaryAction = YES;
    button.accessibilityLabel = @"Sessions";
    button.translatesAutoresizingMaskIntoConstraints = NO;
    NSUInteger infoIndex = [self.bar.arrangedSubviews indexOfObject:self.infoButton.superview];
    if (infoIndex == NSNotFound)
        infoIndex = self.bar.arrangedSubviews.count;
    [self.bar insertArrangedSubview:button atIndex:infoIndex];
    [button.widthAnchor constraintEqualToAnchor:self.pasteButton.widthAnchor].active = YES;
    self.barControls = [self.barControls arrayByAddingObject:button];
    self.sessionsButton = button;
    [self _updateSessionsButton];
}

- (void)_updateSessionsButton {
    NSUInteger count = self.sessions.count;
    UIImage *image = nil;
    if (count > 1 && count <= 50)
        image = [UIImage systemImageNamed:[NSString stringWithFormat:@"%lu.square", (unsigned long) count]];
    if (image == nil)
        image = [UIImage systemImageNamed:@"square.on.square"];
    [self.sessionsButton setImage:image forState:UIControlStateNormal];
    self.sessionsButton.accessibilityValue = [NSString stringWithFormat:@"%lu sessions", (unsigned long) count];
}

- (NSUUID *)sessionTerminalUUID {
    return self.terminal.uuid;
}

// Terminal numbers for Linux VM consoles; any unused tty major works as the key.
#define VM_CONSOLE_MAJOR 250
static int nextVMTerminalNumber;

// A session on one of the Linux VM's consoles. The guest's getty keeps running
// when the session is closed, so the shell is still there next time.
- (int)startVMSession {
    ISHVirtualMachine *vm = ISHVirtualMachine.shared;
    if (!vm.isRunning && !vm.interpreted && !ISHVirtualMachine.jitAvailable) {
        [self presentJITScreenThenStartSession];
        return 0;
    }
    Terminal *terminal = [Terminal terminalWithType:VM_CONSOLE_MAJOR number:nextVMTerminalNumber++];
    __weak Terminal *weakTerminal = terminal;
    __weak typeof(self) weakSelf = self;
    NSError *error = nil;
    ISHVirtualMachineConsole *console = [ISHVirtualMachine.shared openConsoleWithOutput:^(NSData *data) {
        [weakTerminal sendOutput:data.bytes length:(int) data.length];
    } closed:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf vmConsoleClosedForTerminal:weakTerminal];
        });
    } error:&error];
    if (console == nil) {
        [self showMessage:@"Could not start the Linux VM" subtitle:error.localizedDescription];
        [terminal destroy];
        return 0;
    }
    terminal.inputHandler = ^(NSData *data) {
        [console send:data];
    };
    terminal.destroyHandler = ^{
        [console close];
    };
    [self addSessionWithTerminal:terminal pid:0];
    return 0;
}

- (void)vmConsoleClosedForTerminal:(Terminal *)terminal {
    TerminalSession *ended = nil;
    for (TerminalSession *session in self.sessions) {
        if (session.terminal == terminal)
            ended = session;
    }
    if (ended == nil)
        return;
    [ended.terminal destroy];
    NSUInteger index = [self.sessions indexOfObject:ended];
    [self.sessions removeObject:ended];
    if (self.sessions.count == 0) {
        [self startNewSession];
    } else if (ended == self.currentSession) {
        self.currentSession = self.sessions[MIN(index, self.sessions.count - 1)];
    } else {
        [self _updateSessionsButton];
    }
}

// iSH+ runs every session in the Linux VM; iSH's own kernel is not used.
- (int)startSession {
    return [self startVMSession];
}

#if !ISH_LINUX
- (void)processExited:(NSNotification *)notif {
    int pid = [notif.userInfo[@"pid"] intValue];
    TerminalSession *exited = nil;
    for (TerminalSession *session in self.sessions) {
        if (session.pid == pid)
            exited = session;
    }
    if (exited == nil)
        return;
    [exited.terminal destroy];
    if (self.sessions.count > 1) {
        // Other sessions remain: drop this one and show a neighbour.
        NSUInteger index = [self.sessions indexOfObject:exited];
        [self.sessions removeObject:exited];
        if (exited == self.currentSession)
            self.currentSession = self.sessions[MIN(index, self.sessions.count - 1)];
        else
            [self _updateSessionsButton];
        current = NULL; // it's been freed
        return;
    }
    [self.sessions removeObject:exited];
    // On iOS 13, there are multiple windows, so just close this one.
    if (@available(iOS 13, *)) {
        // On iPhone, destroying scenes will fail, but the error doesn't actually go to the error handler, which is really stupid. Apple doesn't fix bugs, so I'm forced to just add a check here.
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad && self.sceneSession != nil) {
            [UIApplication.sharedApplication requestSceneSessionDestruction:self.sceneSession options:nil errorHandler:^(NSError *error) {
                NSLog(@"scene destruction error %@", error);
                self.sceneSession = nil;
                [self processExited:notif];
            }];
            return;
        }
    }
    current = NULL; // it's been freed
    [self startNewSession];
}
#endif

#if ISH_LINUX
- (void)kernelPanicked:(NSNotification *)notif {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"panik" message:notif.userInfo[@"message"] preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"k" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
#endif

- (void)showMessage:(NSString *)message subtitle:(NSString *)subtitle {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:message message:subtitle preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"k"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (object == [UserPreferences shared]) {
        [self _updateStyleFromPreferences:YES];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (void)_updateStyleFromPreferences:(BOOL)animated {
    NSAssert(NSThread.isMainThread, @"This method needs to be called on the main thread");
    NSTimeInterval duration = animated ? 0.1 : 0;
    [UIView animateWithDuration:duration animations:^{
        self.view.backgroundColor = [[UIColor alloc] ish_initWithHexString:UserPreferences.shared.palette.backgroundColor];
        UIKeyboardAppearance keyAppearance = UserPreferences.shared.keyboardAppearance;
        self.termView.keyboardAppearance = keyAppearance;
        // The glass bar and its symbols follow the keyboard's light/dark appearance.
        self.barView.overrideUserInterfaceStyle = keyAppearance == UIKeyboardAppearanceLight ? UIUserInterfaceStyleLight : UIUserInterfaceStyleDark;
        for (BarButton *button in self.barButtons) {
            button.keyAppearance = keyAppearance;
        }
        UIColor *tintColor = keyAppearance == UIKeyboardAppearanceLight ? UIColor.blackColor : UIColor.whiteColor;
        for (UIControl *control in self.barControls) {
            control.tintColor = tintColor;
        }
    }];
    UIView *oldBarView = self.termView.inputAccessoryView;
    if (UserPreferences.shared.hideExtraKeysWithExternalKeyboard && self.hasExternalKeyboard) {
        self.termView.inputAccessoryView = nil;
    } else {
        self.termView.inputAccessoryView = self.barView;
    }
    if (self.termView.inputAccessoryView != oldBarView && self.termView.isFirstResponder) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.ignoreKeyboardMotion = YES; // avoid infinite recursion
            [self.termView reloadInputViews];
            self.ignoreKeyboardMotion = NO;
        });
    }
}
- (void)_updateStyleAnimated {
    [self _updateStyleFromPreferences:YES];
}

- (void)_updateBadge {
    self.settingsBadge.hidden = !FsNeedsRepositoryUpdate();
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UserPreferences.shared.statusBarStyle;
}

- (BOOL)prefersStatusBarHidden {
    return UserPreferences.shared.hideStatusBar;
}

- (void)keyboardDidSomething:(NSNotification *)notification {
    if (self.ignoreKeyboardMotion)
        return;

    CGRect screenKeyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    UIScreen *screen = UIScreen.mainScreen;
    // notification.object is nil before iOS 16.1 and the correct UIScreen after iOS 16.1
    if (notification.object != nil)
        screen = notification.object;
    CGRect keyboardFrame = [self.view convertRect:screenKeyboardFrame fromCoordinateSpace:screen.coordinateSpace];
    if (CGRectEqualToRect(keyboardFrame, CGRectZero))
        return;
    CGRect intersection = CGRectIntersection(keyboardFrame, self.view.bounds);
    keyboardFrame = intersection;
    NSLog(@"%@ %@", notification.name, @(keyboardFrame));
    self.hasExternalKeyboard = keyboardFrame.size.height < 100;
    CGFloat pad = CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(keyboardFrame);
    // The keyboard appears to be undocked. This means it can either be split or
    // truly floating. In the former case we want to keep the pad, but in the
    // latter we should fall back to the input accessory view instead of the
    // keyboard.
    if (pad != keyboardFrame.size.height && keyboardFrame.size.width != UIScreen.mainScreen.bounds.size.width) {
        pad = MAX(self.view.safeAreaInsets.bottom, self.termView.inputAccessoryView.frame.size.height);
    }
    // NSLog(@"pad %f", pad);
    self.bottomConstraint.constant = pad;

    BOOL initialLayout = self.termView.needsUpdateConstraints;
    [self.view setNeedsUpdateConstraints];
    if (!initialLayout) {
        // if initial layout hasn't happened yet, the terminal view is going to be at a really weird place, so animating it is going to look really bad
        NSNumber *interval = notification.userInfo[UIKeyboardAnimationDurationUserInfoKey];
        NSNumber *curve = notification.userInfo[UIKeyboardAnimationCurveUserInfoKey];
        [UIView animateWithDuration:interval.doubleValue
                              delay:0
                            options:curve.integerValue << 16
                         animations:^{
                             [self.view layoutIfNeeded];
                         }
                         completion:nil];
    }
}

- (void)setHasExternalKeyboard:(BOOL)hasExternalKeyboard {
    _hasExternalKeyboard = hasExternalKeyboard;
    [self _updateStyleFromPreferences:YES];
}

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"embed"]) {
        // You might want to check if this is your embed segue here
        // in case there are other segues triggered from this view controller.
        segue.destinationViewController.view.translatesAutoresizingMaskIntoConstraints = NO;
    }
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    // Hack to resolve a layering mismatch between the UI and preferences.
    if (@available(iOS 12.0, *)) {
        if (previousTraitCollection.userInterfaceStyle != self.traitCollection.userInterfaceStyle) {
            // Ensure that the relevant things listening for this will update.
            UserPreferences.shared.colorScheme = UserPreferences.shared.colorScheme;
        }
    }
}

#pragma mark Bar

- (IBAction)showAbout:(id)sender {
    UINavigationController *navigationController = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
    if ([sender isKindOfClass:[UIGestureRecognizer class]]) {
        UIGestureRecognizer *recognizer = sender;
        if (recognizer.state == UIGestureRecognizerStateBegan) {
            AboutViewController *aboutViewController = (AboutViewController *) navigationController.topViewController;
            aboutViewController.includeDebugPanel = YES;
        } else {
            return;
        }
    }
    [self presentViewController:navigationController animated:YES completion:nil];
    [self.termView resignFirstResponder];
}

- (void)resizeBar {
    CGSize bar = self.barView.bounds.size;
    // set sizing parameters on bar
    // numbers stolen from iVim and modified somewhat
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        // phone
        [self setBarHorizontalPadding:6 verticalPadding:6 buttonWidth:32];
    } else if (bar.width >= 450) {
        // wide ipad
        [self setBarHorizontalPadding:15 verticalPadding:8 buttonWidth:43];
    } else {
        // narrow ipad (slide over)
        [self setBarHorizontalPadding:10 verticalPadding:8 buttonWidth:36];
    }
    [UIView performWithoutAnimation:^{
        [self.barView layoutIfNeeded];
    }];
}

- (void)setBarHorizontalPadding:(CGFloat)horizontal verticalPadding:(CGFloat)vertical buttonWidth:(CGFloat)buttonWidth {
    self.barLeading.constant = self.barTrailing.constant = horizontal;
    self.barTop.constant = self.barBottom.constant = vertical;
    self.barButtonWidth.constant = buttonWidth;
}

- (IBAction)pressEscape:(id)sender {
    [self pressKey:@"\x1b"];
}
- (IBAction)pressTab:(id)sender {
    [self pressKey:@"\t"];
}
- (void)pressKey:(NSString *)key {
    [self.termView insertText:key];
}

- (IBAction)pressControl:(id)sender {
    self.controlKey.selected = !self.controlKey.selected;
}
    
- (IBAction)pressArrow:(ArrowBarButton *)sender {
    switch (sender.direction) {
        case ArrowUp: [self pressKey:[self.terminal arrow:'A']]; break;
        case ArrowDown: [self pressKey:[self.terminal arrow:'B']]; break;
        case ArrowLeft: [self pressKey:[self.terminal arrow:'D']]; break;
        case ArrowRight: [self pressKey:[self.terminal arrow:'C']]; break;
        case ArrowNone: break;
    }
}

- (void)switchTerminal:(UIKeyCommand *)sender {
    unsigned i = (unsigned) sender.input.integerValue;
    if (i == 7)
        self.terminal = self.sessionTerminal;
    else
        self.terminal = [Terminal terminalWithType:TTY_CONSOLE_MAJOR number:i];
}

- (void)increaseFontSize:(UIKeyCommand *)command {
    self.termView.overrideFontSize = self.termView.effectiveFontSize + 1;
}
- (void)decreaseFontSize:(UIKeyCommand *)command {
    self.termView.overrideFontSize = self.termView.effectiveFontSize - 1;
}
- (void)resetFontSize:(UIKeyCommand *)command {
    self.termView.overrideFontSize = 0;
}

- (NSArray<UIKeyCommand *> *)keyCommands {
    static NSMutableArray<UIKeyCommand *> *commands = nil;
    if (commands == nil) {
        commands = [NSMutableArray new];
        for (unsigned i = 1; i <= 7; i++) {
            [commands addObject:
             [UIKeyCommand keyCommandWithInput:[NSString stringWithFormat:@"%d", i]
                                 modifierFlags:UIKeyModifierCommand|UIKeyModifierAlternate|UIKeyModifierShift
                                        action:@selector(switchTerminal:)]];
        }
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"+"
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(increaseFontSize:)
                      discoverabilityTitle:@"Increase Font Size"]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"="
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(increaseFontSize:)]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"-"
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(decreaseFontSize:)
                      discoverabilityTitle:@"Decrease Font Size"]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@"0"
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(resetFontSize:)
                      discoverabilityTitle:@"Reset Font Size"]];
        [commands addObject:
         [UIKeyCommand keyCommandWithInput:@","
                             modifierFlags:UIKeyModifierCommand
                                    action:@selector(showAbout:)
                      discoverabilityTitle:@"Settings"]];
        [commands addObject:[UIKeyCommand commandWithTitle:@"New Session" image:nil action:@selector(newSession:)
                                                     input:@"t" modifierFlags:UIKeyModifierCommand propertyList:nil]];
        [commands addObject:[UIKeyCommand commandWithTitle:@"Next Session" image:nil action:@selector(nextSession:)
                                                     input:@"]" modifierFlags:UIKeyModifierCommand|UIKeyModifierShift propertyList:nil]];
        [commands addObject:[UIKeyCommand commandWithTitle:@"Previous Session" image:nil action:@selector(previousSession:)
                                                     input:@"[" modifierFlags:UIKeyModifierCommand|UIKeyModifierShift propertyList:nil]];
    }
    return commands;
}

- (void)setTerminal:(Terminal *)terminal {
    _terminal = terminal;
    self.termView.terminal = self.terminal;
}


@end

@interface BarView : UIInputView
@property (weak) IBOutlet TerminalViewController *terminalViewController;
@property (nonatomic) IBInspectable BOOL allowsSelfSizing;
@end
@implementation BarView {
    UIVisualEffectView *_glassView;
}
@dynamic allowsSelfSizing;

- (void)awakeFromNib {
    [super awakeFromNib];
    if (@available(iOS 26.0, *)) {
        // Float the keys in a Liquid Glass capsule above the keyboard, like the
        // system's own accessory bars, instead of a solid keyboard-coloured strip.
        self.backgroundColor = UIColor.clearColor;
        UIStackView *stack = nil;
        for (UIView *view in self.subviews) {
            if ([view isKindOfClass:UIStackView.class])
                stack = (UIStackView *) view;
        }
        if (stack == nil)
            return;
        UIVisualEffectView *glass = [[UIVisualEffectView alloc] initWithEffect:[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular]];
        glass.cornerConfiguration = [UICornerConfiguration capsuleConfigurationWithMaximumRadius:22];
        glass.translatesAutoresizingMaskIntoConstraints = NO;
        glass.userInteractionEnabled = NO;
        [self insertSubview:glass belowSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [glass.leadingAnchor constraintEqualToAnchor:stack.leadingAnchor constant:-4],
            [glass.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor constant:4],
            [glass.topAnchor constraintEqualToAnchor:stack.topAnchor constant:-3],
            [glass.bottomAnchor constraintEqualToAnchor:stack.bottomAnchor constant:3],
        ]];
        _glassView = glass;
    }
}

- (void)layoutSubviews {
    [self.terminalViewController resizeBar];
}

@end
