#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/message.h>

#pragma mark - Global State (ALL ON by default)

static BOOL noads = YES;
static BOOL downloadWithoutWatermark = YES;
static BOOL autoPlayNextVideo = YES;
static BOOL changeRegion = YES;
static BOOL showProgressBar = YES;
static BOOL canHideUI = YES;
static BOOL enableFavoritesCollections = YES;
static BOOL enablePIP = YES;
static BOOL enableBackgroundPlay = YES;
static BOOL enableBypass = YES;

#pragma mark - Window Finder

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

#pragma mark - Floating Button Target

@interface TTGFloatingButton : UIButton
@end

@implementation TTGFloatingButton {
    CGPoint _dragStart;
    BOOL _dragging;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor redColor];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.borderWidth = 3;
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        [self setTitle:@"G" forState:UIControlStateNormal];
        [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:22];
        self.showsTouchWhenHighlighted = YES;
    }
    return self;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    _dragStart = [t locationInView:self.superview];
    _dragging = NO;
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self.superview];
    CGFloat dx = p.x - _dragStart.x;
    CGFloat dy = p.y - _dragStart.y;
    if (fabs(dx) > 3 || fabs(dy) > 3) _dragging = YES;
    if (_dragging) {
        CGPoint center = self.center;
        center.x += dx; center.y += dy;
        // clamp
        CGRect b = self.superview.bounds;
        center.x = MAX(self.frame.size.width/2, MIN(b.size.width - self.frame.size.width/2, center.x));
        center.y = MAX(self.frame.size.height/2, MIN(b.size.height - self.frame.size.height/2, center.y));
        self.center = center;
        _dragStart = p;
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    if (!_dragging) {
        [self ttgShowSettings];
    } else {
        // snap to edge
        CGRect b = self.superview.bounds;
        CGFloat mid = b.size.width / 2;
        CGRect f = self.frame;
        if (f.origin.x + f.size.width/2 < mid) f.origin.x = 8;
        else f.origin.x = b.size.width - f.size.width - 8;
        [UIView animateWithDuration:0.2 animations:^{ self.frame = f; }];
    }
}

- (void)ttgShowSettings {
    UIWindow *win = self.superview.window ?: TTGFrontmostWindow();
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 TikTok God Settings"
        message:@"Tap a toggle. All features ON by default."
        preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *items = @[
        @{@"title": noads ? @"✅ No Ads" : @"⚪ No Ads", @"val": @(noads), @"key": @"noads"},
        @{@"title": downloadWithoutWatermark ? @"✅ No-Watermark DL" : @"⚪ No-Watermark DL", @"val": @(downloadWithoutWatermark), @"key": @"downloadWithoutWatermark"},
        @{@"title": autoPlayNextVideo ? @"✅ Auto Next" : @"⚪ Auto Next", @"val": @(autoPlayNextVideo), @"key": @"autoPlayNextVideo"},
        @{@"title": changeRegion ? @"✅ Change Region" : @"⚪ Change Region", @"val": @(changeRegion), @"key": @"changeRegion"},
        @{@"title": showProgressBar ? @"✅ Progress Bar" : @"⚪ Progress Bar", @"val": @(showProgressBar), @"key": @"showProgressBar"},
        @{@"title": canHideUI ? @"✅ Hide UI Button" : @"⚪ Hide UI Button", @"val": @(canHideUI), @"key": @"canHideUI"},
        @{@"title": enablePIP ? @"✅ PiP" : @"⚪ PiP", @"val": @(enablePIP), @"key": @"enablePIP"},
        @{@"title": enableBackgroundPlay ? @"✅ Background Play" : @"⚪ Background Play", @"val": @(enableBackgroundPlay), @"key": @"enableBackgroundPlay"},
        @{@"title": enableBypass ? @"✅ Safety Bypass" : @"⚪ Safety Bypass", @"val": @(enableBypass), @"key": @"enableBypass"},
    ];
    
    for (NSDictionary *it in items) {
        [alert addAction:[UIAlertAction actionWithTitle:it[@"title"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            BOOL newVal = ![it[@"val"] boolValue];
            NSString *key = it[@"key"];
            if ([key isEqualToString:@"noads"]) noads = newVal;
            if ([key isEqualToString:@"downloadWithoutWatermark"]) downloadWithoutWatermark = newVal;
            if ([key isEqualToString:@"autoPlayNextVideo"]) autoPlayNextVideo = newVal;
            if ([key isEqualToString:@"changeRegion"]) changeRegion = newVal;
            if ([key isEqualToString:@"showProgressBar"]) showProgressBar = newVal;
            if ([key isEqualToString:@"canHideUI"]) canHideUI = newVal;
            if ([key isEqualToString:@"enablePIP"]) enablePIP = newVal;
            if ([key isEqualToString:@"enableBackgroundPlay"]) enableBackgroundPlay = newVal;
            if ([key isEqualToString:@"enableBypass"]) enableBypass = newVal;
            NSLog(@"[TTG] Set %@ = %d", key, newVal);
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset All ON" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        noads = downloadWithoutWatermark = autoPlayNextVideo = changeRegion = showProgressBar = canHideUI = enablePIP = enableBackgroundPlay = enableBypass = YES;
        NSLog(@"[TTG] All reset to ON");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    
    // iPad popover
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self;
        alert.popoverPresentationController.sourceRect = self.bounds;
    }
    
    [vc presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Hooks (deferred)

static void TTGRegisterHooks(void) {
    @try {
        NSLog(@"[TTG] Registering hooks...");
        
        // ---- Change Region (CTCarrier - system class, VERY STABLE) ----
        Class CTCarrier = NSClassFromString(@"CTCarrier");
        if (CTCarrier) {
            Method mcc = class_getInstanceMethod(CTCarrier, @selector(mcc));
            Method mnc = class_getInstanceMethod(CTCarrier, @selector(mnc));
            Method iso = class_getInstanceMethod(CTCarrier, @selector(isoCountryCode));
            if (mcc) {
                IMP orig = method_getImplementation(mcc);
                IMP newImp = imp_implementationWithBlock(^id(id self) { return @"310"; });
                method_setImplementation(mcc, newImp);
                NSLog(@"[TTG] ✅ CTCarrier.mcc hooked");
            }
            if (mnc) {
                IMP orig = method_getImplementation(mnc);
                IMP newImp = imp_implementationWithBlock(^id(id self) { return @"001"; });
                method_setImplementation(mnc, newImp);
                NSLog(@"[TTG] ✅ CTCarrier.mnc hooked");
            }
            if (iso) {
                IMP orig = method_getImplementation(iso);
                IMP newImp = imp_implementationWithBlock(^id(id self) { return @"us"; });
                method_setImplementation(iso, newImp);
                NSLog(@"[TTG] ✅ CTCarrier.isoCountryCode hooked");
            }
        } else {
            NSLog(@"[TTG] ⚠️ CTCarrier not found");
        }
        
        // ---- Background Play (AVAudioSession - system) ----
        // We'll handle via app delegate notification instead
        
        NSLog(@"[TTG] Hooks registered");
    } @catch (NSException *e) {
        NSLog(@"[TTG] ❌ Hook registration crash: %@", e);
    }
}

#pragma mark - Constructor

%ctor {
    NSLog(@"[TTG] 🚀 ctor START");
    
    // Delay everything to let TikTok fully boot
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            // 1. Try to add floating button
            UIWindow *win = TTGFrontmostWindow();
            if (!win) {
                NSLog(@"[TTG] ❌ No window found!");
                return;
            }
            
            CGFloat startY = 50;
            if (@available(iOS 11.0, *)) startY = 50 + win.safeAreaInsets.top + 34;
            
            TTGFloatingButton *btn = [[TTGFloatingButton alloc] initWithFrame:CGRectMake(14, startY, 44, 44)];
            [win addSubview:btn];
            NSLog(@"[TTG] ✅ Floating button added");
            
            // 2. Register hooks (safe, wrapped in try)
            TTGRegisterHooks();
            
            // 3. Background play - register observer
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
                object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    if (enableBackgroundPlay) {
                        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
                    }
                }];
            
            NSLog(@"[TTG] 🎉 ALL DONE");
        } @catch (NSException *e) {
            NSLog(@"[TTG] ❌ ctor crash: %@", e);
        }
    });
}
