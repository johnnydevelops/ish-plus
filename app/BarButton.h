//
//  AccessoryButton.h
//  iSH
//
//  Created by Theodore Dubois on 9/22/18.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// On iOS 26+ the key bar is a Liquid Glass capsule holding plain keys; earlier
// versions keep the classic keyboard-key look.
static inline BOOL ISHUseGlassBar(void) {
    if (@available(iOS 26.0, *))
        return YES;
    return NO;
}

// Fill for a pressed or latched key inside the glass bar.
static inline UIColor *ISHGlassKeyHighlightColor(UIKeyboardAppearance appearance) {
    return appearance == UIKeyboardAppearanceLight
        ? [UIColor colorWithWhite:0 alpha:0.12]
        : [UIColor colorWithWhite:1 alpha:0.2];
}

@interface BarButton : UIButton

@property (nonatomic) UIKeyboardAppearance keyAppearance;
@property IBInspectable BOOL secondary;
@property IBInspectable BOOL toggleable;

@end

NS_ASSUME_NONNULL_END
