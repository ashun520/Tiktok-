// MINIMAL TEST — NO HOOKS, NO OBJC CLASSES, JUST CTOR + ALERT
#import <UIKit/UIKit.h>
#import <objc/message.h>

static UIWindow *TTGFrontmostWindow(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:NSClassFromString(@"UIWindowScene")] && scene.activationState == UISceneActivationStateForegroundActive) {
                for (UIWindow *w in [(id)scene windows]) { if (w.isKeyWindow || !w.isHidden) return w; }
            }
        }
    }
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (kw) return kw;
    for (UIWindow *w in [UIApplication sharedApplication].windows) { if (!w.isHidden) return w; }
    return nil;
}

%ctor {
    NSLog(@"[TTG-MIN] ctor START");
    int maxAttempts = 60;
    __block int attempt = 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
#pragma clang diagnostic ignored "-Wuninitialized"
    __block void (^tryShow)(void);
    tryShow = ^{
        if (attempt >= maxAttempts) { NSLog(@"[TTG-MIN] GAVE UP"); return; }
        attempt++;
        @try {
            UIWindow *win = TTGFrontmostWindow();
            if (!win) {
                NSLog(@"[TTG-MIN] attempt %d: no window", attempt);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), tryShow);
                return;
            }
            UIViewController *vc = win.rootViewController;
            while (vc.presentedViewController) vc = vc.presentedViewController;
            if (!vc) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), tryShow);
                return;
            }
            NSLog(@"[TTG-MIN] SUCCESS on attempt %d! Presenting alert...", attempt);
            
            // Attach button FIRST (so it appears regardless of alert dismissal)
            CGFloat startY = 60;
            if (@available(iOS 11.0, *)) startY = 50 + win.safeAreaInsets.top + 34;
            UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
            btn.frame = CGRectMake(14, startY, 44, 44);
            btn.backgroundColor = [UIColor redColor];
            btn.layer.cornerRadius = 22;
            btn.layer.borderWidth = 3;
            btn.layer.borderColor = [UIColor whiteColor].CGColor;
            [btn setTitle:@"G" forState:UIControlStateNormal];
            [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            btn.titleLabel.font = [UIFont boldSystemFontOfSize:22];
            btn.showsTouchWhenHighlighted = YES;
            [win addSubview:btn];
            NSLog(@"[TTG-MIN] BUTTON ADDED to window!");
            
            UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 TTG-MIN WORKS!"
                message:@"If you see this, the dylib constructor fired. Now I'll try adding hooks back."
                preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [vc presentViewController:alert animated:YES completion:nil];
            
        } @catch (NSException *e) {
            NSLog(@"[TTG-MIN] CRASH: %@", e);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), tryShow);
        }
    };
#pragma clang diagnostic pop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), tryShow);
}
