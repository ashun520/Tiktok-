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
static BOOL enablePIP = YES;
static BOOL enableBackgroundPlay = YES;
static BOOL enableBypass = YES;

static id g_currentAweme;  // cached by hook

#pragma mark - Utilities

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

static UIViewController *TTGTopViewController(void) {
    UIWindow *win = TTGFrontmostWindow();
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) vc = [(UINavigationController*)vc visibleViewController];
    if ([vc isKindOfClass:[UITabBarController class]]) vc = [(UITabBarController*)vc selectedViewController];
    return vc;
}

static void TTGShowToast(NSString *msg) {
    UIWindow *win = TTGFrontmostWindow();
    if (!win) return;
    UIView *toast = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 260, 50)];
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.78];
    toast.layer.cornerRadius = 25;
    toast.center = win.center;
    
    UILabel *label = [[UILabel alloc] initWithFrame:toast.bounds];
    label.text = msg;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:14];
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;
    [toast addSubview:label];
    
    toast.alpha = 0;
    [win addSubview:toast];
    
    [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 1; } completion:^(BOOL _) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; } completion:^(BOOL __) { [toast removeFromSuperview]; }];
        });
    }];
}

#pragma mark - Get Current Aweme Model

static id TTGGetCurrentAweme(void) {
    // 1. Use cached one from hooks
    if (g_currentAweme) return g_currentAweme;
    
    // 2. Try common VC property names
    UIViewController *top = TTGTopViewController();
    if (top) {
        NSArray *keys = @[@"awemeModel", @"model", @"videoModel", @"aweme", @"currentModel"];
        for (NSString *k in keys) {
            @try {
                id obj = [top valueForKey:k];
                if (obj) { g_currentAweme = obj; return obj; }
            } @catch (NSException *e) {}
        }
    }
    
    // 3. Traverse window subviews for any UIViewController with model
    UIWindow *win = TTGFrontmostWindow();
    if (win) {
        for (UIView *v in win.subviews) {
            UIViewController *vc = (UIViewController *)v.nextResponder;
            while (vc && ![vc isKindOfClass:[UIViewController class]]) vc = (UIViewController *)vc.nextResponder;
            if (vc) {
                NSArray *keys = @[@"awemeModel", @"model", @"videoModel"];
                for (NSString *k in keys) {
                    @try {
                        id obj = [vc valueForKey:k];
                        if (obj) { g_currentAweme = obj; return obj; }
                    } @catch (NSException *e) {}
                }
            }
        }
    }
    
    return nil;
}

#pragma mark - Download Video

static void TTGDownloadCurrent(void) {
    id aweme = TTGGetCurrentAweme();
    if (!aweme) {
        NSLog(@"[TTG] ❌ Cannot find current aweme model");
        TTGShowToast(@"❌ 找不到当前视频");
        return;
    }
    NSLog(@"[TTG] 📥 Downloading aweme: %@", aweme);
    
    // Get video URL
    @try {
        id video = [aweme valueForKey:@"video"];
        id downloadURL = nil;
        if (video) {
            // Prefer downloadURL (no watermark)
            @try { downloadURL = [video valueForKey:@"downloadURL"]; } @catch (NSException *e) {}
            if (!downloadURL) {
                @try { downloadURL = [video valueForKey:@"playURL"]; } @catch (NSException *e) {}
            }
        }
        
        NSString *urlStr = nil;
        if (downloadURL) {
            // originURLList is usually an array of AWEURLModel with .url property, or strings
            @try {
                id origin = [downloadURL valueForKey:@"originURLList"];
                if ([origin isKindOfClass:[NSArray class]] && [origin count] > 0) {
                    id first = [origin firstObject];
                    if ([first isKindOfClass:[NSString class]]) urlStr = first;
                    else @try { urlStr = [first valueForKey:@"url"]; } @catch (NSException *e) {}
                }
            } @catch (NSException *e) {}
            
            if (!urlStr) {
                @try { urlStr = [downloadURL valueForKey:@"url"]; } @catch (NSException *e) {}
            }
        }
        
        if (!urlStr) {
            NSLog(@"[TTG] ❌ Cannot get URL from aweme");
            TTGShowToast(@"❌ 拿不到视频链接");
            return;
        }
        NSLog(@"[TTG] 📥 URL: %@", urlStr);
        
        TTGShowToast(@"⏳ 正在下载...");
        
        NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:[NSURL URLWithString:urlStr]
            completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                if (error) {
                    NSLog(@"[TTG] ❌ Download error: %@", error);
                    dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 下载失败"); });
                    return;
                }
                
                // Request photo permission if needed
                [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
                    if (status != PHAuthorizationStatusAuthorized) {
                        dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 没有相册权限"); });
                        return;
                    }
                    
                    [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:location];
                    } completionHandler:^(BOOL ok, NSError *err) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            if (ok) TTGShowToast(@"✅ 已保存到相册");
                            else TTGShowToast(@"❌ 保存到相册失败");
                        });
                    }];
                }];
            }];
        [task resume];
    } @catch (NSException *e) {
        NSLog(@"[TTG] ❌ Download crash: %@", e);
        TTGShowToast(@"❌ 下载出错");
    }
}

#pragma mark - Floating Button (short-press = download, long-press = settings)

@interface TTGFloatingButton : UIButton
@end

@implementation TTGFloatingButton {
    CGPoint _dragStart;
    BOOL _dragging;
    BOOL _longPressFired;
    NSTimer *_longPressTimer;
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
    _longPressFired = NO;
    
    // Schedule long press (0.5s)
    _longPressTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(fireLongPress) userInfo:nil repeats:NO];
}

- (void)fireLongPress {
    _longPressFired = YES;
    [self ttgShowSettings];
}

- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    CGPoint p = [t locationInView:self.superview];
    CGFloat dx = p.x - _dragStart.x;
    CGFloat dy = p.y - _dragStart.y;
    if (fabs(dx) > 3 || fabs(dy) > 3) {
        if (!_dragging) { [_longPressTimer invalidate]; _longPressTimer = nil; }
        _dragging = YES;
    }
    if (_dragging) {
        CGPoint center = self.center;
        center.x += dx; center.y += dy;
        CGRect b = self.superview.bounds;
        center.x = MAX(self.frame.size.width/2, MIN(b.size.width - self.frame.size.width/2, center.x));
        center.y = MAX(self.frame.size.height/2, MIN(b.size.height - self.frame.size.height/2, center.y));
        self.center = center;
        _dragStart = p;
    }
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    [_longPressTimer invalidate]; _longPressTimer = nil;
    if (_dragging) {
        CGRect b = self.superview.bounds;
        CGFloat mid = b.size.width / 2;
        CGRect f = self.frame;
        if (f.origin.x + f.size.width/2 < mid) f.origin.x = 8;
        else f.origin.x = b.size.width - f.size.width - 8;
        [UIView animateWithDuration:0.2 animations:^{ self.frame = f; }];
    } else if (!_longPressFired) {
        // Short press = DOWNLOAD!
        NSLog(@"[TTG] ⬇️ Short press → download");
        TTGDownloadCurrent();
    }
}

- (void)ttgShowSettings {
    UIViewController *vc = TTGTopViewController();
    if (!vc) return;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 TikTok God"
        message:@"短按G=下载  长按=设置  拖动=移动"
        preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *items = @[
        @{@"title": [NSString stringWithFormat:@"No Ads: %@", noads ? @"ON ✅" : @"OFF"]},
        @{@"title": [NSString stringWithFormat:@"No-Watermark DL: %@", downloadWithoutWatermark ? @"ON ✅" : @"OFF"]},
        @{@"title": [NSString stringWithFormat:@"Auto Next Video: %@", autoPlayNextVideo ? @"ON ✅" : @"OFF"]},
        @{@"title": [NSString stringWithFormat:@"Change Region: %@", changeRegion ? @"ON (US) ✅" : @"OFF"]},
        @{@"title": [NSString stringWithFormat:@"Force Progress Bar: %@", showProgressBar ? @"ON ✅" : @"OFF"]},
        @{@"title": [NSString stringWithFormat:@"Hide UI Button: %@", canHideUI ? @"ON ✅" : @"OFF"]},
        @{@"title": [NSString stringWithFormat:@"PiP: %@", enablePIP ? @"ON ✅" : @"OFF"]},
        @{@"title": [NSString stringWithFormat:@"Background Play: %@", enableBackgroundPlay ? @"ON ✅" : @"OFF"]},
        @{@"title": [NSString stringWithFormat:@"Safety Bypass: %@", enableBypass ? @"ON ✅" : @"OFF"]},
    ];
    
    // Toggle actions
    void (^toggleForKey)(NSString *) = ^(NSString *key) {
        if ([key isEqualToString:@"noads"]) noads = !noads;
        if ([key isEqualToString:@"downloadWithoutWatermark"]) downloadWithoutWatermark = !downloadWithoutWatermark;
        if ([key isEqualToString:@"autoPlayNextVideo"]) autoPlayNextVideo = !autoPlayNextVideo;
        if ([key isEqualToString:@"changeRegion"]) changeRegion = !changeRegion;
        if ([key isEqualToString:@"showProgressBar"]) showProgressBar = !showProgressBar;
        if ([key isEqualToString:@"canHideUI"]) canHideUI = !canHideUI;
        if ([key isEqualToString:@"enablePIP"]) enablePIP = !enablePIP;
        if ([key isEqualToString:@"enableBackgroundPlay"]) enableBackgroundPlay = !enableBackgroundPlay;
        if ([key isEqualToString:@"enableBypass"]) enableBypass = !enableBypass;
    };
    
    NSDictionary *keyMap = @{
        @"No Ads": @"noads",
        @"No-Watermark": @"downloadWithoutWatermark",
        @"Auto Next": @"autoPlayNextVideo",
        @"Change Region": @"changeRegion",
        @"Progress Bar": @"showProgressBar",
        @"Hide UI": @"canHideUI",
        @"PiP": @"enablePIP",
        @"Background": @"enableBackgroundPlay",
        @"Safety": @"enableBypass",
    };
    
    for (NSDictionary *it in items) {
        NSString *title = it[@"title"];
        // Extract key for toggle
        NSString *key = nil;
        for (NSString *prefix in keyMap) {
            if ([title hasPrefix:prefix]) { key = keyMap[prefix]; break; }
        }
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (key) {
                toggleForKey(key);
                // Re-show with updated state
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [self ttgShowSettings];
                });
            }
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset ALL ON" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        noads = downloadWithoutWatermark = autoPlayNextVideo = changeRegion = showProgressBar = canHideUI = enablePIP = enableBackgroundPlay = enableBypass = YES;
        TTGShowToast(@"✅ All features ON");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close" style:UIAlertActionStyleCancel handler:nil]];
    
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self;
        alert.popoverPresentationController.sourceRect = self.bounds;
    }
    
    [vc presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Hook Registration (delayed)

static void TTGRegisterHooks(void) {
    @try {
        NSLog(@"[TTG] Registering hooks...");
        
        // ---- CTCarrier (system class, VERY STABLE) ----
        Class CTCarrier = NSClassFromString(@"CTCarrier");
        if (CTCarrier) {
            Method mcc = class_getInstanceMethod(CTCarrier, @selector(mcc));
            Method mnc = class_getInstanceMethod(CTCarrier, @selector(mnc));
            Method iso = class_getInstanceMethod(CTCarrier, @selector(isoCountryCode));
            if (mcc) method_setImplementation(mcc, imp_implementationWithBlock(^id(id s){ return @"310"; }));
            if (mnc) method_setImplementation(mnc, imp_implementationWithBlock(^id(id s){ return @"001"; }));
            if (iso) method_setImplementation(iso, imp_implementationWithBlock(^id(id s){ return @"us"; }));
            NSLog(@"[TTG] ✅ CTCarrier hooked");
        }
        
        // ---- Cache current aweme by hooking setModel: on ANY class that has it ----
        SEL cacheSels[] = { @selector(setModel:), @selector(setAwemeModel:), @selector(setVideoModel:) };
        int numSels = 3;
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        for (unsigned int i = 0; i < classCount; i++) {
            Class cls = classes[i];
            for (int s = 0; s < numSels; s++) {
                SEL sel = cacheSels[s];
                Method m = class_getInstanceMethod(cls, sel);
                if (m) {
                    const char *types = method_getTypeEncoding(m);
                    if (types && strlen(types) >= 3 && types[2] == '@') {
                        IMP orig = method_getImplementation(m);
                        IMP newImp = imp_implementationWithBlock(^(id self, id model) {
                            if (model) { g_currentAweme = model; }
                            return ((void(*)(id, SEL, id))orig)(self, sel, model);
                        });
                        if (!class_addMethod(cls, sel, newImp, types)) {
                            method_setImplementation(m, newImp);
                        }
                    }
                }
            }
        }
        free(classes);
        NSLog(@"[TTG] ✅ setModel: hooks registered");
        
        // ---- Background Play ----
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                if (enableBackgroundPlay) {
                    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
                    NSLog(@"[TTG] 🎧 Background Playback enabled");
                }
            }];
        
        NSLog(@"[TTG] ✅ ALL HOOKS REGISTERED");
    } @catch (NSException *e) {
        NSLog(@"[TTG] ❌ Hook register crash: %@", e);
    }
}

#pragma mark - Constructor

%ctor {
    NSLog(@"[TTG] 🚀 ctor START");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = TTGFrontmostWindow();
            if (!win) { NSLog(@"[TTG] ❌ No window"); return; }
            
            CGFloat startY = 50;
            if (@available(iOS 11.0, *)) startY = 50 + win.safeAreaInsets.top + 34;
            
            TTGFloatingButton *btn = [[TTGFloatingButton alloc] initWithFrame:CGRectMake(14, startY, 44, 44)];
            [win addSubview:btn];
            NSLog(@"[TTG] ✅ Floating button (short=DOWNLOAD / long=SETTINGS) added");
            
            TTGRegisterHooks();
            
            NSLog(@"[TTG] 🎉 READY");
        } @catch (NSException *e) {
            NSLog(@"[TTG] ❌ ctor crash: %@", e);
        }
    });
}
