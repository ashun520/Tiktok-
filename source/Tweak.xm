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

#pragma mark - 全局：从 AVPlayer 抓正在播放的 URL

static NSMutableArray *g_playerURLs;  // @[@{@"url": NSURL, @"rate": NSNumber}]

static void TTGEnsurePlayerHook(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        g_playerURLs = [NSMutableArray array];

        Class AVPlayerItem = NSClassFromString(@"AVPlayerItem");
        if (AVPlayerItem) {
            Method m1 = class_getInstanceMethod(AVPlayerItem, @selector(initWithURL:));
            Method m2 = class_getInstanceMethod(AVPlayerItem, @selector(initWithAsset:));
            if (m1) {
                IMP orig = method_getImplementation(m1);
                IMP newImp = imp_implementationWithBlock(^id(id self, NSURL *url) {
                    if (url) {
                        @synchronized(g_playerURLs) {
                            [g_playerURLs addObject:@{@"url": url, @"rate": @(0)}];
                            if (g_playerURLs.count > 50) [g_playerURLs removeObjectsInRange:NSMakeRange(0, g_playerURLs.count - 50)];
                        }
                        NSLog(@"[TTG] 🎬 AVPlayerItem initWithURL: %@", url.absoluteString);
                    }
                    return ((id(*)(id, SEL, NSURL *))orig)(self, @selector(initWithURL:), url);
                });
                method_setImplementation(m1, newImp);
            }
            if (m2) {
                IMP orig = method_getImplementation(m2);
                IMP newImp = imp_implementationWithBlock(^id(id self, id asset) {
                    if ([asset isKindOfClass:NSClassFromString(@"AVURLAsset")]) {
                        NSURL *u = ((AVURLAsset *)asset).URL;
                        if (u) {
                            @synchronized(g_playerURLs) {
                                [g_playerURLs addObject:@{@"url": u, @"rate": @(0)}];
                                if (g_playerURLs.count > 50) [g_playerURLs removeObjectsInRange:NSMakeRange(0, g_playerURLs.count - 50)];
                            }
                            NSLog(@"[TTG] 🎬 AVPlayerItem initWithAsset: %@", u.absoluteString);
                        }
                    }
                    return ((id(*)(id, SEL, id))orig)(self, @selector(initWithAsset:), asset);
                });
                method_setImplementation(m2, newImp);
            }
        }
        NSLog(@"[TTG] ✅ AVPlayerItem hook installed");
    });
}

// 找最新出现的 TikTok 视频 URL（带签名字段的那个）
static NSString *TTGFindPlayerPlayableURL(void) {
    @synchronized(g_playerURLs) {
        // 遍历历史 URL，找 .mp4 结尾且 host 属于 TikTok CDN 的
        for (NSDictionary *entry in [g_playerURLs reverseObjectEnumerator]) {
            NSURL *u = entry[@"url"];
            if (!u) continue;
            NSString *abs = u.absoluteString;
            // 只要是 mp4 或者 bytevod / vcdn CDN host
            if ([abs containsString:@".mp4"] || [abs containsString:@"bytev.douyin.com"]
                || [abs containsString:@"v*.tiktokcdn.com"]
                || ([abs containsString:@"tiktokcdn"] && [abs containsString:@"video"])) {
                NSLog(@"[TTG] 🎯 命中 AVPlayer URL: %@", abs);
                return abs;
            }
        }
        // 次选：任何带 tiktokcdn / bytevod 的
        for (NSDictionary *entry in [g_playerURLs reverseObjectEnumerator]) {
            NSURL *u = entry[@"url"];
            if (!u) continue;
            NSString *abs = u.absoluteString;
            if ([abs containsString:@"tiktokcdn"] || [abs containsString:@"bytevod"] || [abs containsString:@"douyinvod"]) {
                NSLog(@"[TTG] 🎯 命中 CDN URL: %@", abs);
                return abs;
            }
        }
    }
    return nil;
}

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

// 判断一个对象是不是视频模型（aweme）
static BOOL TTGIsAwemeModel(id v) {
    if (!v || [v isKindOfClass:[NSNull class]]) return NO;
    NSString *cn = NSStringFromClass([v class]);
    if ([cn containsString:@"Aweme"]) return YES;
    if (TTGGetValue(v, @"video") && TTGGetValue(v, @"awemeId")) return YES;
    if (TTGGetValue(v, @"video") && TTGGetValue(v, @"desc")) return YES;
    return NO;
}

// 从任意对象（VC / Cell / View）里挖 aweme 模型
static id TTGAwemeFromObject(id obj) {
    if (!obj || [obj isKindOfClass:[NSNull class]]) return nil;

    for (NSString *k in TTGPropertyNamesForKeys()) {
        id v = TTGGetValue(obj, k);
        if (TTGIsAwemeModel(v)) return v;
    }

    Class cls = [obj class];
    unsigned int ivarCount = 0;
    Ivar *ivars = class_copyIvarList(cls, &ivarCount);
    if (ivars) {
        for (unsigned int i = 0; i < ivarCount; i++) {
            const char *iname = ivar_getName(ivars[i]);
            const char *itype = ivar_getTypeEncoding(ivars[i]);
            if (!iname || !itype || itype[0] != '@') continue;
            NSString *nsname = [NSString stringWithUTF8String:iname];
            if (!([nsname containsString:@"model"] || [nsname containsString:@"Model"]
                  || [nsname containsString:@"aweme"] || [nsname containsString:@"Aweme"])) continue;
            id v = object_getIvar(obj, ivars[i]);
            if (TTGIsAwemeModel(v)) { free(ivars); return v; }
        }
        free(ivars);
    }
    return nil;
}

// 递归遍历当前可见视图，收集所有候选模型及其可见面积
static void TTGCollectVisibleModels(UIView *view, NSMutableArray *out,
                                   NSMutableSet *seenVCs, int depth) {
    if (!view || depth > 40) return;
    if (view.hidden || view.alpha < 0.01 || view.window == nil) return;

    // 1) 视图自己可能就是 Cell（cell.model）
    id m = TTGAwemeFromObject(view);
    if (m) {
        CGRect f = [view convertRect:view.bounds toView:nil];
        CGFloat area = f.size.width * f.size.height;
        [out addObject:@{@"model": m, @"area": @(area)}];
    }

    // 2) 视图所属的 VC
    UIResponder *r = view.nextResponder;
    int guard = 0;
    while (r && guard++ < 30 && ![r isKindOfClass:[UIViewController class]]) r = r.nextResponder;
    if (r && [r isKindOfClass:[UIViewController class]] && ![seenVCs containsObject:r]) {
        [seenVCs addObject:r];
        id vm = TTGAwemeFromObject(r);
        if (vm) {
            CGRect f = [view convertRect:view.bounds toView:nil];
            CGFloat area = f.size.width * f.size.height;
            [out addObject:@{@"model": vm, @"area": @(area)}];
        }
    }

    for (UIView *sub in view.subviews) {
        TTGCollectVisibleModels(sub, out, seenVCs, depth + 1);
    }
}

// 扫描当前真正显示在屏幕上的那个视频
static id TTGScanVisibleAweme(void) {
    UIWindow *win = TTGFrontmostWindow();
    if (!win) return nil;
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seenVCs = [NSMutableSet set];
    TTGCollectVisibleModels(win, out, seenVCs, 0);

    id best = nil;
    CGFloat bestArea = -1;
    for (NSDictionary *d in out) {
        CGFloat a = [d[@"area"] doubleValue];
        if (a > bestArea) { bestArea = a; best = d[@"model"]; }
    }
    NSLog(@"[TTG] 🔎 可见候选 %lu 个，选中面积 %.0f，模型 %@",
          (unsigned long)out.count, bestArea, best ? NSStringFromClass([best class]) : @"nil");
    return best;
}

static id TTGGetCurrentAweme(void) {
    // 每次都重新扫描可见视图 —— 绝对不能直接返回旧缓存
    id fresh = TTGScanVisibleAweme();
    if (fresh) { g_currentAweme = fresh; return fresh; }

    // 兜底 1：top VC 递归
    UIViewController *top = TTGTopViewController();
    if (top) {
        id found = TTGFindAwemeInVCRecursive(top, 0);
        if (found) { g_currentAweme = found; return found; }
    }

    // 兜底 2：所有 window 的 rootVC 递归
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
    
    // 尝试各种 URL model 属性（playURL 优先 = 无水印，与原版 haoict 一致）
    NSArray *urlModelKeys = @[@"playURL", @"playAddr", @"playApi", @"downloadURL", @"downloadAddr", @"streamURL", @"bitRateURL"];
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

static void TTGDownloadWithNSURLSession(NSURL *url, NSURL *outURL);
static void TTGFinishSave(NSURL *mp4URL);

static void TTGDownloadCurrent(void) {
    // 0) 确保 AVPlayer hook 装好了
    TTGEnsurePlayerHook();

    // 1) 先拿 AVPlayer 正在播放的 URL（签名过的、不会 403）
    NSString *urlStr = TTGFindPlayerPlayableURL();
    BOOL fromPlayer = YES;
    if (!urlStr) {
        // 2) AVPlayer 还没 URL → 走 aweme model（兜底）
        id aweme = TTGGetCurrentAweme();
        if (!aweme) { TTGShowToast(@"❌ 找不到当前视频"); return; }
        urlStr = TTGFindBestVideoURL(aweme);
        fromPlayer = NO;
    }

    if (!urlStr) { TTGShowToast(@"❌ 拿不到视频链接"); return; }
    NSLog(@"[TTG] 📥 URL source=%@ url=%@", fromPlayer ? @"AVPlayer" : @"awemeModel", urlStr);

    if ([urlStr containsString:@".m3u8"]) {
        TTGShowToast(@"❌ 该视频为 m3u8 格式，暂不支持");
        return;
    }

    TTGShowToast(@"⏳ 正在下载...");
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { TTGShowToast(@"❌ URL 无效"); return; }

    // 关键：用 AVURLAsset 来加载视频（它内部用 TikTok 注册的 loader，带 CDN 签名）
    // 然后用 AVAssetExportSession 导出到本地文件
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:@{
        AVURLAssetPreferPreciseDurationAndTimingKey: @YES
    }];

    // 临时输出文件
    NSString *outPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"ttg_%.0f.mp4", [[NSDate date] timeIntervalSince1970]]];
    NSURL *outURL = [NSURL fileURLWithPath:outPath];
    [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];

    NSArray *presets = @[AVAssetExportPresetHighestQuality, AVAssetExportPreset1280x720, AVAssetExportPresetMediumQuality, AVAssetExportPresetPassthrough];

    void (^tryExport)(int) = ^void(int idx) {
        if (idx >= presets.count) {
            // AVAsset 方式也失败了 → 降级用裸 NSURLSession（给它 TikTok 风格的请求头）
            NSLog(@"[TTG] ⚠️ AVAsset 导出全部失败，降级裸下载");
            TTGDownloadWithNSURLSession(url, outURL);
            return;
        }
        NSString *preset = presets[idx];
        AVAssetExportSession *exporter = [AVAssetExportSession exportSessionWithAsset:asset presetName:preset];
        if (!exporter) { tryExport(idx + 1); return; }
        exporter.outputURL = outURL;
        exporter.outputFileType = AVFileTypeMPEG4;
        exporter.shouldOptimizeForNetworkUse = NO;

        [exporter exportAsynchronouslyWithCompletionHandler:^{
            AVAssetExportSessionStatus s = exporter.status;
            NSError *err = exporter.error;
            NSLog(@"[TTG] 📦 export preset=%@ status=%ld error=%@", preset, (long)s, err);
            if (s == AVAssetExportSessionStatusCompleted) {
                TTGFinishSave(outURL);
            } else if (s == AVAssetExportSessionStatusFailed || s == AVAssetExportSessionStatusCancelled) {
                tryExport(idx + 1);
            } else {
                // waiting / exporting 理论上 completion 里不会出现
                tryExport(idx + 1);
            }
        }];
    };
    tryExport(0);
}

// 裸 NSURLSession 降级（所有 AVAsset preset 都失败才会走到这）
static void TTGDownloadWithNSURLSession(NSURL *url, NSURL *outURL) {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 Version/16.5 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    [req setTimeoutInterval:60];

    [[[NSURLSession sharedSession] downloadTaskWithRequest:req completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        if (error || !location) {
            NSLog(@"[TTG] ❌ 裸下载 error: %@", error);
            dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 下载失败"); });
            return;
        }
        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        long long size = [[[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:nil][NSFileSize] longLongValue];
        NSLog(@"[TTG] 🔧 裸下载 HTTP %ld size=%lld", (long)httpResp.statusCode, size);
        if (httpResp.statusCode >= 400 || size < 10240) {
            dispatch_async(dispatch_get_main_queue(), ^{
                TTGShowToast([NSString stringWithFormat:@"❌ 下载失败 HTTP %ld（此链接无签名）", (long)httpResp.statusCode]);
            });
            return;
        }
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
        [[NSFileManager defaultManager] copyItemAtURL:location toURL:outURL error:nil];
        TTGFinishSave(outURL);
    }] resume];
}

static void TTGFinishSave(NSURL *mp4URL) {
    // 校验
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mp4URL options:nil];
    BOOL hasVideo = NO;
    for (AVAssetTrack *t in asset.tracks) {
        if ([t.mediaType isEqualToString:AVMediaTypeVideo]) { hasVideo = YES; break; }
    }
    if (!hasVideo) {
        [[NSFileManager defaultManager] removeItemAtURL:mp4URL error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 拿到的不是视频文件"); });
        return;
    }

    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized) {
            [[NSFileManager defaultManager] removeItemAtURL:mp4URL error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 没有相册权限"); });
            return;
        }
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:mp4URL];
        } completionHandler:^(BOOL ok, NSError *err) {
            [[NSFileManager defaultManager] removeItemAtURL:mp4URL error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (ok) TTGShowToast(@"✅ 已保存到相册");
                else {
                    NSLog(@"[TTG] ❌ PhotoKit save error: %@", err);
                    TTGShowToast([NSString stringWithFormat:@"❌ 保存失败: %@", err.localizedDescription]);
                }
            });
        }];
    }];
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
        
        // 只 hook 已知的播放器/卡片类，避免污染继承方法导致永远拿到第一个模型
        NSArray *modelClassNames = @[
            @"AWEPlayInteractionViewController",
            @"AWEPlayVideoViewController",
            @"AWEFeedCellViewController",
            @"AWEPlayVideoCell",
            @"AWEPlayInteractionView",
        ];
        SEL setModelSel = @selector(setModel:);
        for (NSString *name in modelClassNames) {
            Class cls = NSClassFromString(name);
            if (!cls) { NSLog(@"[TTG] ⚠️ 类不存在: %@", name); continue; }
            Method m = class_getInstanceMethod(cls, setModelSel);
            if (!m) { NSLog(@"[TTG] ⚠️ 无 setModel: %@", name); continue; }
            const char *types = method_getTypeEncoding(m);
            if (!types || types[0] != 'v' || types[1] != '@' || types[2] != ':') continue;
            IMP orig = method_getImplementation(m);
            IMP newImp = imp_implementationWithBlock(^(id self, id model) {
                if (TTGIsAwemeModel(model)) g_currentAweme = model;
                ((void(*)(id, SEL, id))orig)(self, setModelSel, model);
            });
            class_replaceMethod(cls, setModelSel, newImp, types);
            NSLog(@"[TTG] ✅ %@.setModel: 已 hook", name);
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

__attribute__((constructor)) static void TTGInit(void) {
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
