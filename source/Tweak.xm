#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/message.h>

#pragma mark - 全局开关

static BOOL noads = YES;
static BOOL downloadWithoutWatermark = YES;
static BOOL autoPlayNextVideo = YES;
static BOOL changeRegion = YES;
static BOOL showProgressBar = YES;
static BOOL canHideUI = YES;
static BOOL enablePIP = YES;
static BOOL enableBackgroundPlay = YES;
static BOOL enableBypass = YES;

#pragma mark - 工具

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

static UIViewController *TTGTopVC(void) {
    UIWindow *win = TTGFrontmostWindow();
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if ([vc isKindOfClass:[UINavigationController class]]) vc = [(UINavigationController*)vc visibleViewController];
    if ([vc isKindOfClass:[UITabBarController class]]) vc = [(UITabBarController*)vc selectedViewController];
    return vc;
}

static void TTGShowToast(NSString *msg) {
    if (!msg) return;
    UIWindow *win = TTGFrontmostWindow();
    if (!win) return;
    @try {
        UIView *toast = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 50)];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.85];
        toast.layer.cornerRadius = 25;
        toast.center = win.center;
        UILabel *label = [[UILabel alloc] initWithFrame:toast.bounds];
        label.text = msg;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [toast addSubview:label];
        toast.alpha = 0;
        [win addSubview:toast];
        [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; } completion:^(BOOL _) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.25 animations:^{ toast.alpha = 0; } completion:^(BOOL __) { [toast removeFromSuperview]; }];
            });
        }];
    } @catch (NSException *e) {
        NSLog(@"[TTG] toast err: %@", e);
    }
}

static id TTGGetValue(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}

#pragma mark - 找当前 aweme

static NSArray *TTGAllSubviewsOf(UIView *v) {
    if (!v) return nil;
    NSMutableArray *result = [NSMutableArray array];
    [result addObject:v];
    for (UIView *s in v.subviews) {
        [result addObjectsFromArray:TTGAllSubviewsOf(s)];
    }
    return result;
}

static id TTGFindAwemeFromViewHierarchy(void) {
    // 遍历所有 window 的 subview，找含 model/aweme/video 属性的 VC/View
    @try {
        NSArray *allWindows = nil;
        if (@available(iOS 13.0, *)) {
            NSMutableArray *ws = [NSMutableArray array];
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) {
                    [ws addObjectsFromArray:[(id)scene windows]];
                }
            }
            allWindows = ws;
        } else {
            allWindows = [UIApplication sharedApplication].windows;
        }

        NSMutableArray *keys = [NSMutableArray arrayWithArray:@[@"awemeModel", @"model", @"videoModel", @"aweme", @"currentAweme", @"currentModel", @"playModel", @"feedModel", @"detailModel"]];

        for (UIWindow *win in allWindows) {
            for (UIView *view in TTGAllSubviewsOf(win)) {
                // ViewController 本身
                if ([view isKindOfClass:[UIViewController class]]) {
                    UIViewController *vc = (UIViewController *)view;
                    for (NSString *k in keys) {
                        id v = TTGGetValue(vc, k);
                        if (v && TTGGetValue(v, @"video")) return v;
                        if (v && [NSStringFromClass([v class]) containsString:@"Aweme"]) return v;
                    }
                }
                // View 有自定义 ivar
                unsigned int pc = 0;
                objc_property_t *props = class_copyPropertyList([view class], &pc);
                if (props) {
                    for (unsigned int i = 0; i < pc; i++) {
                        NSString *pname = [NSString stringWithUTF8String:property_getName(props[i])];
                        if ([pname containsString:@"model"] || [pname containsString:@"Model"]
                            || [pname containsString:@"aweme"] || [pname containsString:@"Aweme"]) {
                            id v = TTGGetValue(view, pname);
                            if (v && TTGGetValue(v, @"video")) { free(props); return v; }
                            if (v && [NSStringFromClass([v class]) containsString:@"Aweme"]) { free(props); return v; }
                        }
                    }
                    free(props);
                }
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[TTG] find aweme err: %@", e);
    }
    return nil;
}

#pragma mark - 从 aweme 取视频 URL（模板）

static NSString *TTGExtractVideoURL(id aweme) {
    if (!aweme) return nil;
    @try {
        id video = TTGGetValue(aweme, @"video");
        if (!video) {
            // 有些版本 aweme 本身就是 video model
            if ([NSStringFromClass([aweme class]) containsString:@"Video"]) video = aweme;
            else return nil;
        }

        // playURL 优先（无水印版本）→ downloadURL 兜底
        for (NSString *urlKey in @[@"playURL", @"downloadURL", @"playApi", @"streamURL"]) {
            id urlModel = TTGGetValue(video, urlKey);
            if (!urlModel) continue;

            // originURLList / urlList / urls 数组
            for (NSString *listKey in @[@"originURLList", @"urlList", @"urls", @"urlListString"]) {
                id list = TTGGetValue(urlModel, listKey);
                if ([list isKindOfClass:[NSArray class]] && [list count] > 0) {
                    id first = list[0];
                    if ([first isKindOfClass:[NSString class]] && [first hasPrefix:@"http"]) return first;
                    if ([first isKindOfClass:[NSURL class]]) return ((NSURL *)first).absoluteString;
                    NSString *surl = TTGGetValue(first, @"url");
                    if (surl && [surl hasPrefix:@"http"]) return surl;
                }
            }
            // 直接 url
            NSString *direct = TTGGetValue(urlModel, @"url");
            if (direct && [direct hasPrefix:@"http"]) return direct;
        }
    } @catch (NSException *e) {
        NSLog(@"[TTG] extract url err: %@", e);
    }
    return nil;
}

#pragma mark - 下载 & 保存（零 hook 方案）

static void TTGDownloadAndSave(void) {
    @try {
        id aweme = TTGFindAwemeFromViewHierarchy();
        if (!aweme) { TTGShowToast(@"❌ 没找到当前视频"); return; }

        NSString *urlStr = TTGExtractVideoURL(aweme);
        if (!urlStr || urlStr.length < 10) { TTGShowToast(@"❌ 拿不到视频链接"); return; }

        NSLog(@"[TTG] 📥 aweme=%@  urlKey=playURL  url=%@", NSStringFromClass([aweme class]), urlStr);

        if ([urlStr containsString:@".m3u8"]) { TTGShowToast(@"❌ m3u8 暂不支持"); return; }

        TTGShowToast(@"⏳ 正在下载...");

        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) { TTGShowToast(@"❌ URL 无效"); return; }

        // AVURLAsset 会用 TikTok 进程内注册的 loader 去加载，自动处理签名
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{
            AVURLAssetPreferPreciseDurationAndTimingKey: @YES
        }];

        // 输出路径
        NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"ttg_%.0f.mp4", [[NSDate date] timeIntervalSince1970]]];
        NSURL *outURL = [NSURL fileURLWithPath:outPath];
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];

        // 后台队列做 export（避免卡主线程）
        dispatch_queue_t bgQ = dispatch_queue_create("com.ttg.export", DISPATCH_QUEUE_SERIAL);
        dispatch_async(bgQ, ^{
            for (NSString *preset in @[AVAssetExportPresetHighestQuality, AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality, AVAssetExportPresetPassthrough]) {
                @autoreleasepool {
                    @try {
                        AVAssetExportSession *exporter = [AVAssetExportSession exportSessionWithAsset:asset presetName:preset];
                        if (!exporter) continue;
                        exporter.outputURL = outURL;
                        exporter.outputFileType = AVFileTypeMPEG4;
                        exporter.shouldOptimizeForNetworkUse = NO;

                        __block BOOL done = NO;
                        __block BOOL success = NO;
                        __block NSError *lastErr = nil;

                        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                        [exporter exportAsynchronouslyWithCompletionHandler:^{
                            AVAssetExportSessionStatus s = exporter.status;
                            NSError *err = exporter.error;
                            NSLog(@"[TTG] 📦 preset=%@ status=%ld err=%@", preset, (long)s, err);
                            if (s == AVAssetExportSessionStatusCompleted) {
                                success = YES;
                                done = YES;
                            } else if (s == AVAssetExportSessionStatusFailed || s == AVAssetExportSessionStatusCancelled) {
                                lastErr = err;
                                done = YES;
                            }
                            dispatch_semaphore_signal(sem);
                        }];
                        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

                        if (success) {
                            // 校验
                            AVURLAsset *chk = [AVURLAsset URLAssetWithURL:outURL options:nil];
                            BOOL hasVideo = NO;
                            for (AVAssetTrack *t in chk.tracks) {
                                if ([t.mediaType isEqualToString:AVMediaTypeVideo]) { hasVideo = YES; break; }
                            }
                            if (!hasVideo) {
                                [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
                                dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 拿到的不是视频"); });
                                return;
                            }
                            // 保存到相册
                            [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
                                if (status != PHAuthorizationStatusAuthorized) {
                                    [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
                                    dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 没相册权限"); });
                                    return;
                                }
                                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                                    [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:outURL];
                                } completionHandler:^(BOOL ok, NSError *err) {
                                    [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
                                    dispatch_async(dispatch_get_main_queue(), ^{
                                        if (ok) TTGShowToast(@"✅ 已保存到相册");
                                        else {
                                            NSLog(@"[TTG] save err: %@", err);
                                            TTGShowToast([NSString stringWithFormat:@"❌ 保存失败:%@", err.localizedDescription]);
                                        }
                                    });
                                }];
                            }];
                            return; // 成功就返回
                        }
                    } @catch (NSException *e) {
                        NSLog(@"[TTG] export loop err: %@", e);
                    }
                }
            }
            // 全部 preset 都失败
            dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 下载失败，请稍后再试"); });
        });
    } @catch (NSException *e) {
        NSLog(@"[TTG] TTGDownloadAndSave outer err: %@", e);
        TTGShowToast(@"❌ 内部错误");
    }
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
        @try {
            self.backgroundColor = [UIColor colorWithRed:0.9 green:0.2 blue:0.2 alpha:0.95];
            self.layer.cornerRadius = frame.size.width / 2;
            self.layer.shadowColor = [UIColor blackColor].CGColor;
            self.layer.shadowOpacity = 0.4;
            self.layer.shadowOffset = CGSizeMake(0, 2);
            self.layer.shadowRadius = 4;
            [self setTitle:@"⬇" forState:UIControlStateNormal];
            [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            self.titleLabel.font = [UIFont boldSystemFontOfSize:18];
        } @catch (NSException *e) { NSLog(@"[TTG] btn init err: %@", e); }
    }
    return self;
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *t = [touches anyObject];
    _dragStart = [t locationInView:self.superview];
    _dragging = NO;
    _longPressFired = NO;
    @try {
        _longPressTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(fireLongPress) userInfo:nil repeats:NO];
    } @catch (NSException *e) {}
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
        TTGDownloadAndSave();
    }
}

- (void)ttgShowSettings {
    UIViewController *vc = TTGTopVC();
    if (!vc) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"🤖 TikTok God 设置"
        message:@"短按⬇下载  长按打开设置  拖动移动"
        preferredStyle:UIAlertControllerStyleActionSheet];

    struct { NSString *title; BOOL *ptr; } items[] = {
        { @"去广告", &noads },
        { @"无水印下载", &downloadWithoutWatermark },
        { @"自动连播下一个", &autoPlayNextVideo },
        { @"模拟美国地区", &changeRegion },
        { @"强制显示进度条", &showProgressBar },
        { @"隐藏视频上的UI", &canHideUI },
        { @"画中画（PiP）", &enablePIP },
        { @"后台继续播放", &enableBackgroundPlay },
        { @"安全检测绕过", &enableBypass },
    };
    int count = sizeof(items)/sizeof(items[0]);

    for (int i = 0; i < count; i++) {
        BOOL *flagPtr = items[i].ptr;
        BOOL isOn = flagPtr ? *flagPtr : NO;
        NSString *title = [NSString stringWithFormat:@"%@ %@", isOn ? @"✅ 开" : @"⬜ 关", items[i].title];
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if (flagPtr) *flagPtr = !*flagPtr;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
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

#pragma mark - 少量系统 hook（用 class_replaceMethod，安全）

static void TTGInstallSafeHooks(void) {
    @try {
        // 后台播放
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                if (enableBackgroundPlay) {
                    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
                }
            }];
        NSLog(@"[TTG] ✅ 后台播放 hook 已安装");

        // CTCarrier 切地区（class_replaceMethod 方式，比 method_setImplementation 安全）
        if (changeRegion) {
            Class CTCarrier = NSClassFromString(@"CTCarrier");
            if (CTCarrier) {
                class_replaceMethod(CTCarrier, @selector(mcc), imp_implementationWithBlock(^id(id s){ return @"310"; }), "@@:");
                class_replaceMethod(CTCarrier, @selector(mnc), imp_implementationWithBlock(^id(id s){ return @"001"; }), "@@:");
                class_replaceMethod(CTCarrier, @selector(isoCountryCode), imp_implementationWithBlock(^id(id s){ return @"us"; }), "@@:");
                NSLog(@"[TTG] ✅ CTCarrier hook 已安装");
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[TTG] hook install err: %@", e);
    }
}

#pragma mark - Constructor

__attribute__((constructor)) static void TTGInit(void) {
    NSLog(@"[TTG] 🚀 ctor 启动");

    // 注册所有 hook（先注册，避免漏掉启动前播放的内容）
    TTGInstallSafeHooks();

    // 悬浮按钮延迟出现（等主 window 就绪）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        @try {
            UIWindow *win = TTGFrontmostWindow();
            if (!win) { NSLog(@"[TTG] ❌ 没找到 window"); return; }

            CGFloat startY = 50;
            if (@available(iOS 11.0, *)) startY = 50 + win.safeAreaInsets.top + 34;

            TTGFloatingButton *btn = [[TTGFloatingButton alloc] initWithFrame:CGRectMake(14, startY, 44, 44)];
            [win addSubview:btn];
            NSLog(@"[TTG] ✅ 悬浮按钮已添加");
        } @catch (NSException *e) {
            NSLog(@"[TTG] ctor btn err: %@", e);
        }
    });
}
