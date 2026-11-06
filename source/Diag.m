//
// TTG Diagnostic dylib — minimal test to confirm injection actually works
//
// If this alert DOES NOT appear, the problem is:
//   - LCSign injection didn't actually add LC_LOAD_DYLIB to the main binary, OR
//   - LCSign didn't re-sign the dylib with your Apple ID (dyld Team ID mismatch), OR
//   - Free Apple ID can't load external dylibs (unlikely but possible)
//
// If this alert DOES appear, then our full dylib has a real code bug.
//

#import <UIKit/UIKit.h>
#import <objc/message.h>

// Force constructor — logos internal generator handles this automatically
__attribute__((constructor))
static void ttg_diag_constructor(void) {
    NSLog(@"[TTG-DIAG] ======== DYLIB LOADED BY DYLD ========");
    NSLog(@"[TTG-DIAG] If you see this in Xcode Console, injection works!");

    // Try to show alert 3 times with increasing delays (UI might not be ready)
    for (int i = 0; i < 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            // Find top VC
            UIViewController *vc = nil;
            UIWindow *keyWin = nil;
            if (@available(iOS 13.0, *)) {
                for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
                    if ([s isKindOfClass:NSClassFromString(@"UIWindowScene")] && s.activationState == UISceneActivationStateForegroundActive) {
                        id ws = s;
                        NSArray *windows = [ws windows];
                        keyWin = windows.firstObject;
                        break;
                    }
                }
            }
            if (!keyWin) keyWin = [UIApplication sharedApplication].keyWindow;
            vc = keyWin.rootViewController;
            while (vc.presentedViewController) vc = vc.presentedViewController;

            if (vc) {
                NSLog(@"[TTG-DIAG] Presenting alert on attempt %d", i);
                UIAlertController *a = [UIAlertController alertControllerWithTitle:@"🎉 注入成功!"
                                                                             message:@"如果你看到这个弹窗，说明 dylib 加载成功了！\n\n但主版本 tiktokgod.dylib 的窗口代码有 bug，请让作者修复。"
                                                                      preferredStyle:UIAlertControllerStyleAlert];
                [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [vc presentViewController:a animated:YES completion:nil];
            } else {
                NSLog(@"[TTG-DIAG] No top VC yet on attempt %d", i);
            }
        });
    }
}
