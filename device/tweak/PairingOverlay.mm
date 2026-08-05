#import "PairingOverlay.h"
#import "InputInjector.h"
#import "DisplayController.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static UIWindow *gPairingWindow = nil;
static dispatch_block_t gHideBlock = nil;

static void hidePairingCodeOnMain(void) {
    if (gHideBlock) {
        dispatch_block_cancel(gHideBlock);
        gHideBlock = nil;
    }
    gPairingWindow.hidden = YES;
    gPairingWindow.rootViewController = nil;
    gPairingWindow = nil;
}

static UILabel *makeLabel(CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [UIFont systemFontOfSize:size weight:weight];
    label.textColor = color;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    return label;
}

void IOSPYHidePairingCode(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        hidePairingCodeOnMain();
    });
}

void IOSPYShowPairingCode(NSString *code, NSString *hostName, NSTimeInterval timeout) {
    if (code.length != 4) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        IOSPYRestoreDisplayForLocalInput();
        IOSPYSystemAction(3); // wake; never unlock or bypass the passcode
        hidePairingCodeOnMain();

        CGRect bounds = UIScreen.mainScreen.bounds;
        UIWindow *window = [[UIWindow alloc] initWithFrame:bounds];
        window.windowLevel = UIWindowLevelAlert + 2500;
        window.backgroundColor = UIColor.clearColor;
        window.userInteractionEnabled = NO;

        UIViewController *controller = [[UIViewController alloc] init];
        controller.view.backgroundColor = UIColor.clearColor;
        window.rootViewController = controller;

        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
        UIVisualEffectView *card = [[UIVisualEffectView alloc] initWithEffect:blur];
        card.translatesAutoresizingMaskIntoConstraints = NO;
        card.layer.cornerRadius = 28;
        card.layer.cornerCurve = kCACornerCurveContinuous;
        card.clipsToBounds = YES;
        [controller.view addSubview:card];

        UILabel *title = makeLabel(18, UIFontWeightSemibold, UIColor.whiteColor);
        title.text = @"ioscpy 配对";
        UILabel *subtitle = makeLabel(13, UIFontWeightRegular,
                                      [UIColor.whiteColor colorWithAlphaComponent:0.72]);
        subtitle.text = [NSString stringWithFormat:@"%@ 请求连接这台 iPhone",
                         hostName.length ? hostName : @"一台 Mac"];
        UILabel *codeLabel = makeLabel(44, UIFontWeightBold, UIColor.whiteColor);
        codeLabel.font = [UIFont monospacedDigitSystemFontOfSize:44 weight:UIFontWeightBold];
        codeLabel.text = code;
        codeLabel.accessibilityLabel = @"配对码";
        UILabel *footer = makeLabel(12, UIFontWeightRegular,
                                    [UIColor.whiteColor colorWithAlphaComponent:0.58]);
        footer.text = @"请只在你自己的 Mac 上输入此代码";

        UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[title, subtitle, codeLabel, footer]];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.axis = UILayoutConstraintAxisVertical;
        stack.alignment = UIStackViewAlignmentFill;
        stack.spacing = 10;
        [card.contentView addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [card.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
            [card.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
            [card.widthAnchor constraintLessThanOrEqualToConstant:330],
            [card.widthAnchor constraintEqualToAnchor:controller.view.widthAnchor multiplier:0.78],
            [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:24],
            [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-24],
            [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:22],
            [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-22],
        ]];

        gPairingWindow = window;
        window.hidden = NO;

        NSTimeInterval duration = MAX(10, MIN(timeout, 120));
        dispatch_block_t hide = dispatch_block_create(0, ^{ hidePairingCodeOnMain(); });
        gHideBlock = hide;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(duration * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), hide);
    });
}
