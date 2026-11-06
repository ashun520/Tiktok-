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
        UIView *toast = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 56)];
        toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.9];
        toast.layer.cornerRadius = 28;
        toast.center = win.center;
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(toast.bounds, 10, 8)];
        label.text = msg;
        label.textColor = [UIColor whiteColor];
        label.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        label.textAlignment = NSTextAlignmentCenter;
        label.numberOfLines = 0;
        [toast addSubview:label];
        toast.alpha = 0;
        [win addSubview:toast];
        [UIView animateWithDuration:0.2 animations:^{ toast.alpha = 1; } completion:^(BOOL _) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 animations:^{ toast.alpha = 0; } completion:^(BOOL __) { [toast removeFromSuperview]; }];
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
        } @catch (NSException *e) {}
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

#pragma mark - Constructor

__attribute__((constructor)) static void TTGInit(void) {
    NSLog(@"[TTG] 🚀 ctor 启动");
    TTGInstallSafeHooks();

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
