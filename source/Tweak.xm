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

    // 去水印：playURL 有时带 watermark=1 参数，改成 0
    if ([urlStr containsString:@"watermark=1"]) {
        urlStr = [urlStr stringByReplacingOccurrencesOfString:@"watermark=1" withString:@"watermark=0"];
        NSLog(@"[TTG] 📥 去水印参数后: %@", urlStr);
    }
    if ([urlStr containsString:@".m3u8"]) {
        TTGShowToast(@"❌ 该视频为 m3u8 格式，暂不支持");
        return;
    }
    
    TTGShowToast(@"⏳ 正在下载...");
    
    NSURL *url = [NSURL URLWithString:urlStr];
    if (!url) { TTGShowToast(@"❌ URL 无效"); return; }
    
    // 用真实浏览器 UA，避免被 CDN 拒绝返回 HTML
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.5 Mobile/15E148 Safari/604.1" forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://www.tiktok.com/" forHTTPHeaderField:@"Referer"];
    [req setTimeoutInterval:30];
    
    NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:req
        completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            if (error || !location) {
                NSLog(@"[TTG] ❌ Download error: %@", error);
                dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 下载失败"); });
                return;
            }
            
            NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:location.path error:nil];
            long long fileSize = [attrs[NSFileSize] longLongValue];
            NSLog(@"[TTG] 📥 HTTP %ld  size=%lld  type=%@", (long)httpResp.statusCode, fileSize, httpResp.MIMEType);
            
            // 1) HTTP 错误检查
            if (httpResp && httpResp.statusCode >= 400) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    TTGShowToast([NSString stringWithFormat:@"❌ 下载失败 HTTP %ld", (long)httpResp.statusCode]);
                });
                return;
            }
            if (fileSize < 10 * 1024) {
                dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 下载内容无效"); });
                return;
            }
            
            // 2) 关键修复：复制到带 .mp4 扩展名的临时文件，否则 PhotoKit 认不出视频类型
            NSString *tmpPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                [NSString stringWithFormat:@"ttg_%.0f.mp4", [[NSDate date] timeIntervalSince1970]]];
            NSURL *mp4URL = [NSURL fileURLWithPath:tmpPath];
            NSError *copyErr = nil;
            [[NSFileManager defaultManager] removeItemAtURL:mp4URL error:nil];
            if (![[NSFileManager defaultManager] copyItemAtURL:location toURL:mp4URL error:&copyErr]) {
                NSLog(@"[TTG] ❌ copy error: %@", copyErr);
                dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 文件处理失败"); });
                return;
            }
            NSLog(@"[TTG] 📥 已复制到 %@", tmpPath);
            
            // 3) 用 AVFoundation 校验是不是真正的视频
            AVURLAsset *asset = [AVURLAsset URLAssetWithURL:mp4URL options:nil];
            BOOL hasVideoTrack = NO;
            for (AVAssetTrack *t in asset.tracks) {
                if ([t.mediaType isEqualToString:AVMediaTypeVideo]) { hasVideoTrack = YES; break; }
            }
            NSLog(@"[TTG] 📥 视频轨道=%d 时长=%.2f", hasVideoTrack, CMTimeGetSeconds(asset.duration));
            if (!hasVideoTrack) {
                [[NSFileManager defaultManager] removeItemAtURL:mp4URL error:nil];
                dispatch_async(dispatch_get_main_queue(), ^{ TTGShowToast(@"❌ 拿到的不是视频文件"); });
                return;
            }
            
            // 4) 保存到相册
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
                        if (ok) {
                            TTGShowToast(@"✅ 已保存到相册");
                        } else {
                            NSLog(@"[TTG] ❌ Save error: %@ %@", err.domain, err.localizedDescription);
                            TTGShowToast([NSString stringWithFormat:@"❌ 保存失败: %@", err.localizedDescription]);
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
