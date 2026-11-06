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

@class TTGSettingsViewController;

// 自定义手势类：完全绕过系统 UILongPressGestureRecognizer 机制
// 自己用 dispatch_after 控时，0.4s 内手指没移动则立刻 BEGAN
// 没有任何 delegate 依赖问题
@interface TTGOneFingerHoldRecognizer : UIGestureRecognizer
@property (nonatomic, assign) NSTimeInterval holdDuration;  // 默认 0.4
@property (nonatomic, assign) CGFloat allowableMovement;    // 默认 10
@end

@implementation TTGOneFingerHoldRecognizer {
    CGPoint _startPoint;
    BOOL _fired;
    __block BOOL _cancelled;
}

- (instancetype)initWithTarget:(id)target action:(SEL)action {
    if ((self = [super initWithTarget:target action:action])) {
        _holdDuration = 0.4;
        _allowableMovement = 10;
        self.cancelsTouchesInView = YES;
        self.delaysTouchesBegan = NO;
        self.delaysTouchesEnded = NO;
    }
    return self;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (touches.count != 1) { self.state = UIGestureRecognizerStateFailed; return; }
    _startPoint = [[touches anyObject] locationInView:self.view];
    _fired = NO;
    _cancelled = NO;
    NSLog(@"[TTG] 👆 touchesBegan count=1");
    __weak typeof(self) wself = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.holdDuration * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (_cancelled) { NSLog(@"[TTG] 👆 timer 触发但已取消"); return; }
        __strong typeof(wself) self = wself;
        if (!self) return;
        if (self.state == UIGestureRecognizerStatePossible) {
            self->_fired = YES;
            NSLog(@"[TTG] ✅ 👆 timer 到点 → set state=Began");
            self.state = UIGestureRecognizerStateBegan;
        }
    });
}

// 关键：第二个手指按下时取消 timer（否则双指操作也会先 fire 单指）
- (void)touchesAdded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    NSLog(@"[TTG] 👆 touchesAdded count=%lu → 取消单指 timer", (unsigned long)self.numberOfTouches);
    _cancelled = YES;
    self.state = UIGestureRecognizerStateFailed;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (_fired) { self.state = UIGestureRecognizerStateChanged; return; }
    CGPoint now = [[touches anyObject] locationInView:self.view];
    CGFloat dx = now.x - _startPoint.x;
    CGFloat dy = now.y - _startPoint.y;
    if (sqrtf(dx*dx + dy*dy) > self.allowableMovement) {
        NSLog(@"[TTG] 👆 手指移动过大 → cancel (%.1f,%.1f)", dx, dy);
        _cancelled = YES;
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _cancelled = YES;
    if (_fired && self.state != UIGestureRecognizerStateEnded) {
        self.state = UIGestureRecognizerStateEnded;
    } else {
        self.state = UIGestureRecognizerStateFailed;
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    _cancelled = YES;
    self.state = UIGestureRecognizerStateCancelled;
}

- (void)reset {
    [super reset];
    _cancelled = YES;
    _fired = NO;
}
@end

@interface TTGLongPressHandler : NSObject
+ (instancetype)shared;
- (void)handleSingleLongPress:(UIGestureRecognizer *)gr;
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
    _sheetH = 280;   // 改小（只有按钮，没有滑块）
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
    // 行1：主动作（保存视频、保存图片、保存音乐、设置）
    // 行2-3：开关（2列）
    NSArray *actionBtns = @[
        @{@"icon": @"arrow.down.circle.fill", @"title": @"保存视频", @"action": ^{ TTGDownloadAndSave(); }},
        @{@"icon": @"photo.on.rectangle", @"title": @"保存图片", @"action": ^{ TTGDownloadImage(); }},
        @{@"icon": @"music.note", @"title": @"保存音乐", @"action": ^{ TTGDownloadMusic(); }},
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
    // 关闭按钮
    UIButton *sheetClose = [UIButton buttonWithType:UIButtonTypeSystem];
    [sheetClose setTitle:@"关闭" forState:UIControlStateNormal];
    sheetClose.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [sheetClose setTitleColor:[UIColor colorWithWhite:0 alpha:0.6] forState:UIControlStateNormal];
    sheetClose.backgroundColor = [UIColor colorWithWhite:0 alpha:0.08];
    sheetClose.layer.cornerRadius = 22;
    [sheetClose addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    sheetClose.tag = 9003;
    [_sheet addSubview:sheetClose];

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

    // 按钮容器：y = 70, 2行 x 2列 = 106pt
    UIView *btnContainer = (UIView *)[_sheet viewWithTag:9001];
    btnContainer.frame = CGRectMake(pad, 68, W - pad * 2, 106);

    // 关闭按钮
    UIButton *sheetClose = (UIButton *)[_sheet viewWithTag:9003];
    sheetClose.frame = CGRectMake((W - 100) / 2, _sheetH - 56, 100, 40);

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

// 手势装到 window 上（最顶层，不会被内部子视图盖住）
static NSHashTable *_ttg_windowsWithGesture = nil;

@implementation TTGLongPressHandler
+ (instancetype)shared {
    static TTGLongPressHandler *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[TTGLongPressHandler alloc] init]; });
    return inst;
}
// 单指长按 → 动作面板（保存视频/图片/音乐）
- (void)handleSingleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state == UIGestureRecognizerStateBegan) {
        NSLog(@"[TTG] 👆 单指长按 → 动作面板");
        TTGActionPanelView *panel = [[TTGActionPanelView alloc] init];
        [panel show];
    }
}
// 双指长按 → 设置面板（插件开关）
- (void)handleDoubleLongPress:(UILongPressGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateBegan) return;
    NSLog(@"[TTG] ✌️ 双指长按 → 设置面板");
    UIViewController *topVC = TTGTopVC();
    if (!topVC) return;
    Class cls = NSClassFromString(@"TTGSettingsViewController");
    if (!cls) { NSLog(@"[TTG] ❌ TTGSettingsViewController 未找到"); return; }
    UIViewController *vc = [[cls alloc] init];
    if (!vc) return;
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    // 不用系统 transitionStyle —— CrossDissolve 本身就有一层淡入，再叠加 present 动画 = 闪两次
    vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    // 用 animated:NO + 自己做淡入 → 只有一层动画，不闪
    vc.view.alpha = 0;
    [topVC presentViewController:vc animated:NO completion:^{
        [UIView animateWithDuration:0.2 animations:^{
            vc.view.alpha = 1;
        }];
    }];
}

// MARK: - UIGestureRecognizerDelegate
// window 上的手势（我们自己装的）互相不 require，否则死锁
// 只让子视图（TikTok 内部）的长按/tap require 我们失败
// （不返回 YES 给 shouldRecognizeSimultaneously，iOS 默认互斥 → 我们到点立刻 Began）
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // 排除：other 也在 window 上（也是我们装的），不互相 require
    if (otherGestureRecognizer.view && [otherGestureRecognizer.view isKindOfClass:[UIWindow class]]) {
        return NO;
    }
    // 只让子视图的长按/tap require 我们失败（我们 0.4s 先触发，早于 TikTok 的 0.5s）
    // pan/swipe/pinch 一律放行，保证上下滑动正常
    if ([otherGestureRecognizer isKindOfClass:[UILongPressGestureRecognizer class]] ||
        [otherGestureRecognizer isKindOfClass:[UITapGestureRecognizer class]]) {
        return YES;
    }
    return NO;
}
@end

static void TTGInstallGesturesOnWindow(UIWindow *win) {
    if (!win) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        _ttg_windowsWithGesture = [NSHashTable weakObjectsHashTable];
    });
    if ([_ttg_windowsWithGesture containsObject:win]) return;

    // 单指长按 —— 用完全自定义的手势类，自己控 timer
    // 不跟系统 UILongPressGestureRecognizer 有任何依赖，绕过所有 require/simultaneous 问题
    TTGOneFingerHoldRecognizer *single = [[TTGOneFingerHoldRecognizer alloc]
        initWithTarget:[TTGLongPressHandler shared] action:@selector(handleSingleLongPress:)];

    // 双指长按（保持系统类，因为它能用）
    UILongPressGestureRecognizer *dbl = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[TTGLongPressHandler shared] action:@selector(handleDoubleLongPress:)];
    dbl.minimumPressDuration = 0.5;
    dbl.numberOfTouchesRequired = 2;
    dbl.allowableMovement = 30;
    dbl.cancelsTouchesInView = YES;
    dbl.delaysTouchesBegan = NO;
    dbl.delaysTouchesEnded = NO;

    // 自定义单指手势 不需要任何 delegate —— 自己 timer 到点直接 BEGAN，无视任何其他手势
    // 双指 delegate：让子视图长按等双指失败（避免双指操作时 TikTok 内部长按误触）
    dbl.delegate = (id<UIGestureRecognizerDelegate>)[TTGLongPressHandler shared];

    [win addGestureRecognizer:single];
    [win addGestureRecognizer:dbl];
    [_ttg_windowsWithGesture addObject:win];
    NSLog(@"[TTG] ✋ 手势已装到 window: %@", win);
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

#pragma mark - 保存图片/音乐（占位，后续补完整）

static void TTGDownloadImage(void) {
    TTGShowToast(@"🖼️ 图片保存开发中，先用保存视频");
}

static void TTGDownloadMusic(void) {
    TTGShowToast(@"🎵 音乐保存开发中");
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
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC, (uint64_t)(0.5 * NSEC_PER_SEC));
            dispatch_source_set_event_handler(timer, ^{
                @try {
                    UIWindow *win = TTGFrontmostWindow();
                    if (win) {
                        TTGInstallGesturesOnWindow(win);
                    }
                } @catch (NSException *e) {
                    NSLog(@"[TTG] poll err: %@", e);
                }
            });
            dispatch_resume(timer);
            NSLog(@"[TTG] 🔁 持续追踪 window，每秒检查一次");
        });
        // 立刻先跑一遍
        UIWindow *win = TTGFrontmostWindow();
        if (win) {
            TTGInstallGesturesOnWindow(win);
        }
    });
}
