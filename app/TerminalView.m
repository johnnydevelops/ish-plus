//
//  TerminalView.m
//  iSH
//
//  Created by Theodore Dubois on 11/3/17.
//

#import "TerminalView.h"
#import "UserPreferences.h"
#import "NSObject+SaneKVO.h"
#import "iSHSwift.h"

@interface TerminalView ()
@property (nonatomic) ISHTerminalSurface *surface;
@property (nonatomic) UIButton *focusButton;
@end

@implementation TerminalView
@synthesize canBecomeFirstResponder = _canBecomeFirstResponder;
@synthesize inputAccessoryView = _inputAccessoryView;

- (void)awakeFromNib {
    [super awakeFromNib];
    UserPreferences *prefs = UserPreferences.shared;
    [prefs observe:@[@"optionMapping", @"backtickMapEscape", @"overrideControlSpace", @"capsLockMapping"]
           options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateKeyboardPreferences];
        });
    }];
    [prefs observe:@[@"colorScheme", @"fontFamily", @"fontSize", @"theme", @"cursorStyle", @"blinkCursor"]
           options:0 owner:self usingBlock:^(typeof(self) self) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _updateStyle];
        });
    }];
}

- (void)dealloc {
    self.terminal = nil;
}

static const CGFloat kTerminalPadding = 4;

#pragma mark Hosting the surface

- (void)setTerminal:(Terminal *)terminal {
    if (_terminal == terminal)
        return;
    BOOL wasFocused = self.isFirstResponder;
    [self uninstallSurface];
    _terminal = terminal;
    if (terminal != nil)
        [self installSurface];
    if (wasFocused)
        [self becomeFirstResponder];
}

- (void)installSurface {
    ISHTerminalSurface *surface = self.terminal.surface;
    if (surface.superview != nil && surface.superview != self)
        [surface removeFromSuperview];
    // A small margin around the text, as iSH had (hterm's screen padding).
    // The surface is transparent, so it shows the theme's background.
    surface.frame = CGRectInset(self.bounds, kTerminalPadding, kTerminalPadding);
    surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    surface.userInteractionEnabled = self.userInteractionEnabled;
    surface.controlKey = self.controlKey;
    surface.accessoryView = self.inputAccessoryView;
    surface.keyboardAppearance = self.keyboardAppearance;
    __weak typeof(self) weakSelf = self;
    surface.focusChanged = ^(BOOL focused) {
        [weakSelf _updateFocusButton];
    };
    self.surface = surface;
    [self insertSubview:surface atIndex:0];
    [self _updateFocusButton];
    self.opaque = NO;
    [self _updateKeyboardPreferences];
    [self _updateStyle];
}

- (void)uninstallSurface {
    self.surface.focusChanged = nil;
    if (self.surface.superview == self)
        [self.surface removeFromSuperview];
    self.surface = nil;
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled {
    [super setUserInteractionEnabled:userInteractionEnabled];
    self.surface.userInteractionEnabled = userInteractionEnabled;
    [self _updateFocusButton];
}

- (void)setControlKey:(UIButton *)controlKey {
    _controlKey = controlKey;
    self.surface.controlKey = controlKey;
}

#pragma mark Focus

- (BOOL)canBecomeFirstResponder {
    return _canBecomeFirstResponder;
}

- (BOOL)becomeFirstResponder {
    if (!self.canBecomeFirstResponder || self.surface == nil)
        return NO;
    return [self.surface becomeFirstResponder];
}

- (BOOL)resignFirstResponder {
    return [self.surface resignFirstResponder];
}

- (BOOL)isFirstResponder {
    return self.surface.isFirstResponder;
}

- (void)setInputAccessoryView:(UIInputView *)inputAccessoryView {
    _inputAccessoryView = inputAccessoryView;
    self.surface.accessoryView = inputAccessoryView;
}

- (void)reloadInputViews {
    [self.surface reloadInputViews];
}

- (void)setKeyboardAppearance:(UIKeyboardAppearance)keyboardAppearance {
    BOOL needsFirstResponderDance = self.isFirstResponder && _keyboardAppearance != keyboardAppearance;
    _keyboardAppearance = keyboardAppearance;
    self.surface.keyboardAppearance = keyboardAppearance;
    if (needsFirstResponderDance)
        [self.surface reloadInputViews];
}

- (IBAction)loseFocus:(id)sender {
    [self resignFirstResponder];
}

#pragma mark Focus button

// A small button in the bottom left corner that brings the keyboard back. It is only
// shown while the terminal is not focused, because with mouse tracking applications a
// tap is a click and no longer focuses the terminal.
- (UIButton *)focusButton {
    if (_focusButton == nil) {
        UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightMedium];
        UIImage *image = [UIImage systemImageNamed:@"keyboard" withConfiguration:symbol];
        UIButtonConfiguration *config;
        if (@available(iOS 26.0, *)) {
            config = [UIButtonConfiguration glassButtonConfiguration];
        } else {
            config = [UIButtonConfiguration grayButtonConfiguration];
        }
        config.image = image;
        config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
        config.contentInsets = NSDirectionalEdgeInsetsMake(8, 8, 8, 8);
        UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
        [button addTarget:self action:@selector(focusButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
        button.accessibilityLabel = @"Show Keyboard";
        button.pointerInteractionEnabled = YES;
        button.translatesAutoresizingMaskIntoConstraints = NO;
        button.hidden = YES;
        [self addSubview:button];
        UILayoutGuide *safe = self.safeAreaLayoutGuide;
        [NSLayoutConstraint activateConstraints:@[
            [button.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
            [button.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-8],
            [button.widthAnchor constraintEqualToConstant:36],
            [button.heightAnchor constraintEqualToConstant:36],
        ]];
        _focusButton = button;
    }
    return _focusButton;
}

- (void)focusButtonPressed:(id)sender {
    [self becomeFirstResponder];
}

- (void)_updateFocusButton {
    BOOL show = self.surface != nil && self.canBecomeFirstResponder && self.userInteractionEnabled && !self.surface.isFirstResponder;
    if (!show && _focusButton == nil)
        return;
    UIButton *button = self.focusButton;
    if (button.hidden == !show)
        return;
    [self bringSubviewToFront:button];
    if (show) {
        button.alpha = 0;
        button.hidden = NO;
    }
    [UIView animateWithDuration:0.2 animations:^{
        button.alpha = show ? 1 : 0;
    } completion:^(BOOL finished) {
        if (!show && finished)
            button.hidden = YES;
    }];
}

#pragma mark Input

- (void)insertText:(NSString *)text {
    [self.surface insertText:text];
}

- (void)paste:(id)sender {
    NSString *string = UIPasteboard.generalPasteboard.string;
    if (string)
        [self.surface insertText:string];
}

- (void)clearScrollback:(UIKeyCommand *)command {
    [self.surface clearScrollbackBuffer];
}

- (NSArray<UIKeyCommand *> *)keyCommands {
    // Everything else, including Ctrl/Option/arrow handling, is done by the surface itself.
    return @[[UIKeyCommand commandWithTitle:@"Clear Scrollback"
                                      image:nil
                                     action:@selector(clearScrollback:)
                                      input:@"k"
                              modifierFlags:UIKeyModifierCommand | UIKeyModifierShift
                               propertyList:nil]];
}

- (void)_updateKeyboardPreferences {
    UserPreferences *prefs = UserPreferences.shared;
    self.surface.optionSendsEscape = prefs.optionMapping == OptionMapEsc;
    self.surface.backtickMapsEscape = prefs.backtickMapEscape;
    self.surface.overrideControlSpace = prefs.overrideControlSpace;
    self.surface.capsLockMapping = prefs.capsLockMapping;
}

#pragma mark Styling

- (void)_updateStyle {
    NSAssert(NSThread.isMainThread, @"This method needs to be called on the main thread");
    if (self.surface == nil)
        return;
    UserPreferences *prefs = UserPreferences.shared;
    if (_overrideFontSize == prefs.fontSize.doubleValue)
        _overrideFontSize = 0;
    Palette *palette = prefs.palette;
    if (self.overrideAppearance != OverrideAppearanceNone) {
        palette = self.overrideAppearance == OverrideAppearanceLight ? prefs.theme.lightPalette : prefs.theme.darkPalette;
    }

    UIFont *font = [self fontWithFamily:prefs.fontFamily size:self.effectiveFontSize];
    UIColor *foreground = [[UIColor alloc] ish_initWithHexString:palette.foregroundColor];
    UIColor *background = [[UIColor alloc] ish_initWithHexString:palette.backgroundColor];
    UIColor *cursor = palette.cursorColor ? [[UIColor alloc] ish_initWithHexString:palette.cursorColor] : nil;
    NSMutableArray<UIColor *> *colors = nil;
    if (palette.colorPaletteOverrides.count >= 16) {
        colors = [NSMutableArray new];
        for (NSString *hex in [palette.colorPaletteOverrides subarrayWithRange:NSMakeRange(0, 16)]) {
            UIColor *color = [[UIColor alloc] ish_initWithHexString:hex];
            if (color == nil) {
                colors = nil;
                break;
            }
            [colors addObject:color];
        }
    }
    [self.surface applyStyleWithFont:font
                          foreground:foreground ?: UIColor.labelColor
                          background:background ?: UIColor.systemBackgroundColor
                              cursor:cursor
                             palette:colors
                         cursorShape:prefs.cursorStyle
                               blink:prefs.blinkCursor];
}

- (UIFont *)fontWithFamily:(NSString *)family size:(CGFloat)size {
    UIFont *font = nil;
    if (family != nil && ![family isEqualToString:@"ui-monospace"])
        font = [UIFont fontWithName:family size:size];
    return font ?: [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightRegular];
}

- (void)setOverrideFontSize:(CGFloat)overrideFontSize {
    _overrideFontSize = overrideFontSize;
    [self _updateStyle];
}

- (void)setOverrideAppearance:(enum OverrideAppearance)overrideAppearance {
    _overrideAppearance = overrideAppearance;
    [self _updateStyle];
}

- (CGFloat)effectiveFontSize {
    if (self.overrideFontSize != 0)
        return self.overrideFontSize;
    return UserPreferences.shared.fontSize.doubleValue;
}

// Not an accessibility element itself; the surface is.
- (BOOL)isAccessibilityElement { return NO; }

@end
