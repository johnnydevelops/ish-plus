//
//  TerminalView.h
//  iSH
//
//  Created by Theodore Dubois on 11/3/17.
//

#import <UIKit/UIKit.h>
#import "Terminal.h"

enum OverrideAppearance {
    OverrideAppearanceNone,
    OverrideAppearanceLight,
    OverrideAppearanceDark,
};

// Hosts the native terminal surface of the current Terminal session and
// forwards focus, input accessory and styling to it.
@interface TerminalView : UIView

@property IBInspectable (nonatomic) BOOL canBecomeFirstResponder;

@property (nonatomic) CGFloat overrideFontSize;
@property (readonly) CGFloat effectiveFontSize;
@property (nonatomic) enum OverrideAppearance overrideAppearance;

@property (nonatomic) UIKeyboardAppearance keyboardAppearance;

@property (weak, nonatomic) IBOutlet UIInputView *inputAccessoryView;
@property (weak, nonatomic) IBOutlet UIButton *controlKey;

@property (nonatomic) Terminal *terminal;

// Types text into the terminal as if from the keyboard (honours the Ctrl key).
- (void)insertText:(NSString *)text;

@end
