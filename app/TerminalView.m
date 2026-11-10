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
@end

@implementation TerminalView
@synthesize canBecomeFirstResponder = _canBecomeFirstResponder;
@synthesize inputAccessoryView = _inputAccessoryView;

- (void)awakeFromNib {
    [super awakeFromNib];
    UserPreferences *prefs = UserPreferences.shared;
    [prefs observe:@[@"optionMapping", @"backtickMapEscape", @"overrideControlSpace"]
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
    surface.frame = self.bounds;
    surface.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    surface.userInteractionEnabled = self.userInteractionEnabled;
    surface.controlKey = self.controlKey;
    surface.accessoryView = self.inputAccessoryView;
    surface.keyboardAppearance = self.keyboardAppearance;
    self.surface = surface;
    [self addSubview:surface];
    self.opaque = NO;
    [self _updateKeyboardPreferences];
    [self _updateStyle];
}

- (void)uninstallSurface {
    if (self.surface.superview == self)
        [self.surface removeFromSuperview];
    self.surface = nil;
}

- (void)setUserInteractionEnabled:(BOOL)userInteractionEnabled {
    [super setUserInteractionEnabled:userInteractionEnabled];
    self.surface.userInteractionEnabled = userInteractionEnabled;
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
