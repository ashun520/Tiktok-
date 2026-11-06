#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - 前向声明

static void TTGDownloadAndSave(void);
static void TTGDownloadImage(void);
static void TTGDownloadMusic(void);
static void TTGDownloadLivePhoto(void);

@class TTGSettingsViewController;

// 递归禁用整个 view 树里除了保留的 window 上的手势之外的所有 UILongPressGestureRecognizer
static void TTGKillAllLongPressInViewExcept(UIView *v, UIGestureRecognizer *except) {
    for (UIGestureRecognizer *gr in v.gestureRecognizers) {
        if (gr == except) continue;
        if (![gr isKindOfClass:[UILongPressGestureRecognizer class]]) continue;
        // 如果 gr 也在 window 上（是我们双指的那个），也保留
        if (gr.view && [gr.view isKindOfClass:[UIWindow class]]) continue;
        // 双重保险：先 cancel state，再 disable
        if (gr.state != UIGestureRecognizerStateEnded &&
            gr.state != UIGestureRecognizerStateCancelled &&
            gr.state != UIGestureRecognizerStateFailed) {
            gr.state = UIGestureRecognizerStateCancelled;
        }
        gr.enabled = NO;
    }
    for (UIView *sub in v.subviews) {
        TTGKillAllLongPressInViewExcept(sub, except);
    }
}

// 纯禁用：扫所有 window，把子视图上的所有 UILongPressGestureRecognizer.enabled = NO
// 只保留 window 上的（我们自己的）
static void TTGDisableAllChildLongPresses(void) {
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
        for (UIWindow *win in allWindows) {
            for (UIView *sub in win.subviews) {
                TTGKillAllLongPressInViewExcept(sub, nil);
            }
        }
    } @catch (NSException *e) {}
}

// 全局 touch 计数器（通过 swizzle UIWindow.sendEvent 维护）
static NSInteger _ttg_global_touch_count = 0;

@interface UIWindow (TTGSendEventSwizzle)
@end

@implementation UIWindow (TTGSendEventSwizzle)
+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class cls = [UIWindow class];
        SEL originalSel = @selector(sendEvent:);
        SEL swizzledSel = @selector(ttg_sendEvent:);
        Method original = class_getInstanceMethod(cls, originalSel);
        Method swizzled = class_getInstanceMethod(cls, swizzledSel);
        method_exchangeImplementations(original, swizzled);
    });
}
- (void)ttg_sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypeTouches) {
        NSSet *allTouches = [event valueForKey:@"allTouches"];
        UITouch *anyTouch = allTouches.anyObject;
        if (anyTouch.phase == UITouchPhaseBegan) {
            // 新增：allTouches 数量就是新 down 的 touch 数
            // 但 allTouches 也可能包含没移动的旧 touch，所以用 global + 1/-1 增量
            if (_ttg_global_touch_count < (NSInteger)allTouches.count) {
                _ttg_global_touch_count = allTouches.count;
            }
        } else if (anyTouch.phase == UITouchPhaseEnded || anyTouch.phase == UITouchPhaseCancelled) {
            // 结束：allTouches 里不包含结束的 touch，所以直接 allTouches.count 就是剩余数
            _ttg_global_touch_count = allTouches.count;
        } else {
            // Moved/Stationary → 全局 count 就是 allTouches.count
            _ttg_global_touch_count = allTouches.count;
        }
        NSLog(@"[TTG] 🌐 sendEvent phase=%ld → total_touches=%ld", (long)anyTouch.phase, (long)_ttg_global_touch_count);
    }
    [self ttg_sendEvent:event];
}
@end

// 单指长按：完全自研 + 零 super + swizzle 全局 touch 计数检测多指
@interface TTGSinglePressRecognizer : UILongPressGestureRecognizer {
    dispatch_block_t _ttg_timer_block;
    CGPoint _ttg_startPoint;
    BOOL _ttg_fired;
}
@end

@implementation TTGSinglePressRecognizer

#define TTG_SINGLE_DELAY      0.40
#define TTG_SINGLE_MOVE_LIMIT 25.0

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (touches.count != 1) {
        NSLog(@"[TTG] 👆 touchesBegan(count=%lu≠1) → Fail", (unsigned long)touches.count);
        self.state = UIGestureRecognizerStateFailed;
        return;
    }
    
    UITouch *touch = touches.anyObject;
    _ttg_startPoint = [touch locationInView:self.view];
    _ttg_fired = NO;
    
    NSLog(@"[TTG] 👆 touchesBegan(1指) → timer %.2fs", TTG_SINGLE_DELAY);
    TTGDisableAllChildLongPresses();
    
    __weak typeof(self) weakSelf = self;
    _ttg_timer_block = dispatch_block_create((dispatch_block_flags_t)0, ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || self->_ttg_fired) return;
        if (self.state != UIGestureRecognizerStatePossible) return;
        // 最终保险：全局 touch 数必须还是 1
        if (_ttg_global_touch_count != 1) {
            NSLog(@"[TTG] 👆 timer 到点但全局 touches=%ld≠1 → Fail", (long)_ttg_global_touch_count);
            self.state = UIGestureRecognizerStateFailed;
            return;
        }
        self->_ttg_fired = YES;
        NSLog(@"[TTG] ✅ 👆 timer 到点 → Began");
        self.state = UIGestureRecognizerStateBegan;
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(TTG_SINGLE_DELAY * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), _ttg_timer_block);
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_ttg_fired) return;
    UITouch *touch = touches.anyObject;
    CGPoint p = [touch locationInView:self.view];
    CGFloat dx = p.x - _ttg_startPoint.x;
    CGFloat dy = p.y - _ttg_startPoint.y;
    CGFloat maxD = TTG_SINGLE_MOVE_LIMIT + 2;
    if ((dx*dx + dy*dy) > maxD*maxD) {
        [self _ttg_cancelTimer];
        NSLog(@"[TTG] 👆 touchesMoved 超范围 → Fail");
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSLog(@"[TTG] 👆 touchesEnded → fired=%d", _ttg_fired);
    [self _ttg_cancelTimer];
    if (_ttg_fired) self.state = UIGestureRecognizerStateEnded;
    else self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSLog(@"[TTG] 👆 touchesCancelled");
    [self _ttg_cancelTimer];
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
    NSLog(@"[TTG] 👆 reset");
    [self _ttg_cancelTimer];
    _ttg_fired = NO;
    [super reset];
}

- (void)_ttg_cancelTimer {
    if (_ttg_timer_block) {
        dispatch_block_cancel(_ttg_timer_block);
        _ttg_timer_block = nil;
    }
}

@end

// TTGLongPressHandler 在文件后面有完整 @interface + @implementation
@interface TTGLongPressHandler : NSObject
+ (instancetype)shared;
- (void)handleSingleLongPress:(UILongPressGestureRecognizer *)gr;
- (void)handleDoubleLongPress:(UILongPressGestureRecognizer *)gr;
@end

@interface UIButton (TTGBlock)
- (void)addActionForBlock:(void(^)(void))block;
@end

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

static CGFloat TTGStatusBarHeight(void) {
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:NSClassFromString(@"UIWindowScene")]) {
                UIWindowScene *ws = (UIWindowScene *)s;
                return ws.statusBarManager.statusBarFrame.size.height;
            }
        }
    }
    return [UIApplication sharedApplication].statusBarFrame.size.height;
}

static void TTGShowToast(NSString *msg) {
    if (!msg) return;
    UIWindow *win = TTGFrontmostWindow();
    if (!win) return;
    @try {
        CGSize sz = [msg sizeWithAttributes:@{NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold]}];
        CGFloat w = MIN(MAX(sz.width + 44, 110), 260);
        CGFloat h = 40;
        CGFloat statusBar = TTGStatusBarHeight();
        CGFloat y = statusBar + 68;

        UIView *toast = [[UIView alloc] initWithFrame:CGRectMake((win.bounds.size.width - w)/2, y, w, h)];
        toast.layer.cornerRadius = 20;
        toast.layer.shadowColor = [UIColor blackColor].CGColor;
        toast.layer.shadowOpacity = 0.18;
        toast.layer.shadowOffset = CGSizeMake(0, 4);
        toast.layer.shadowRadius = 10;
        toast.clipsToBounds = NO;

        // 磨砂背景（跟悬浮按钮/设置面板统一用 Light 磨砂玻璃）
        UIBlurEffectStyle bs = UIBlurEffectStyleLight;
        UIBlurEffect *blur = [UIBlurEffect effectWithStyle:bs];
        UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
        blurView.frame = CGRectMake(0, 0, w, h);
        blurView.layer.cornerRadius = 20;
        blurView.clipsToBounds = YES;
        // 加一层淡色让字更清晰
        UIView *tint = [[UIView alloc] initWithFrame:blurView.bounds];
        tint.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
        tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [blurView.contentView addSubview:tint];
        [toast addSubview:blurView];

        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(10, 0, w - 20, h)];
        label.text = msg;
        label.textColor = [UIColor colorWithWhite:0 alpha:0.85];
        label.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        label.textAlignment = NSTextAlignmentCenter;
        [toast addSubview:label];

        toast.alpha = 0;
        toast.transform = CGAffineTransformMakeTranslation(0, -14);
        [win addSubview:toast];
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5 options:UIViewAnimationOptionCurveEaseOut animations:^{
            toast.alpha = 1;
            toast.transform = CGAffineTransformIdentity;
        } completion:^(BOOL _) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.2 animations:^{
                    toast.alpha = 0;
                    toast.transform = CGAffineTransformMakeTranslation(0, -10);
                } completion:^(BOOL __) { [toast removeFromSuperview]; }];
            });
        }];
    } @catch (NSException *e) {}
}

static id TTGGetValue(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *e) { return nil; }
}

static NSArray *TTGPropertyListForClass(Class cls) {
    NSMutableArray *result = [NSMutableArray array];
    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList(cls, &pc);
    if (props) {
        for (unsigned int i = 0; i < pc; i++) {
            [result addObject:[NSString stringWithUTF8String:property_getName(props[i])]];
        }
        free(props);
    }
    return result;
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
                if ([view isKindOfClass:[UIViewController class]]) {
                    UIViewController *vc = (UIViewController *)view;
                    for (NSString *k in keys) {
                        id v = TTGGetValue(vc, k);
                        if (v && TTGGetValue(v, @"video")) return v;
                        if (v && [NSStringFromClass([v class]) containsString:@"Aweme"]) return v;
                    }
                }
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

#pragma mark - 从 aweme 取视频 URL（极致详细日志版）

static NSString *TTGExtractVideoURL(id aweme) {
    if (!aweme) return nil;
    @try {
        Class awemeClass = [aweme class];
        NSLog(@"[TTG] 🔍 aweme class=%@ props=%@", NSStringFromClass(awemeClass), [TTGPropertyListForClass(awemeClass) componentsJoinedByString:@","]);

        id video = TTGGetValue(aweme, @"video");
        if (!video) {
            if ([NSStringFromClass([aweme class]) containsString:@"Video"]) video = aweme;
            else {
                NSLog(@"[TTG] ❌ aweme 里没有 video 属性");
                return nil;
            }
        }
        NSLog(@"[TTG] 🔍 video class=%@ props=%@", NSStringFromClass([video class]), [TTGPropertyListForClass([video class]) componentsJoinedByString:@","]);

        for (NSString *urlKey in @[@"playURL", @"downloadURL", @"playApi", @"streamURL", @"bitRateURL"]) {
            id urlModel = TTGGetValue(video, urlKey);
            if (!urlModel) continue;
            NSLog(@"[TTG] 🔑 video.%@ class=%@", urlKey, NSStringFromClass([urlModel class]));

            NSArray *urlProps = TTGPropertyListForClass([urlModel class]);
            NSLog(@"[TTG]     urlModel props: %@", [urlProps componentsJoinedByString:@","]);

            for (NSString *listKey in @[@"originURLList", @"urlList", @"urls", @"urlListString"]) {
                id list = TTGGetValue(urlModel, listKey);
                if ([list isKindOfClass:[NSArray class]] && [list count] > 0) {
                    NSLog(@"[TTG]     %@[%lu] = %@", listKey, (unsigned long)[list count], list[0]);
                    id first = list[0];
                    if ([first isKindOfClass:[NSString class]] && [first hasPrefix:@"http"]) return first;
                    if ([first isKindOfClass:[NSURL class]]) return ((NSURL *)first).absoluteString;
                    NSString *surl = TTGGetValue(first, @"url");
                    if (surl && [surl hasPrefix:@"http"]) return surl;
                }
            }
            NSString *direct = TTGGetValue(urlModel, @"url");
            if (direct && [direct hasPrefix:@"http"]) { NSLog(@"[TTG]     urlModel.url = %@", direct); return direct; }
        }
    } @catch (NSException *e) {
        NSLog(@"[TTG] extract url err: %@", e);
    }
    return nil;
}

#pragma mark - 裸下载（真实浏览器 UA，带完整 TikTok 请求头）

static void TTGBareDownload(NSString *urlStr, NSURL *outURL, void (^done)(BOOL ok, NSError *err)) {
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { done(NO, [NSError errorWithDomain:@"TTG" code:-1 userInfo:@{NSLocalizedDescriptionKey:@"URL invalid"}]); return; }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"com.ss.android.ugc.aweme" forHTTPHeaderField:@"X-App-Pkg"];
    [req setValue:@"16.5.0" forHTTPHeaderField:@"X-Version"];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 com.ss.android.ugc.aweme/47.6.0" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://www.tiktok.com/" forHTTPHeaderField:@"Referer"];
    [req setValue:@"*/*" forHTTPHeaderField:@"Accept"];
    [req setTimeoutInterval:60];

    NSLog(@"[TTG] 📥 bare GET %@", urlStr);

    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:req
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error || !location) { done(NO, error); return; }
            NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
            NSLog(@"[TTG] 📥 bare HTTP %ld MIME=%@", (long)http.statusCode, http.MIMEType);
            if (http.statusCode >= 400) {
                done(NO, [NSError errorWithDomain:@"TTG" code:http.statusCode userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"HTTP %ld", (long)http.statusCode]}]);
                return;
            }
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:nil];
            long long sz = [attrs[NSFileSize] longLongValue];
            NSLog(@"[TTG] 📥 bare size=%lld", sz);
            if (sz < 10 * 1024) { done(NO, [NSError errorWithDomain:@"TTG" code:-2 userInfo:@{NSLocalizedDescriptionKey:@"File too small"}]); return; }
            [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
            NSError *copyErr = nil;
            if (![[NSFileManager defaultManager] copyItemAtURL:location toURL:outURL error:&copyErr]) {
                done(NO, copyErr); return;
            }
            done(YES, nil);
        }];
    [task resume];
}

#pragma mark - 下载 & 保存主流程

static void TTGFinishSave(NSURL *outURL);
static void TTGDownloadBareAndSave(NSString *urlStr, NSURL *outURL, dispatch_queue_t bgQ);

static void TTGDownloadAndSave(void) {
    @try {
        id aweme = TTGFindAwemeFromViewHierarchy();
        if (!aweme) { TTGShowToast(@"❌ 没找到当前视频"); return; }
        NSLog(@"[TTG] ✅ 找到 aweme: %@", NSStringFromClass([aweme class]));

        NSString *urlStr = TTGExtractVideoURL(aweme);
        if (!urlStr || urlStr.length < 10) { TTGShowToast(@"❌ 拿不到视频链接"); return; }
        NSLog(@"[TTG] ✅ 原始 URL: %@", urlStr);

        if ([urlStr containsString:@".m3u8"]) { TTGShowToast(@"❌ m3u8 暂不支持"); return; }

        TTGShowToast(@"⏳ 正在下载...");

        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) { TTGShowToast(@"❌ URL 无效"); return; }

        NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"ttg_%.0f.mp4", [[NSDate date] timeIntervalSince1970]]];
        NSURL *outURL = [NSURL fileURLWithPath:outPath];
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];

        dispatch_queue_t bgQ = dispatch_queue_create("com.ttg.export", DISPATCH_QUEUE_SERIAL);
        dispatch_async(bgQ, ^{
            // ============================================
            // 第一步：AVURLAsset 预加载 duration + tracks
            // ============================================
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{
                AVURLAssetPreferPreciseDurationAndTimingKey: @YES
            }];
            NSLog(@"[TTG] 🎞️ AVURLAsset created: %@", asset.URL.absoluteString);

            dispatch_semaphore_t preloadSem = dispatch_semaphore_create(0);
            __block NSError *loadErr = nil;
            __block BOOL hasVideoTrack = NO;
            [asset loadValuesAsynchronouslyForKeys:@[@"duration", @"tracks"] completionHandler:^{
                NSError *durationErr = nil;
                AVKeyValueStatus durStatus = [asset statusOfValueForKey:@"duration" error:&durationErr];
                NSError *tracksErr = nil;
                AVKeyValueStatus tracksStatus = [asset statusOfValueForKey:@"tracks" error:&tracksErr];
                NSLog(@"[TTG] 🎞️ duration status=%ld err=%@", (long)durStatus, durationErr);
                NSLog(@"[TTG] 🎞️ tracks status=%ld err=%@ count=%lu", (long)tracksStatus, tracksErr, (unsigned long)asset.tracks.count);
                if (durStatus != AVKeyValueStatusLoaded) loadErr = durationErr ?: tracksErr;
                for (AVAssetTrack *t in asset.tracks) {
                    if ([t.mediaType isEqualToString:AVMediaTypeVideo]) { hasVideoTrack = YES; break; }
                }
                dispatch_semaphore_signal(preloadSem);
            }];
            dispatch_semaphore_wait(preloadSem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));

            if (!hasVideoTrack || loadErr) {
                NSLog(@"[TTG] ❌ AVURLAsset 加载失败: hasVideo=%d err=%@ — 跳过 export", hasVideoTrack, loadErr);
                // 直接走裸下载
                TTGDownloadBareAndSave(urlStr, outURL, bgQ);
                return;
            }

            // ============================================
            // 第二步：AVAssetExportSession 四档预设
            // ============================================
            for (NSString *preset in @[AVAssetExportPresetHighestQuality, AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality, AVAssetExportPresetPassthrough]) {
                @autoreleasepool {
                    @try {
                        AVAssetExportSession *exporter = [AVAssetExportSession exportSessionWithAsset:asset presetName:preset];
                        if (!exporter) { NSLog(@"[TTG]   ⚠️ preset=%@ 返回 nil", preset); continue; }
                        exporter.outputURL = outURL;
                        exporter.outputFileType = AVFileTypeMPEG4;
                        exporter.shouldOptimizeForNetworkUse = NO;

                        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
                        [exporter exportAsynchronouslyWithCompletionHandler:^{
                            NSLog(@"[TTG]   📦 preset=%@ status=%ld err=%@", preset, (long)exporter.status, exporter.error);
                            dispatch_semaphore_signal(sem);
                        }];
                        dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC));

                        if (exporter.status == AVAssetExportSessionStatusCompleted) {
                            goto SAVE_TO_PHOTOS;
                        }
                    } @catch (NSException *e) {
                        NSLog(@"[TTG]   ❌ preset=%@ exception: %@", preset, e);
                    }
                }
            }

            // ============================================
            // 第三步：所有 export 失败 → 裸下载兜底
            // ============================================
            NSLog(@"[TTG] ⚠️ 所有 AVAssetExportSession preset 都失败，降级裸下载");
            TTGDownloadBareAndSave(urlStr, outURL, bgQ);
            return;

            SAVE_TO_PHOTOS: {
                NSLog(@"[TTG] ✅ AVAssetExportSession 导出成功");
                AVURLAsset *chk = [AVURLAsset URLAssetWithURL:outURL options:nil];
                BOOL hasV = NO;
                for (AVAssetTrack *t in chk.tracks) {
                    if ([t.mediaType isEqualToString:AVMediaTypeVideo]) { hasV = YES; break; }
                }
                if (!hasV) {
                    NSLog(@"[TTG] ❌ 导出文件无视频轨道");
                    [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
                    dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 拿到的不是视频"); });
                    return;
                }
                TTGFinishSave(outURL);
            }
        });
    } @catch (NSException *e) {
        NSLog(@"[TTG] outer err: %@", e);
        TTGShowToast(@"❌ 内部错误");
    }
}

// 裸下载（类方法占位，实际用 dispatch_queue 串行）
static void TTGFinishSave(NSURL *outURL) {
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
                    TTGShowToast([NSString stringWithFormat:@"❌ 保存失败:%@", err.localizedDescription ?: @"unknown"]);
                }
            });
        }];
    }];
}

static void TTGDownloadBareAndSave(NSString *urlStr, NSURL *outURL, dispatch_queue_t bgQ) {
    TTGBareDownload(urlStr, outURL, ^(BOOL ok, NSError *err) {
        if (ok) {
            AVURLAsset *chk = [AVURLAsset URLAssetWithURL:outURL options:nil];
            BOOL hasV = NO;
            for (AVAssetTrack *t in chk.tracks) {
                if ([t.mediaType isEqualToString:AVMediaTypeVideo]) { hasV = YES; break; }
            }
            if (!hasV) {
                [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 裸下载不是视频（可能被 CDN 拒签）"); });
                return;
            }
            TTGFinishSave(outURL);
        } else {
            NSLog(@"[TTG] ❌ 裸下载失败: %@", err);
            dispatch_async(dispatch_get_main_queue(), ^{
                TTGShowToast([NSString stringWithFormat:@"❌ 下载失败:%@", err.localizedDescription ?: @"稍后再试"]);
            });
        }
    });
}

#pragma mark - 长按手势 + 底部磨砂面板

// 长按手势处理：在 TikTok feed 上添加，触发 TTGActionPanelView
@interface TTGActionPanelView : UIView
@end

@implementation TTGActionPanelView {
    UIView *_dimmingView;
    UIView *_sheet;
    CGFloat _sheetH;
}

- (instancetype)init {
    self = [super initWithFrame:[UIScreen mainScreen].bounds];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        [self setup];
    }
    return self;
}

// 全局数组存开关 BOOL* 指针（tag 作为索引）
static NSMutableArray *_ttg_switch_ptrs = nil;

- (void)setup {
    // 初始化指针数组
    if (!_ttg_switch_ptrs) _ttg_switch_ptrs = [NSMutableArray array];

    CGRect b = self.bounds;

    // 暗色遮罩
    _dimmingView = [[UIView alloc] initWithFrame:b];
    _dimmingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dimmingView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
    [self addSubview:_dimmingView];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismiss)];
    [_dimmingView addGestureRecognizer:tap];

    // 底部 sheet（磨砂玻璃）
    _sheetH = 340;   // 加大（3 行按钮）
    CGFloat bottomPad = 0;
    if (@available(iOS 11.0, *)) {
        UIWindow *w = TTGFrontmostWindow();
        if (w) bottomPad = w.safeAreaInsets.bottom;
    }
    _sheetH += bottomPad;

    _sheet = [[UIView alloc] init];
    _sheet.frame = CGRectMake(0, b.size.height, b.size.width, _sheetH);
    _sheet.backgroundColor = [UIColor clearColor];
    _sheet.layer.cornerRadius = 22;
    _sheet.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    _sheet.layer.shadowColor = [UIColor blackColor].CGColor;
    _sheet.layer.shadowOpacity = 0.3;
    _sheet.layer.shadowOffset = CGSizeMake(0, -6);
    _sheet.layer.shadowRadius = 24;
    _sheet.clipsToBounds = NO;
    [self addSubview:_sheet];

    // 磨砂背景（Light 风格，跟之前统一）
    UIBlurEffect *be = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
    UIVisualEffectView *bvg = [[UIVisualEffectView alloc] initWithEffect:be];
    bvg.frame = _sheet.bounds;
    bvg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    bvg.layer.cornerRadius = 22;
    bvg.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    bvg.clipsToBounds = YES;
    [_sheet addSubview:bvg];
    UIView *tint = [[UIView alloc] initWithFrame:_sheet.bounds];
    tint.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    tint.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    [bvg.contentView addSubview:tint];

    // 顶部标题
    UILabel *title = [[UILabel alloc] init];
    title.text = @"🎬 Tiktok God";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor colorWithWhite:0 alpha:0.9];
    [_sheet addSubview:title];

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"长按视频界面唤起 · ashun520";
    sub.font = [UIFont systemFontOfSize:11];
    sub.textColor = [UIColor colorWithWhite:0 alpha:0.45];
    [_sheet addSubview:sub];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.6] forState:UIControlStateNormal];
    closeBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.08];
    closeBtn.layer.cornerRadius = 14;
    [closeBtn addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [_sheet addSubview:closeBtn];

    // 按钮容器（grid）
    UIView *btnContainer = [[UIView alloc] init];
    btnContainer.tag = 9001;
    [_sheet addSubview:btnContainer];

    // 构建按钮
    // 3 行 × 2 列：保存视频、保存图片、保存音乐、保存实况、设置面板、（空位）
    NSArray *actionBtns = @[
        @{@"icon": @"arrow.down.circle.fill", @"title": @"保存视频", @"action": ^{ TTGDownloadAndSave(); }},
        @{@"icon": @"photo.on.rectangle", @"title": @"保存图片", @"action": ^{ TTGDownloadImage(); }},
        @{@"icon": @"music.note", @"title": @"保存音乐", @"action": ^{ TTGDownloadMusic(); }},
        @{@"icon": @"livephoto", @"title": @"保存实况", @"action": ^{ TTGDownloadLivePhoto(); }},
        @{@"icon": @"gearshape.fill", @"title": @"设置面板", @"action": ^{ [self openSettings]; }},
    ];

    for (int i = 0; i < (int)actionBtns.count; i++) {
        NSDictionary *item = actionBtns[i];
        UIButton *btn = [self makeActionButtonWithIcon:item[@"icon"] title:item[@"title"]];
        int row = i / 2;
        int col = i % 2;
        CGFloat containerW = [UIScreen mainScreen].bounds.size.width - 40;
        CGFloat btnW = (containerW - 16) / 2;
        CGFloat btnH = 48;
        btn.frame = CGRectMake(col * (btnW + 16), row * (btnH + 10), btnW, btnH);
        void (^blk)(void) = item[@"action"];
        [btn addActionForBlock:blk];
        [btnContainer addSubview:btn];
    }

    // 开关已移到双指长按的设置面板，这里只留主动作按钮
    // （底部"关闭"按钮已移除，点遮罩/右上角✕即可关闭）

    // 底部署名
    UILabel *footer = [[UILabel alloc] init];
    footer.text = @"by ashun520 · LCSign 注入版 · 长按视频唤起";
    footer.font = [UIFont systemFontOfSize:10.5];
    footer.textColor = [UIColor colorWithWhite:0 alpha:0.3];
    footer.textAlignment = NSTextAlignmentCenter;
    footer.tag = 9004;
    [_sheet addSubview:footer];
}

- (UIButton *)makeActionButtonWithIcon:(NSString *)iconName title:(NSString *)title {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
    btn.layer.cornerRadius = 14;
    btn.layer.borderColor = [UIColor colorWithWhite:0 alpha:0.08].CGColor;
    btn.layer.borderWidth = 1.0;

    UIImage *img = [UIImage systemImageNamed:iconName];
    if (img) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightSemibold];
        [btn setImage:[img imageWithConfiguration:cfg] forState:UIControlStateNormal];
        [btn setTintColor:[UIColor colorWithWhite:0 alpha:0.8]];
    }
    [btn setTitle:title forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithWhite:0 alpha:0.85] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
    // 手动 layout：避免 UIButton 内部 edgeInsets 在不同 iOS 版本行为不一致
    btn.imageEdgeInsets = UIEdgeInsetsZero;
    btn.titleEdgeInsets = UIEdgeInsetsZero;
    btn.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    return btn;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // 让 icon 和 label 在按钮内居中排列：icon 左，label 右，间距 8
    for (UIView *v in self.subviews) {
        if ([v isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)v;
            if (b.imageView && b.titleLabel) {
                CGFloat W = b.bounds.size.width;
                CGFloat H = b.bounds.size.height;
                CGFloat iconW = b.imageView.intrinsicContentSize.width;
                CGFloat iconH = b.imageView.intrinsicContentSize.height;
                CGSize titleSz = [b.titleLabel sizeThatFits:CGSizeMake(W - iconW - 20, 24)];
                CGFloat gap = 6;
                CGFloat totalW = iconW + gap + titleSz.width;
                CGFloat startX = (W - totalW) / 2;
                CGFloat iconY = (H - iconH) / 2;
                CGFloat titleY = (H - titleSz.height) / 2 - 2;
                b.imageView.frame = CGRectMake(startX, iconY, iconW, iconH);
                b.titleLabel.frame = CGRectMake(startX + iconW + gap, titleY, titleSz.width, titleSz.height);
            }
        }
    }
}

- (void)show {
    UIWindow *win = TTGFrontmostWindow();
    if (!win) return;
    self.frame = win.bounds;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:self];

    CGRect b = self.bounds;
    _dimmingView.alpha = 0;
    _sheet.frame = CGRectMake(0, b.size.height, b.size.width, _sheetH);
    [self layoutSheetContents];

    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.3 options:0 animations:^{
        self->_dimmingView.alpha = 1;
        CGRect f = self->_sheet.frame;
        f.origin.y = b.size.height - self->_sheetH;
        self->_sheet.frame = f;
    } completion:nil];
}

- (void)dismiss {
    CGRect b = self.bounds;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        self->_dimmingView.alpha = 0;
        CGRect f = self->_sheet.frame;
        f.origin.y = b.size.height;
        self->_sheet.frame = f;
    } completion:^(BOOL done) {
        [self removeFromSuperview];
    }];
}

- (void)layoutSheetContents {
    CGFloat W = _sheet.bounds.size.width;
    CGFloat pad = 20;

    UILabel *title = (UILabel *)[_sheet viewWithTag:90000];
    if (!title) { title = (UILabel *)[self findViewIn:_sheet type:@"UILabel" idx:0]; title.tag = 90000; }
    UILabel *sub = (UILabel *)[self findViewIn:_sheet type:@"UILabel" idx:1];
    UIButton *closeBtn = (UIButton *)[self findViewIn:_sheet type:@"UIButton" idx:0];

    title.frame = CGRectMake(pad, 16, 180, 24);
    sub.frame = CGRectMake(pad, 38, 200, 14);
    closeBtn.frame = CGRectMake(W - 46, 12, 28, 28);

    // 按钮容器：y = 68, 3行 x 2列（5 个按钮 + 1 空位）
    UIView *btnContainer = (UIView *)[_sheet viewWithTag:9001];
    btnContainer.frame = CGRectMake(pad, 68, W - pad * 2, 164);  // 3 行 × 48px + 2 × 10px gap

    // 底部署名
    UILabel *footer = (UILabel *)[_sheet viewWithTag:9004];
    footer.frame = CGRectMake(pad, _sheetH - 20, W - pad * 2, 14);
}

- (UIView *)findViewIn:(UIView *)root type:(NSString *)clsName idx:(int)idx {
    __block int found = 0;
    __block UIView *result = nil;
    [self traverse:root block:^(UIView *v, BOOL *stop) {
        if ([NSStringFromClass([v class]) isEqualToString:clsName]) {
            if (found == idx) { result = v; *stop = YES; }
            found++;
        }
    }];
    return result;
}

- (void)traverse:(UIView *)v block:(void(^)(UIView *, BOOL *))block {
    BOOL stop = NO;
    block(v, &stop);
    if (stop) return;
    for (UIView *sub in v.subviews) [self traverse:sub block:block];
}

- (void)switchToggled:(UISwitch *)sw {
    if (sw.tag < 0 || sw.tag >= (int)_ttg_switch_ptrs.count) return;
    id v = _ttg_switch_ptrs[sw.tag];
    if ([v isKindOfClass:[NSValue class]]) {
        BOOL *ptr = (BOOL *)[(NSValue *)v pointerValue];
        if (ptr) *ptr = sw.isOn;
    }
}

- (void)openSettings {
    UIViewController *top = TTGTopVC();
    if (!top) { [self dismiss]; return; }
    UIViewController *vc = [[NSClassFromString(@"TTGSettingsViewController") alloc] init];
    if (!vc) return;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    [self dismiss];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [top presentViewController:vc animated:YES completion:nil];
    });
}

@end

// UIButton block action 扩展
@implementation UIButton (TTGBlock)
- (void)addActionForBlock:(void(^)(void))block {
    objc_setAssociatedObject(self, "ttg_action_block", block, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [self addTarget:self action:@selector(ttg_fireBlock) forControlEvents:UIControlEventTouchUpInside];
}
- (void)ttg_fireBlock {
    void(^blk)(void) = objc_getAssociatedObject(self, "ttg_action_block");
    if (blk) blk();
}
@end

@implementation TTGLongPressHandler {
    BOOL _panelShowing;
}
+ (instancetype)shared {
    static TTGLongPressHandler *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[TTGLongPressHandler alloc] init]; });
    return inst;
}

// 单指长按 → 动作面板
- (void)handleSingleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        if (_panelShowing) { NSLog(@"[TTG] 🔒 面板已在显示 → 忽略单指"); return; }
        _panelShowing = YES;
        NSLog(@"[TTG] ✅ 👆 单指长按 BEGAN → 弹动作面板");
        TTGActionPanelView *panel = [[TTGActionPanelView alloc] init];
        [panel show];
    }
    if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled || gr.state == UIGestureRecognizerStateFailed) {
        // 等手势结束时解锁（最保守安全）
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_panelShowing = NO;
        });
    }
}

// 双指长按 → 设置面板
- (void)handleDoubleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        if (_panelShowing) { NSLog(@"[TTG] 🔒 面板已在显示 → 忽略双指"); return; }
        _panelShowing = YES;
        NSLog(@"[TTG] ✅ ✌️ 双指长按 BEGAN → 弹设置面板");
        UIViewController *topVC = TTGTopVC();
        if (!topVC) { _panelShowing = NO; return; }
        Class cls = NSClassFromString(@"TTGSettingsViewController");
        if (!cls) { _panelShowing = NO; NSLog(@"[TTG] ❌ TTGSettingsViewController 未找到"); return; }
        UIViewController *vc = [[cls alloc] init];
        if (!vc) { _panelShowing = NO; return; }
        vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
        vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
        vc.view.alpha = 0;
        [topVC presentViewController:vc animated:NO completion:^{
            [UIView animateWithDuration:0.2 animations:^{
                vc.view.alpha = 1;
            }];
        }];
    }
    if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled || gr.state == UIGestureRecognizerStateFailed) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_panelShowing = NO;
        });
    }
}

@end

static void TTGInstallGesturesOnWindow(UIWindow *win) {
    if (!win) return;

    // 先检查：我们的单指/双指手势是否已经真的在 window 上
    BOOL hasSingle = NO, hasDouble = NO;
    for (UIGestureRecognizer *gr in win.gestureRecognizers) {
        if ([gr isKindOfClass:[TTGSinglePressRecognizer class]]) hasSingle = YES;
        if ([gr isKindOfClass:[UILongPressGestureRecognizer class]] &&
            ![gr isKindOfClass:[TTGSinglePressRecognizer class]] &&
            ((UILongPressGestureRecognizer *)gr).numberOfTouchesRequired == 2) hasDouble = YES;
    }

    if (hasSingle && hasDouble) {
        // 两个都在 → 确保没被 disable，然后跳过
        for (UIGestureRecognizer *gr in win.gestureRecognizers) {
            if ([gr isKindOfClass:[TTGSinglePressRecognizer class]]) gr.enabled = YES;
            if ([gr isKindOfClass:[UILongPressGestureRecognizer class]] &&
                ![gr isKindOfClass:[TTGSinglePressRecognizer class]] &&
                ((UILongPressGestureRecognizer *)gr).numberOfTouchesRequired == 2) gr.enabled = YES;
        }
        return;
    }

    // 缺哪个装哪个（不要重复装）
    if (!hasSingle) {
        TTGSinglePressRecognizer *single = [[TTGSinglePressRecognizer alloc]
            initWithTarget:[TTGLongPressHandler shared] action:@selector(handleSingleLongPress:)];
        single.minimumPressDuration = 999.0;  // 让 super 的 timer 永不触发，我们有自研的
        single.numberOfTouchesRequired = 1;
        single.allowableMovement = 25;
        single.cancelsTouchesInView = YES;
        single.delaysTouchesBegan = NO;
        single.delaysTouchesEnded = NO;
        [win addGestureRecognizer:single];
        NSLog(@"[TTG] ✋ 单指长按手势已装到 window");
    }

    if (!hasDouble) {
        UILongPressGestureRecognizer *dbl = [[UILongPressGestureRecognizer alloc]
            initWithTarget:[TTGLongPressHandler shared] action:@selector(handleDoubleLongPress:)];
        dbl.minimumPressDuration = 0.5;
        dbl.numberOfTouchesRequired = 2;
        dbl.allowableMovement = 30;
        dbl.cancelsTouchesInView = YES;
        dbl.delaysTouchesBegan = NO;
        dbl.delaysTouchesEnded = NO;
        [win addGestureRecognizer:dbl];
        NSLog(@"[TTG] ✋ 双指长按手势已装到 window");
    }

    // 装完立即 disable 所有子视图长按
    TTGDisableAllChildLongPresses();
    NSLog(@"[TTG] ✋ window 手势就绪 → 已 disable 子视图长按");
}

#pragma mark - 设置页（液态玻璃）

@interface TTGSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation TTGSettingsViewController {
    NSArray *_rows;
    UITableView *_tableView;
    UIView *_dimmingView;
    UIView *_card;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];
    self.view.opaque = NO;

    // 暗色遮罩（不磨砂了，用户说太磨砂看不见字）
    _dimmingView = [[UIView alloc] initWithFrame:self.view.bounds];
    _dimmingView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _dimmingView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
    [self.view addSubview:_dimmingView];

    // 悬浮卡片（居中，不是全屏）
    _card = [[UIView alloc] init];
    _card.backgroundColor = [UIColor clearColor];
    _card.layer.cornerRadius = 22;
    _card.layer.shadowColor = [UIColor blackColor].CGColor;
    _card.layer.shadowOpacity = 0.22;
    _card.layer.shadowOffset = CGSizeMake(0, 10);
    _card.layer.shadowRadius = 28;
    _card.clipsToBounds = NO;
    [self.view addSubview:_card];
    // 磨砂背景层（加在 card 最底层，子视图会自动在它上面）
    UIBlurEffectStyle bstyle;
    if (@available(iOS 13.0, *)) bstyle = UIBlurEffectStyleLight;
    else bstyle = UIBlurEffectStyleLight;
    UIBlurEffect *be = [UIBlurEffect effectWithStyle:bstyle];
    UIVisualEffectView *bvg = [[UIVisualEffectView alloc] initWithEffect:be];
    bvg.tag = 999;
    bvg.layer.cornerRadius = 22;
    bvg.clipsToBounds = YES;
    UIView *cardTint = [[UIView alloc] init];
    cardTint.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    cardTint.tag = 998;
    [_card addSubview:bvg];
    [_card addSubview:cardTint];

    // 顶部标题区（卡片内部）
    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.text = @"插件设置";
    titleLabel.font = [UIFont boldSystemFontOfSize:20];
    titleLabel.textColor = [UIColor colorWithWhite:0 alpha:0.9];
    titleLabel.tag = 101;
    [_card addSubview:titleLabel];

    // 关闭按钮（卡片右上角）
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    [closeBtn setTitleColor:[UIColor colorWithWhite:0 alpha:0.6] forState:UIControlStateNormal];
    closeBtn.backgroundColor = [UIColor colorWithWhite:0 alpha:0.06];
    closeBtn.layer.cornerRadius = 13;
    closeBtn.tag = 102;
    [closeBtn addTarget:self action:@selector(dismissSelf) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:closeBtn];

    // 全部开启按钮
    UIButton *allOnBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    [allOnBtn setTitle:@"🔓 全部开启" forState:UIControlStateNormal];
    allOnBtn.titleLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    [allOnBtn setTitleColor:[UIColor colorWithRed:0.1 green:0.5 blue:1 alpha:1] forState:UIControlStateNormal];
    allOnBtn.backgroundColor = [UIColor colorWithRed:0.1 green:0.5 blue:1 alpha:0.1];
    allOnBtn.layer.cornerRadius = 12;
    allOnBtn.tag = 103;
    [allOnBtn addTarget:self action:@selector(toggleAllOn) forControlEvents:UIControlEventTouchUpInside];
    [_card addSubview:allOnBtn];

    // 数据
    struct { NSString *t; BOOL *p; } raw[] = {
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
    int n = sizeof(raw)/sizeof(raw[0]);
    NSMutableArray *arr = [NSMutableArray array];
    for (int i = 0; i < n; i++) {
        [arr addObject:@{@"title": raw[i].t, @"ptr": [NSValue valueWithPointer:(const void *)raw[i].p]}];
    }
    _rows = arr;

    // TableView
    _tableView = [[UITableView alloc] init];
    _tableView.backgroundColor = [UIColor clearColor];
    _tableView.dataSource = self;
    _tableView.delegate = self;
    _tableView.rowHeight = 48;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    _tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    _tableView.separatorColor = [UIColor colorWithWhite:0 alpha:0.08];
    _tableView.scrollEnabled = NO;   // 卡片高度刚好容纳 9 行，不滚
    _tableView.tableFooterView = [[UIView alloc] init];
    [_card addSubview:_tableView];

    // 底部署名（卡片内）
    UILabel *footer = [[UILabel alloc] init];
    footer.text = @"by ashun520  ·  LCSign 注入版";
    footer.font = [UIFont systemFontOfSize:10.5];
    footer.textColor = [UIColor colorWithWhite:0 alpha:0.35];
    footer.textAlignment = NSTextAlignmentCenter;
    footer.tag = 104;
    [_card addSubview:footer];

    // 点遮罩关闭
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(dismissSelf)];
    tap.cancelsTouchesInView = NO;
    [_dimmingView addGestureRecognizer:tap];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds;
    _dimmingView.frame = b;

    // 卡片尺寸：宽 = 屏宽 - 32，高 = 标题区(70) + 9行(48*9) + 底部署名(32) = 534
    CGFloat cardW = MIN(b.size.width - 32, 420);
    CGFloat rowH = 48;
    CGFloat tableH = rowH * _rows.count;
    CGFloat headerH = 72;
    CGFloat footerH = 32;
    CGFloat cardH = headerH + tableH + footerH;

    CGFloat topInset = TTGStatusBarHeight();
    CGFloat availableTop = topInset + 20;
    CGFloat availableBottom = b.size.height - (b.size.height - (_card.frame.origin.y + cardH)) - 20;  // not used

    // 卡片居中，但上半部分优先（避开状态栏，也不碰到底部 tab）
    CGFloat maxTop = topInset + 60;
    CGFloat minBottom = 60;
    CGFloat idealTop = (b.size.height - cardH) / 2;
    CGFloat cardTop = MAX(maxTop, MIN(idealTop, b.size.height - cardH - minBottom));
    if (cardTop > b.size.height - cardH - minBottom) {
        cardTop = b.size.height - cardH - minBottom;
    }
    CGFloat cardX = (b.size.width - cardW) / 2;
    _card.frame = CGRectMake(cardX, cardTop, cardW, cardH);
    // 同步磨砂背景层
    UIVisualEffectView *bvg = (UIVisualEffectView *)[_card viewWithTag:999];
    UIView *cardTint = (UIView *)[_card viewWithTag:998];
    bvg.frame = _card.bounds;
    cardTint.frame = _card.bounds;

    // 卡片内部子视图
    UIView *card = _card;
    CGFloat W = cardW;

    UILabel *titleLabel = (UILabel *)[card viewWithTag:101];
    UIButton *closeBtn = (UIButton *)[card viewWithTag:102];
    UIButton *allOnBtn = (UIButton *)[card viewWithTag:103];
    UILabel *footer = (UILabel *)[card viewWithTag:104];

    titleLabel.frame = CGRectMake(18, 16, W - 90, 26);
    closeBtn.frame = CGRectMake(W - 40, 14, 26, 26);
    allOnBtn.frame = CGRectMake(18, 46, 84, 22);

    _tableView.frame = CGRectMake(0, headerH, W, tableH);

    footer.frame = CGRectMake(0, headerH + tableH + 4, W, 22);
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // 弹出动画：从缩放到正常
    _card.transform = CGAffineTransformMakeScale(0.85, 0.85);
    _card.alpha = 0;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.4 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_card.transform = CGAffineTransformIdentity;
        self->_card.alpha = 1;
        self->_dimmingView.alpha = 1;
    } completion:nil];
}

- (void)dismissSelf {
    [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)toggleAllOn {
    noads = downloadWithoutWatermark = autoPlayNextVideo = changeRegion = showProgressBar = canHideUI = enablePIP = enableBackgroundPlay = enableBypass = YES;
    [_tableView reloadData];
    TTGShowToast(@"✅ 所有功能已开启");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *ReuseId = @"TTGSettingsCell2";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ReuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:ReuseId];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
    }
    NSDictionary *row = _rows[indexPath.row];
    BOOL *flag = (BOOL *)[(NSValue *)row[@"ptr"] pointerValue];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.textColor = [UIColor colorWithWhite:0 alpha:0.85];

    UISwitch *sw = (UISwitch *)cell.accessoryView;
    if (!sw || ![sw isKindOfClass:[UISwitch class]]) {
        sw = [[UISwitch alloc] init];
        if (@available(iOS 13.0, *)) {
            sw.onTintColor = [UIColor systemGreenColor];
        } else {
            sw.onTintColor = [UIColor colorWithRed:0.3 green:0.75 blue:0.4 alpha:1];
        }
        cell.accessoryView = sw;
    }
    sw.tag = indexPath.row;
    sw.on = flag ? *flag : NO;
    [sw removeTarget:nil action:nil forControlEvents:UIControlEventValueChanged];
    [sw addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
}

- (void)switchToggled:(UISwitch *)sw {
    if (sw.tag < 0 || sw.tag >= (int)_rows.count) return;
    NSDictionary *row = _rows[sw.tag];
    BOOL *flag = (BOOL *)[(NSValue *)row[@"ptr"] pointerValue];
    if (flag) *flag = sw.isOn;
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    if (@available(iOS 13.0, *)) return UIStatusBarStyleDarkContent;
    return UIStatusBarStyleDefault;
}

@end

#pragma mark - 安全 hook

static void TTGInstallSafeHooks(void) {
    @try {
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillResignActiveNotification
            object:nil queue:[NSOperationQueue mainQueue]
            usingBlock:^(NSNotification *note) {
                if (enableBackgroundPlay) {
                    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:nil];
                }
            }];
        NSLog(@"[TTG] ✅ 后台播放 hook");

        if (changeRegion) {
            Class CTCarrier = NSClassFromString(@"CTCarrier");
            if (CTCarrier) {
                class_replaceMethod(CTCarrier, @selector(mcc), imp_implementationWithBlock(^id(id s){ return @"310"; }), "@@:");
                class_replaceMethod(CTCarrier, @selector(mnc), imp_implementationWithBlock(^id(id s){ return @"001"; }), "@@:");
                class_replaceMethod(CTCarrier, @selector(isoCountryCode), imp_implementationWithBlock(^id(id s){ return @"us"; }), "@@:");
                NSLog(@"[TTG] ✅ CTCarrier hook");
            }
        }
    } @catch (NSException *e) {
        NSLog(@"[TTG] hook install err: %@", e);
    }
}

#pragma mark - 保存图片

// 从 aweme 里提取所有图片 URL（支持图集/单图/封面）
static NSArray *TTGExtractImageURLs(id aweme) {
    if (!aweme) return nil;
    @try {
        NSMutableArray *urls = [NSMutableArray array];

        // 1. aweme.images → 图集（数组）
        NSArray *images = TTGGetValue(aweme, @"images");
        if ([images isKindOfClass:[NSArray class]]) {
            for (id img in images) {
                for (NSString *listKey in @[@"originURLList", @"urlList", @"urls"]) {
                    NSArray *list = TTGGetValue(img, listKey);
                    if ([list isKindOfClass:[NSArray class]]) {
                        for (id u in list) {
                            if ([u isKindOfClass:[NSString class]] && [u hasPrefix:@"http"]) {
                                [urls addObject:u];
                            } else if ([u isKindOfClass:[NSURL class]]) {
                                [urls addObject:[(NSURL *)u absoluteString]];
                            } else {
                                NSString *s = TTGGetValue(u, @"url");
                                if (s && [s hasPrefix:@"http"]) [urls addObject:s];
                            }
                        }
                    }
                }
            }
        }

        // 2. aweme.video.cover → 视频封面（兜底）
        if (urls.count == 0) {
            id video = TTGGetValue(aweme, @"video");
            if (video) {
                id cover = TTGGetValue(video, @"cover");
                if (!cover && [NSStringFromClass([aweme class]) containsString:@"Video"]) cover = video;
                if (cover) {
                    for (NSString *listKey in @[@"originURLList", @"urlList", @"urls"]) {
                        NSArray *list = TTGGetValue(cover, listKey);
                        if ([list isKindOfClass:[NSArray class]]) {
                            for (id u in list) {
                                if ([u isKindOfClass:[NSString class]] && [u hasPrefix:@"http"]) {
                                    [urls addObject:u]; break;
                                } else if ([u isKindOfClass:[NSURL class]]) {
                                    [urls addObject:[(NSURL *)u absoluteString]]; break;
                                }
                            }
                        }
                    }
                }
            }
        }

        NSLog(@"[TTG] 🖼️ 提取到 %lu 张图片", (unsigned long)urls.count);
        return urls;
    } @catch (NSException *e) {
        NSLog(@"[TTG] extract image err: %@", e);
        return nil;
    }
}

static void TTGDownloadImage(void) {
    @try {
        id aweme = TTGFindAwemeFromViewHierarchy();
        if (!aweme) { TTGShowToast(@"❌ 没找到当前内容"); return; }

        NSArray *urls = TTGExtractImageURLs(aweme);
        if (!urls || urls.count == 0) { TTGShowToast(@"❌ 没找到图片（视频类型无图）"); return; }

        TTGShowToast([NSString stringWithFormat:@"⏳ 保存 %lu 张图片中...", (unsigned long)urls.count]);

        // 检查相册权限
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status != PHAuthorizationStatusAuthorized) {
                TTGShowToast(@"❌ 没相册权限");
                return;
            }

            dispatch_group_t group = dispatch_group_create();
            __block int successCount = 0;

            for (int i = 0; i < (int)urls.count; i++) {
                NSString *urlStr = urls[i];
                dispatch_group_enter(group);

                NSURL *url = [NSURL URLWithString:urlStr];
                NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithURL:url
                    completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                        if (!error && location) {
                            UIImage *img = [UIImage imageWithContentsOfFile:location.path];
                            if (img) {
                                [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                                    [PHAssetChangeRequest creationRequestForAssetFromImage:img];
                                } completionHandler:^(BOOL ok, NSError *saveErr) {
                                    if (ok) { successCount++; NSLog(@"[TTG] 🖼️ ✅ 第 %d 张保存成功", i+1); }
                                    else NSLog(@"[TTG] 🖼️ ❌ 第 %d 张保存失败: %@", i+1, saveErr);
                                    dispatch_group_leave(group);
                                }];
                            } else {
                                dispatch_group_leave(group);
                            }
                        } else {
                            dispatch_group_leave(group);
                        }
                    }];
                [task resume];
            }

            dispatch_group_notify(group, dispatch_get_main_queue(), ^{
                if (successCount > 0) {
                    TTGShowToast([NSString stringWithFormat:@"✅ 已保存 %d 张图片", successCount]);
                } else {
                    TTGShowToast(@"❌ 全部保存失败");
                }
            });
        }];
    } @catch (NSException *e) {
        NSLog(@"[TTG] save image err: %@", e);
        TTGShowToast(@"❌ 保存出错");
    }
}

#pragma mark - 保存音乐（到 Files 目录）

// 从 aweme.music 提取音乐 URL
static NSString *TTGExtractMusicURL(id aweme) {
    if (!aweme) return nil;
    @try {
        id music = TTGGetValue(aweme, @"music");
        if (!music) {
            NSLog(@"[TTG] ❌ aweme 里没有 music 属性");
            return nil;
        }
        NSLog(@"[TTG] 🎵 music class=%@ props=%@", NSStringFromClass([music class]), [TTGPropertyListForClass([music class]) componentsJoinedByString:@","]);

        // 音乐 URL 通常在 playURL / downloadURL 里
        for (NSString *urlKey in @[@"playURL", @"downloadURL", @"playApi", @"url"]) {
            id urlModel = TTGGetValue(music, urlKey);
            if (!urlModel) continue;
            if ([urlModel isKindOfClass:[NSString class]] && [urlModel hasPrefix:@"http"]) {
                NSLog(@"[TTG] 🎵 music.%@ = %@", urlKey, urlModel);
                return urlModel;
            }
            for (NSString *listKey in @[@"originURLList", @"urlList", @"urls"]) {
                NSArray *list = TTGGetValue(urlModel, listKey);
                if ([list isKindOfClass:[NSArray class]] && [list count] > 0) {
                    id first = list[0];
                    if ([first isKindOfClass:[NSString class]] && [first hasPrefix:@"http"]) return first;
                    if ([first isKindOfClass:[NSURL class]]) return ((NSURL *)first).absoluteString;
                    NSString *surl = TTGGetValue(first, @"url");
                    if (surl && [surl hasPrefix:@"http"]) return surl;
                }
            }
            NSString *direct = TTGGetValue(urlModel, @"url");
            if (direct && [direct hasPrefix:@"http"]) return direct;
        }
    } @catch (NSException *e) {
        NSLog(@"[TTG] extract music err: %@", e);
    }
    return nil;
}

// 从 aweme.music 提取音乐名（用于保存文件名）
static NSString *TTGExtractMusicName(id aweme) {
    if (!aweme) return @"tiktok_music";
    @try {
        id music = TTGGetValue(aweme, @"music");
        if (!music) return @"tiktok_music";
        NSString *name = TTGGetValue(music, @"musicName");
        if (!name) name = TTGGetValue(music, @"title");
        if (!name) name = TTGGetValue(music, @"name");
        if (name && name.length > 0) {
            // 清理文件名
            name = [name stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
            name = [name stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
            return name;
        }
    } @catch (NSException *e) {}
    return @"tiktok_music";
}

static void TTGDownloadMusic(void) {
    @try {
        id aweme = TTGFindAwemeFromViewHierarchy();
        if (!aweme) { TTGShowToast(@"❌ 没找到当前内容"); return; }

        NSString *urlStr = TTGExtractMusicURL(aweme);
        if (!urlStr) { TTGShowToast(@"❌ 这首没音乐可保存"); return; }

        NSString *musicName = TTGExtractMusicName(aweme);
        NSLog(@"[TTG] 🎵 音乐名: %@ URL: %@", musicName, urlStr);

        TTGShowToast(@"⏳ 正在下载音乐...");

        // 保存到 tmp 然后复制到 Documents（Files App 可访问）
        NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *outPath = [docDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@_%.0f.mp3", musicName, [[NSDate date] timeIntervalSince1970]]];
        NSURL *outURL = [NSURL fileURLWithPath:outPath];
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];

        NSURL *url = [NSURL URLWithString:urlStr];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [req setValue:@"com.ss.android.ugc.aweme" forHTTPHeaderField:@"X-App-Pkg"];
        [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 com.ss.android.ugc.aweme/47.6.0" forHTTPHeaderField:@"User-Agent"];
        [req setTimeoutInterval:120];

        NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:req
            completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error || !location) {
                        TTGShowToast(@"❌ 下载音乐失败");
                        return;
                    }
                    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                    if (http.statusCode >= 400) {
                        TTGShowToast(@"❌ 音乐链接失效");
                        return;
                    }
                    [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
                    NSError *copyErr = nil;
                    if ([[NSFileManager defaultManager] copyItemAtURL:location toURL:outURL error:&copyErr]) {
                        NSLog(@"[TTG] 🎵 ✅ 已保存到 %@", outPath);
                        TTGShowToast([NSString stringWithFormat:@"✅ 音乐已存「文件」- %@", musicName]);
                    } else {
                        TTGShowToast(@"❌ 保存到文件失败");
                    }
                });
            }];
        [task resume];
    } @catch (NSException *e) {
        NSLog(@"[TTG] save music err: %@", e);
        TTGShowToast(@"❌ 保存出错");
    }
}

#pragma mark - 保存实况图片（Live Photo）

static void TTGDownloadLivePhoto(void) {
    @try {
        id aweme = TTGFindAwemeFromViewHierarchy();
        if (!aweme) { TTGShowToast(@"❌ 没找到当前内容"); return; }

        // 检查是否是实况内容（aweme.imageList 里的每个 item 如果有 photoMode=LivePhoto 或同时有静态图和视频片段）
        NSArray *images = TTGGetValue(aweme, @"images");
        if (![images isKindOfClass:[NSArray class]] || images.count == 0) {
            TTGShowToast(@"❌ 当前内容不是实况图片");
            return;
        }

        // 收集所有图片 URL（同保存图片，但标记为实况）
        NSMutableArray *imageURLs = [NSMutableArray array];
        NSMutableArray *videoURLs = [NSMutableArray array];

        for (id img in images) {
            // 图片
            for (NSString *listKey in @[@"originURLList", @"urlList", @"urls"]) {
                NSArray *list = TTGGetValue(img, listKey);
                if ([list isKindOfClass:[NSArray class]]) {
                    for (id u in list) {
                        NSString *s = nil;
                        if ([u isKindOfClass:[NSString class]]) s = u;
                        else if ([u isKindOfClass:[NSURL class]]) s = [(NSURL *)u absoluteString];
                        else s = TTGGetValue(u, @"url");
                        if (s && [s hasPrefix:@"http"]) { [imageURLs addObject:s]; break; }
                    }
                }
            }
            // 视频片段（实况的视频部分）
            id video = TTGGetValue(img, @"video");
            if (video) {
                for (NSString *listKey in @[@"originURLList", @"urlList", @"urls"]) {
                    NSArray *list = TTGGetValue(video, listKey);
                    if ([list isKindOfClass:[NSArray class]]) {
                        for (id u in list) {
                            NSString *s = nil;
                            if ([u isKindOfClass:[NSString class]]) s = u;
                            else if ([u isKindOfClass:[NSURL class]]) s = [(NSURL *)u absoluteString];
                            else s = TTGGetValue(u, @"url");
                            if (s && [s hasPrefix:@"http"]) { [videoURLs addObject:s]; break; }
                        }
                    }
                }
            }
        }

        if (imageURLs.count == 0) { TTGShowToast(@"❌ 没找到图片"); return; }

        // 如果没有视频片段，就是普通图片（不是实况）
        if (videoURLs.count == 0) {
            TTGShowToast(@"⚠️ 这张不是实况，改存普通图片");
            TTGDownloadImage();
            return;
        }

        TTGShowToast([NSString stringWithFormat:@"⏳ 保存 %lu 张实况中...", (unsigned long)imageURLs.count]);

        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            if (status != PHAuthorizationStatusAuthorized) { TTGShowToast(@"❌ 没相册权限"); return; }

            dispatch_group_t group = dispatch_group_create();
            __block int okCount = 0;

            for (int i = 0; i < (int)imageURLs.count && i < (int)videoURLs.count; i++) {
                dispatch_group_enter(group);

                // 下载图片 + 视频
                NSString *docDir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ttg_live"];
                [[NSFileManager defaultManager] createDirectoryAtPath:docDir withIntermediateDirectories:YES attributes:nil error:nil];
                NSString *imgPath = [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"live_%d.jpg", i]];
                NSString *vidPath = [docDir stringByAppendingPathComponent:[NSString stringWithFormat:@"live_%d.mov", i]];

                // 先下图片
                TTGBareDownload(imageURLs[i], [NSURL fileURLWithPath:imgPath], ^(BOOL imgOk, NSError *imgErr) {
                    if (!imgOk) { dispatch_group_leave(group); return; }
                    // 再下视频
                    TTGBareDownload(videoURLs[i], [NSURL fileURLWithPath:vidPath], ^(BOOL vidOk, NSError *vidErr) {
                        if (!vidOk) { dispatch_group_leave(group); return; }
                        // 合成为 Live Photo
                        NSURL *imgURL = [NSURL fileURLWithPath:imgPath];
                        NSURL *vidURL = [NSURL fileURLWithPath:vidPath];

                        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
                            PHAssetCreationRequest *req = [PHAssetCreationRequest creationRequestForAsset];
                            [req addResourceWithType:PHAssetResourceTypePhoto fileURL:imgURL options:nil];
                            [req addResourceWithType:PHAssetResourceTypePairedVideo fileURL:vidURL options:nil];
                        } completionHandler:^(BOOL saveOk, NSError *saveErr) {
                            if (saveOk) { okCount++; NSLog(@"[TTG] 📸 ✅ 第 %d 张实况保存成功", i+1); }
                            else NSLog(@"[TTG] 📸 ❌ 第 %d 张实况保存失败: %@", i+1, saveErr);
                            dispatch_group_leave(group);
                        }];
                    });
                });
            }

            dispatch_group_notify(group, dispatch_get_main_queue(), ^{
                if (okCount > 0) TTGShowToast([NSString stringWithFormat:@"✅ 已保存 %d 张实况", okCount]);
                else TTGShowToast(@"❌ 实况保存失败（API 限制或不是真实况）");
            });
        }];
    } @catch (NSException *e) {
        NSLog(@"[TTG] save livephoto err: %@", e);
        TTGShowToast(@"❌ 保存出错");
    }
}

#pragma mark - Constructor

__attribute__((constructor)) static void TTGInit(void) {
    NSLog(@"[TTG] 🚀 ctor 启动");
    TTGInstallSafeHooks();

    // 持续追踪 keyWindow，一旦出现就装手势（window 是最顶层，不会被内部 view 盖住）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        static dispatch_source_t timer = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(0.3 * NSEC_PER_SEC), (uint64_t)(0.15 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(timer, ^{
                @try {
                    // 1. 确保手势装在 window 上
                    UIWindow *win = TTGFrontmostWindow();
                    if (win) {
                        TTGInstallGesturesOnWindow(win);
                    }
                    // 2. 持续禁用所有子视图的长按手势（防止 TikTok 动态添加）
                    TTGDisableAllChildLongPresses();
                } @catch (NSException *e) {
                    NSLog(@"[TTG] poll err: %@", e);
                }
            });
            dispatch_resume(timer);
            NSLog(@"[TTG] 🔁 持续追踪 window + 禁用子视图长按 (每0.3s)");
        });
        // 立刻先跑一遍
        UIWindow *win = TTGFrontmostWindow();
        if (win) {
            TTGInstallGesturesOnWindow(win);
        }
    });
}
