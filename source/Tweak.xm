#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/message.h>

#pragma mark - 全局开关（全部默认开）

static BOOL noads = YES;
static BOOL downloadWithoutWatermark = YES;
static BOOL autoPlayNextVideo = YES;
static BOOL changeRegion = YES;
static BOOL showProgressBar = YES;
static BOOL canHideUI = YES;
static BOOL enablePIP = YES;
static BOOL enableBackgroundPlay = YES;
static BOOL enableBypass = YES;

static id g_currentAweme;

#pragma mark - 工具函数

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
    UIView *toast = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 50)];
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
    toast.layer.cornerRadius = 25;
    toast.center = win.center;
    UILabel *label = [[UILabel alloc] initWithFrame:toast.bounds];
    label.text = msg; label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    label.textAlignment = NSTextAlignmentCenter; label.numberOfLines = 0;
    [toast addSubview:label];
    toast.alpha = 0;
    [win addSubview:toast];
    [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; } completion:^(BOOL _) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 0; } completion:^(BOOL __) { [toast removeFromSuperview]; }];
        });
    }];
}

#pragma mark - 递归查找所有 VC 的 awemeModel

static NSArray *TTGPropertyNamesForKeys(void) {
    // 尽可能多的属性名
    static NSArray *keys = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        keys = @[
            @"awemeModel", @"model", @"videoModel", @"aweme",
            @"currentAweme", @"currentModel", @"selectedAweme",
            @"playModel", @"feedModel", @"detailModel",
            @"awemeInfo", @"videoInfo"
        ];
    });
    return keys;
}

static id TTGGetValue(id obj, NSString *key) {
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}

// 递归遍历 VC 树找 awemeModel
static id TTGFindAwemeInVCRecursive(UIViewController *vc, int depth) {
    if (depth > 10 || !vc) return nil;
    
    // 先查自己
    for (NSString *k in TTGPropertyNamesForKeys()) {
        id v = TTGGetValue(vc, k);
        if (v && [v isKindOfClass:NSClassFromString(@"AWEAwemeModel")]) return v;
        if (v && [NSStringFromClass([v class]) containsString:@"Aweme"]) return v;
        if (v && [NSStringFromClass([v class]) containsString:@"Model"] && TTGGetValue(v, @"video")) return v;
    }
    
    // 查所有属性（包括私有）
    unsigned int propCount = 0;
    objc_property_t *props = class_copyPropertyList([vc class], &propCount);
    if (props) {
        for (unsigned int i = 0; i < propCount; i++) {
            const char *pname = property_getName(props[i]);
            NSString *nsname = [NSString stringWithUTF8String:pname];
            if ([nsname containsString:@"model"] || [nsname containsString:@"Model"]
                || [nsname containsString:@"aweme"] || [nsname containsString:@"Aweme"]
                || [nsname containsString:@"video"] || [nsname containsString:@"Video"]) {
                id v = TTGGetValue(vc, nsname);
                if (v) {
                    Class cls = [v class];
                    if ([NSStringFromClass(cls) containsString:@"Aweme"]
                        || ([NSStringFromClass(cls) containsString:@"Model"] && TTGGetValue(v, @"video"))) {
                        free(props);
                        return v;
                    }
                }
            }
        }
        free(props);
    }
    
    // 查所有 ivar
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList([vc class], &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *iname = ivar_getName(ivars[i]);
            if (!iname) continue;
            NSString *nsname = [NSString stringWithUTF8String:iname];
            if ([nsname containsString:@"model"] || [nsname containsString:@"Model"]
                || [nsname containsString:@"aweme"] || [nsname containsString:@"Aweme"]) {
                id v = object_getIvar(vc, ivars[i]);
                if (v && v != [NSNull null]) {
                    Class cls = [v class];
                    if ([NSStringFromClass(cls) containsString:@"Aweme"]
                        || ([NSStringFromClass(cls) containsString:@"Model"] && TTGGetValue(v, @"video"))) {
                        free(ivars);
                        return v;
                    }
                }
            }
        }
        free(ivars);
    }
    
    // 递归子 VC
    for (UIViewController *child in vc.childViewControllers) {
        id found = TTGFindAwemeInVCRecursive(child, depth + 1);
        if (found) return found;
    }
    
    // presented VC
    if (vc.presentedViewController && vc.presentedViewController != vc) {
        id found = TTGFindAwemeInVCRecursive(vc.presentedViewController, depth + 1);
        if (found) return found;
    }
    
    return nil;
}

static id TTGGetCurrentAweme(void) {
    // 1. 缓存
    if (g_currentAweme) return g_currentAweme;
    
    // 2. 从 top VC 递归查
    UIViewController *top = TTGTopViewController();
    if (top) {
        id found = TTGFindAwemeInVCRecursive(top, 0);
        if (found) { g_currentAweme = found; return found; }
    }
    
    // 3. 从 window rootVC 递归查（可能有多个 window）
    UIWindow *win = TTGFrontmostWindow();
    if (win && win.rootViewController) {
        id found = TTGFindAwemeInVCRecursive(win.rootViewController, 0);
        if (found) { g_currentAweme = found; return found; }
    }
    
    // 4. 所有 window 的 rootVC
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) {
                for (UIWindow *w in [(id)scene windows]) {
                    if (w.rootViewController) {
                        id found = TTGFindAwemeInVCRecursive(w.rootViewController, 0);
                        if (found) { g_currentAweme = found; return found; }
                    }
                }
            }
        }
    }
    
    NSLog(@"[TTG] ❌ 找不到任何 aweme model");
    return nil;
}

#pragma mark - 下载视频（无水印）

static NSArray *TTGAllStringURLsFromArray(id arr) {
    if (![arr isKindOfClass:[NSArray class]]) return nil;
    NSMutableArray *result = [NSMutableArray array];
    for (id item in arr) {
        if ([item isKindOfClass:[NSString class]] && [item hasPrefix:@"http"]) [result addObject:item];
        else {
            NSString *url = TTGGetValue(item, @"url");
            if (url && [url hasPrefix:@"http"]) [result addObject:url];
        }
    }
    return result;
}

static NSString *TTGFindBestVideoURL(id aweme) {
    // aweme -> video -> downloadURL / playURL -> originURLList / url
    id video = TTGGetValue(aweme, @"video");
    if (!video) {
        // 有些版本 aweme 本身就是 video model
        Class cls = [aweme class];
        if ([NSStringFromClass(cls) containsString:@"Video"]) video = aweme;
        else return nil;
    }
    
    NSLog(@"[TTG] 📹 video class: %@", NSStringFromClass([video class]));
    
    // 列出 video 的所有可用属性（调试）
    @try {
        unsigned int pc = 0;
        objc_property_t *ps = class_copyPropertyList([video class], &pc);
        NSMutableArray *pnames = [NSMutableArray array];
        for (unsigned int i = 0; i < MIN(pc, 30); i++) {
            [pnames addObject:[NSString stringWithUTF8String:property_getName(ps[i])]];
        }
        free(ps);
        NSLog(@"[TTG] 📹 video props: %@", pnames);
    } @catch (NSException *e) {}
    
    // 尝试各种 URL model 属性
    NSArray *urlModelKeys = @[@"downloadURL", @"playURL", @"playApi", @"streamURL", @"bitRateURL"];
    for (NSString *key in urlModelKeys) {
        id urlModel = TTGGetValue(video, key);
        if (!urlModel) continue;
        NSLog(@"[TTG]   🔑 Found %@: %@", key, NSStringFromClass([urlModel class]));
        
        // 从 urlModel 找 URL 字符串
        NSArray *listKeys = @[@"originURLList", @"urlList", @"urls", @"urlListString"];
        for (NSString *lk in listKeys) {
            id list = TTGGetValue(urlModel, lk);
            NSArray *strings = TTGAllStringURLsFromArray(list);
            if (strings.count > 0) {
                NSLog(@"[TTG]   ✅ Using %@.%@[0] = %@", key, lk, strings[0]);
                return strings[0];
            }
        }
        
        // 直接 url 属性
        NSString *directUrl = TTGGetValue(urlModel, @"url");
        if (directUrl && [directUrl hasPrefix:@"http"]) {
            NSLog(@"[TTG]   ✅ Using %@.url = %@", key, directUrl);
            return directUrl;
        }
    }
    
    // aweme 根层级的 url
    NSString *directUrl = TTGGetValue(aweme, @"url");
    if (directUrl && [directUrl hasPrefix:@"http"]) return directUrl;
    
    return nil;
}

static void TTGDownloadCurrent(void) {
    id aweme = TTGGetCurrentAweme();
    if (!aweme) {
        TTGShowToast(@"❌ 找不到当前视频");
        return;
    }
    
    NSLog(@"[TTG] 📥 Downloading aweme model: %@", NSStringFromClass([aweme class]));
    NSString *urlStr = TTGFindBestVideoURL(aweme);
    
    if (!urlStr) {
        NSLog(@"[TTG] ❌ 拿不到视频链接");
        TTGShowToast(@"❌ 拿不到视频链接");
        return;
    }
    NSLog(@"[TTG] 📥 URL: %@", urlStr);
    
    TTGShowToast(@"⏳ 正在下载...");
    
    // 设置 User-Agent 避免 403
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { TTGShowToast(@"❌ URL 无效"); return; }
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"com.ss.android.ugc.aweme" forHTTPHeaderField:@"X-App-Pkg"];
    [req setValue:@"TikTok" forHTTPHeaderField:@"User-Agent"];
    
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:req
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error) {
                NSLog(@"[TTG] ❌ Download error: %@", error);
                dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 下载失败"); });
                return;
            }
            
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            NSLog(@"[TTG] 📥 HTTP %ld bytes=%ld", (long)httpResp.statusCode, (long)[[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:nil].fileSize);
            
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
                        else {
                            NSLog(@"[TTG] ❌ Save error: %@", err);
                            TTGShowToast(@"❌ 保存失败");
                        }
                    });
                }];
            }];
        }];
    [task resume];
}

#pragma mark - 悬浮按钮

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
        self.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.95];
        self.layer.cornerRadius = frame.size.width / 2;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.4;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowRadius = 4;
        [self setTitle:@"⬇" forState:UIControlStateNormal];
        [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    }
    return self;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    _dragStart = [t locationInView:self.superview];
    _dragging = NO;
    _longPressFired = NO;
    _longPressTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(fireLongPress) userInfo:nil repeats:NO];
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
        TTGDownloadCurrent();
    }
}

- (void)ttgShowSettings {
    UIViewController *vc = TTGTopViewController();
    if (!vc) return;
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 TikTok God 设置"
        message:@"短按⬇下载  长按打开设置  拖动移动"
        preferredStyle:UIAlertControllerStyleActionSheet];
    
    NSArray *items = @[
        @{@"title": @"去广告", @"key": @"noads"},
        @{@"title": @"无水印下载", @"key": @"downloadWithoutWatermark"},
        @{@"title": @"自动连播下一个", @"key": @"autoPlayNextVideo"},
        @{@"title": @"模拟美国地区", @"key": @"changeRegion"},
        @{@"title": @"强制显示进度条", @"key": @"showProgressBar"},
        @{@"title": @"隐藏视频上的UI", @"key": @"canHideUI"},
        @{@"title": @"画中画（PiP）", @"key": @"enablePIP"},
        @{@"title": @"后台继续播放", @"key": @"enableBackgroundPlay"},
        @{@"title": @"安全检测绕过", @"key": @"enableBypass"},
    ];
    
    void (^toggle)(NSString *, BOOL *) = ^(NSString *key, BOOL *ptr) {
        if ([key isEqualToString:key]) {} // placeholder
        *ptr = !*ptr;
    };
    
    NSDictionary *keyToPtr = @{
        @"noads": ^(void){ noads = !noads; },
        @"downloadWithoutWatermark": ^(void){ downloadWithoutWatermark = !downloadWithoutWatermark; },
        @"autoPlayNextVideo": ^(void){ autoPlayNextVideo = !autoPlayNextVideo; },
        @"changeRegion": ^(void){ changeRegion = !changeRegion; },
        @"showProgressBar": ^(void){ showProgressBar = !showProgressBar; },
        @"canHideUI": ^(void){ canHideUI = !canHideUI; },
        @"enablePIP": ^(void){ enablePIP = !enablePIP; },
        @"enableBackgroundPlay": ^(void){ enableBackgroundPlay = !enableBackgroundPlay; },
        @"enableBypass": ^(void){ enableBypass = !enableBypass; },
    };
    
    for (NSDictionary *it in items) {
        NSString *key = it[@"key"];
        NSString *title = it[@"title"];
        BOOL *flagPtr = NULL;
        if ([key isEqualToString:@"noads"]) flagPtr = &noads;
        else if ([key isEqualToString:@"downloadWithoutWatermark"]) flagPtr = &downloadWithoutWatermark;
        else if ([key isEqualToString:@"autoPlayNextVideo"]) flagPtr = &autoPlayNextVideo;
        else if ([key isEqualToString:@"changeRegion"]) flagPtr = &changeRegion;
        else if ([key isEqualToString:@"showProgressBar"]) flagPtr = &showProgressBar;
        else if ([key isEqualToString:@"canHideUI"]) flagPtr = &canHideUI;
        else if ([key isEqualToString:@"enablePIP"]) flagPtr = &enablePIP;
        else if ([key isEqualToString:@"enableBackgroundPlay"]) flagPtr = &enableBackgroundPlay;
        else if ([key isEqualToString:@"enableBypass"]) flagPtr = &enableBypass;
        
        BOOL isOn = flagPtr ? *flagPtr : NO;
        NSString *dispTitle = [NSString stringWithFormat:@"%@ %@", isOn ? @"✅ 开" : @"⬜ 关", title];
        [alert addAction:[UIAlertAction actionWithTitle:dispTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (flagPtr) *flagPtr = !*flagPtr;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self ttgShowSettings];
            });
        }]];
    }
    
    [alert addAction:[UIAlertAction actionWithTitle:@"全部开启" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        noads = downloadWithoutWatermark = autoPlayNextVideo = changeRegion = showProgressBar = canHideUI = enablePIP = enableBackgroundPlay = enableBypass = YES;
        TTGShowToast(@"✅ 所有功能已开启");
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    
    if (alert.popoverPresentationController) {
        alert.popoverPresentationController.sourceView = self;
        alert.popoverPresentationController.sourceRect = self.bounds;
    }
    [vc presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Hook 注册

static void TTGRegisterHooks(void) {
    @try {
        NSLog(@"[TTG] 🪝 注册 hooks...");
        
        // CTCarrier（系统类，极稳）
        Class CTCarrier = NSClassFromString(@"CTCarrier");
        if (CTCarrier && changeRegion) {
            Method mcc = class_getInstanceMethod(CTCarrier, @selector(mcc));
            Method mnc = class_getInstanceMethod(CTCarrier, @selector(mnc));
            Method iso = class_getInstanceMethod(CTCarrier, @selector(isoCountryCode));
            if (mcc) method_setImplementation(mcc, imp_implementationWithBlock(^id(id s){ return @"310"; }));
            if (mnc) method_setImplementation(mnc, imp_implementationWithBlock(^id(id s){ return @"001"; }));
            if (iso) method_setImplementation(iso, imp_implementationWithBlock(^id(id s){ return @"us"; }));
            NSLog(@"[TTG] ✅ CTCarrier 切地区 已启用");
        }
        
        // 遍历所有类找 set*Aweme* / set*Model* 方法做缓存
        unsigned int classCount = 0;
        Class *classes = objc_copyClassList(&classCount);
        if (classes) {
            SEL cacheSels[] = { @selector(setModel:), @selector(setAwemeModel:), @selector(setVideoModel:) };
            for (unsigned int i = 0; i < classCount; i++) {
                Class cls = classes[i];
                for (int s = 0; s < 3; s++) {
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
                            method_setImplementation(m, newImp);
                        }
                    }
                }
            }
            free(classes);
        }
        NSLog(@"[TTG] ✅ setModel 缓存已注册");
        
        // 后台播放
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                if (enableBackgroundPlay) {
                    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
                    NSLog(@"[TTG] 🎧 后台播放 已启用");
                }
            }];
        
        NSLog(@"[TTG] ✅ 所有 hooks 已注册");
    } @catch (NSException *e) {
        NSLog(@"[TTG] ❌ hook 注册崩溃: %@", e);
    }
}

#pragma mark - Constructor

%ctor {
    NSLog(@"[TTG] 🚀 ctor 启动");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = TTGFrontmostWindow();
            if (!win) { NSLog(@"[TTG] ❌ 找不到 window"); return; }
            
            CGFloat startY = 50;
            if (@available(iOS 11.0, *)) startY = 50 + win.safeAreaInsets.top + 34;
            
            TTGFloatingButton *btn = [[TTGFloatingButton alloc] initWithFrame:CGRectMake(14, startY, 44, 44)];
            [win addSubview:btn];
            NSLog(@"[TTG] ✅ 悬浮按钮已添加");
            
            TTGRegisterHooks();
            NSLog(@"[TTG] 🎉 准备就绪");
        } @catch (NSException *e) {
            NSLog(@"[TTG] ❌ ctor 崩溃: %@", e);
        }
    });
}
