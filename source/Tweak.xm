/**
 * TikTok God — LCSign injection port (v3 — %property crash FIXED)
 *
 * Critical fix: REMOVED all %property! logos internal generator uses
 * class_addIvar for %property, which CRASHES on already-registered
 * classes (AWEPlayInteractionViewController, AWEFeedContainerViewController).
 * Replaced with objc_setAssociatedObject (runtime-safe, no class_addIvar).
 */

#include "Tweak.h"
#include "icons.h"
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/message.h>

#pragma mark - Global state (ALL ON by default)

BOOL noads = YES;
BOOL downloadWithoutWatermark = YES;
BOOL autoPlayNextVideo = YES;
BOOL changeRegion = YES;
BOOL showProgressBar = YES;
BOOL canHideUI = YES;
BOOL enableFavoritesCollections = YES;
BOOL enablePIP = YES;
BOOL enableBackgroundPlay = YES;
BOOL enableBypass = YES;
NSDictionary *region = @{@"mcc": @"310", @"mnc": @"001", @"code": @"us"};

static AVPictureInPictureController *g_pipController;
static AVPlayerLayer *g_pipPlayerLayer;
static AVPlayer *g_pipPlayer;

#pragma mark - Prefs

static NSString *TTGPrefsPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.haoict.tiktokgodpref.plist"];
}

static NSDictionary *TTGAllPrefs(void) {
    return @{
        @"noads": @(noads),
        @"downloadWithoutWatermark": @(downloadWithoutWatermark),
        @"autoPlayNextVideo": @(autoPlayNextVideo),
        @"changeRegion": @(changeRegion),
        @"showProgressBar": @(showProgressBar),
        @"canHideUI": @(canHideUI),
        @"enableFavoritesCollections": @(enableFavoritesCollections),
        @"enablePIP": @(enablePIP),
        @"enableBackgroundPlay": @(enableBackgroundPlay),
        @"enableBypass": @(enableBypass),
        @"region": region ?: @{}
    };
}

static void TTGSavePrefs(void) {
    [TTGAllPrefs() writeToFile:TTGPrefsPath() atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR(PREF_CHANGED_NOTIF), NULL, NULL, YES);
}

static void reloadPrefs(void) {
    NSDictionary *s = [[NSMutableDictionary alloc] initWithContentsOfFile:TTGPrefsPath()] ?: @{};
    if (s.allKeys.count == 0) return;
    noads = [[s objectForKey:@"noads"] ?: @(YES) boolValue];
    downloadWithoutWatermark = [[s objectForKey:@"downloadWithoutWatermark"] ?: @(YES) boolValue];
    autoPlayNextVideo = [[s objectForKey:@"autoPlayNextVideo"] ?: @(YES) boolValue];
    changeRegion = [[s objectForKey:@"changeRegion"] ?: @(YES) boolValue];
    showProgressBar = [[s objectForKey:@"showProgressBar"] ?: @(YES) boolValue];
    canHideUI = [[s objectForKey:@"canHideUI"] ?: @(YES) boolValue];
    enableFavoritesCollections = [[s objectForKey:@"enableFavoritesCollections"] ?: @(YES) boolValue];
    enablePIP = [[s objectForKey:@"enablePIP"] ?: @(YES) boolValue];
    enableBackgroundPlay = [[s objectForKey:@"enableBackgroundPlay"] ?: @(YES) boolValue];
    enableBypass = [[s objectForKey:@"enableBypass"] ?: @(YES) boolValue];
    NSDictionary *r = [s objectForKey:@"region"];
    if (r && r.allKeys.count) region = r;
}

#pragma mark - Associated object helpers (replace %property — class_addIvar crashes!)

static const void *kIsUIHiddenKey = &kIsUIHiddenKey;
static const void *kHideUIButtonKey = &kHideUIButtonKey;
static const void *kDownloadButtonKey = &kDownloadButtonKey;
static const void *kPipButtonKey = &kPipButtonKey;

static void TTGSetAssoc(id obj, const void *key, id val) {
    objc_setAssociatedObject(obj, key, val, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static id TTGGetAssoc(id obj, const void *key) {
    return objc_getAssociatedObject(obj, key);
}
static void TTGSetBoolAssoc(id obj, const void *key, BOOL val) {
    objc_setAssociatedObject(obj, key, @(val), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL TTGGetBoolAssoc(id obj, const void *key) {
    NSNumber *n = objc_getAssociatedObject(obj, key);
    return n ? n.boolValue : NO;
}

#pragma mark - Helpers

static UIImage *TTGIcon(const unsigned char *bytes, unsigned int len) {
    return [UIImage imageWithData:[NSData dataWithBytes:bytes length:len]];
}

static UIWindow *TTGFrontmostWindow(void) {
    if (@available(iOS 13.0, *)) {
        Class WSCls = NSClassFromString(@"UIWindowScene");
        if (WSCls) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:WSCls] && scene.activationState == UISceneActivationStateForegroundActive) {
                    NSArray *windows = [(id)scene windows];
                    for (UIWindow *w in windows) {
                        if (w.isKeyWindow || w.isHidden == NO) return w;
                    }
                    if (windows.firstObject) return windows.firstObject;
                }
            }
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if ([scene isKindOfClass:WSCls]) {
                    NSArray *windows = [(id)scene windows];
                    if (windows.firstObject) return windows.firstObject;
                }
            }
        }
    }
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (kw) return kw;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.isHidden) return w;
    }
    return nil;
}

static UIViewController *TTGTopViewController(UIWindow *win) {
    UIViewController *vc = win.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void TTGShowAlert(NSString *msg, NSString *title, UIViewController *fromVC) {
    UIWindow *win = TTGFrontmostWindow();
    UIViewController *vc = fromVC ?: (win ? TTGTopViewController(win) : nil);
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

static NSString *TTGGetVideoURL(AWEVideoModel *video) {
    NSArray *dlList = video.downloadURL.originURLList;
    NSString *dlURL = (NSString *)dlList.firstObject;
    if (dlURL.length > 0) return dlURL;
    NSArray *plList = video.playURL.originURLList;
    NSString *plURL = (NSString *)plList.firstObject;
    if (plURL.length > 0) return plURL;
    return nil;
}

#pragma mark - Native downloader

@interface TTGDownloader : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) void (^onProgress)(double);
@property (nonatomic, copy) void (^onDone)(BOOL, NSString *);
@end

@implementation TTGDownloader
- (void)downloadURLString:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) { if (self.onDone) self.onDone(NO, @"Invalid URL"); return; }
    [[[NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:nil] downloadTaskWithURL:url] resume];
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didWriteData:(int64_t)bw totalBytesWritten:(int64_t)tw totalBytesExpectedToWrite:(int64_t)te {
    if (te > 0 && self.onProgress) dispatch_async(dispatch_get_main_queue(), ^{ self.onProgress((double)tw / (double)te); });
}
- (void)URLSession:(NSURLSession *)s downloadTask:(NSURLSessionDownloadTask *)t didFinishDownloadingToURL:(NSURL *)location {
    NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ttg_video.mp4"];
    NSURL *dest = [NSURL fileURLWithPath:destPath];
    [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
    if (![[NSFileManager defaultManager] moveItemAtURL:location toURL:dest error:nil]) {
        if (self.onDone) self.onDone(NO, @"Move failed");
        return;
    }
    __block NSError *saveErr = nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{ [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:dest]; } error:&saveErr];
    [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
    if (self.onDone) self.onDone(saveErr == nil, saveErr.localizedDescription ?: nil);
}
- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    if (error && self.onDone) dispatch_async(dispatch_get_main_queue(), ^{ self.onDone(NO, error.localizedDescription); });
}
@end

#pragma mark - PiP + Background

static void TTGTogglePIP(NSString *videoURL) {
    Class pipCls = NSClassFromString(@"AVPictureInPictureController");
    if (!pipCls || !videoURL.length) { TTGShowAlert(@"PiP not supported", @"PiP", nil); return; }
    if (g_pipController && g_pipController.isPictureInPictureActive) { [g_pipController stopPictureInPicture]; return; }
    NSURL *url = [NSURL URLWithString:videoURL];
    if (!g_pipPlayer) g_pipPlayer = [AVPlayer playerWithURL:url];
    else { [g_pipPlayer replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:url]]; }
    if (!g_pipPlayerLayer) {
        g_pipPlayerLayer = [AVPlayerLayer layer];
        g_pipPlayerLayer.frame = CGRectMake(0, 0, 100, 100);
        UIWindow *win = TTGFrontmostWindow();
        [win.rootViewController.view.layer addSublayer:g_pipPlayerLayer];
    }
    g_pipPlayerLayer.player = g_pipPlayer;
    if (!g_pipController) g_pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:g_pipPlayerLayer];
    if ([AVPictureInPictureController isPictureInPictureSupported]) [g_pipController startPictureInPicture];
    else TTGShowAlert(@"PiP not supported on this device", @"PiP", nil);
}

static void TTGEnableBackgroundPlay(void) {
    if (!enableBackgroundPlay) return;
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers error:&err];
    [[AVAudioSession sharedInstance] setActive:YES error:&err];
}

#pragma mark - Settings Button

static BOOL g_buttonAttached = NO;

@interface TTGSettingsButton : UIButton
@property (nonatomic, assign) BOOL dragging;
@end

@implementation TTGSettingsButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithRed:1.0 green:0.15 blue:0.15 alpha:0.92];
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.borderWidth = 2.5;
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        self.titleLabel.font = [UIFont boldSystemFontOfSize:frame.size.width * 0.55];
        [self setTitle:@"G" forState:UIControlStateNormal];
        [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.5;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.layer.shadowRadius = 3;

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
        lp.minimumPressDuration = 0.4;
        [self addGestureRecognizer:lp];
        [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragging:)]];
    }
    return self;
}
- (void)tapped { if (self.dragging) { self.dragging = NO; return; } [self showPanel]; }
- (void)longPressed:(UILongPressGestureRecognizer *)g { if (g.state == UIGestureRecognizerStateBegan) [self showPanel]; }
- (void)dragging:(UIPanGestureRecognizer *)g {
    UIView *parent = self.superview;
    if (!parent) return;
    CGPoint p = [g translationInView:parent];
    CGPoint newCenter = CGPointMake(self.center.x + p.x, self.center.y + p.y);
    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    newCenter.x = MAX(halfW + 4, MIN(parent.bounds.size.width - halfW - 4, newCenter.x));
    newCenter.y = MAX(halfH + 50, MIN(parent.bounds.size.height - halfH - 100, newCenter.y));
    self.center = newCenter;
    [g setTranslation:CGPointZero inView:parent];
    if (g.state == UIGestureRecognizerStateChanged && (fabs(p.x) > 3 || fabs(p.y) > 3)) self.dragging = YES;
    if (g.state == UIGestureRecognizerStateEnded) {
        CGFloat bx = self.center.x, screenW = parent.bounds.size.width;
        CGFloat snapX = bx < screenW / 2 ? halfW + 14 : screenW - halfW - 14;
        [UIView animateWithDuration:0.25 animations:^{ self.center = CGPointMake(snapX, self.center.y); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ self.dragging = NO; });
    }
}
- (void)showPanel {
    UIWindow *win = TTGFrontmostWindow();
    UIViewController *vc = win ? TTGTopViewController(win) : nil;
    if (!vc) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self showPanel]; }); return; }

    UIAlertController *panel = [UIAlertController alertControllerWithTitle:@"🤖 TikTok God 设置" message:@"✅ = 开  ⬜ = 关" preferredStyle:UIAlertControllerStyleActionSheet];
    void (^addToggle)(NSString *, BOOL *, BOOL) = ^(NSString *title, BOOL *flag, BOOL restart) {
        NSString *fullTitle = [[(*flag ? @"✅ " : @"⬜️ ") stringByAppendingString:title] stringByAppendingString:restart ? @" (需重启)" : @""];
        [panel addAction:[UIAlertAction actionWithTitle:fullTitle style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            *flag = !*flag; TTGSavePrefs();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self showPanel]; });
        }]];
    };
    addToggle(@"去广告", &noads, NO);
    addToggle(@"无水印下载", &downloadWithoutWatermark, NO);
    addToggle(@"自动连播下一个", &autoPlayNextVideo, NO);
    addToggle(@"强制进度条可拖动", &showProgressBar, NO);
    addToggle(@"一键隐藏 UI", &canHideUI, NO);
    addToggle(@"切换地区 (US)", &changeRegion, YES);
    addToggle(@"画中画 PiP", &enablePIP, NO);
    addToggle(@"后台继续播放", &enableBackgroundPlay, NO);
    addToggle(@"绕过安全检测", &enableBypass, YES);
    addToggle(@"收藏合集入口", &enableFavoritesCollections, YES);
    [panel addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:panel animated:YES completion:nil];
}
@end

static void TTGTryAttachButton(int attempt) {
    if (g_buttonAttached) return;
    if (attempt > 40) { NSLog(@"[TTG] ⚠️ Gave up attaching button"); return; }
    UIWindow *win = TTGFrontmostWindow();
    if (!win) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TTGTryAttachButton(attempt + 1); });
        return;
    }
    for (UIView *v in win.subviews) { if ([v isKindOfClass:[TTGSettingsButton class]]) { g_buttonAttached = YES; return; } }
    CGFloat startY = 50 + win.safeAreaInsets.top + 34;
    TTGSettingsButton *btn = [[TTGSettingsButton alloc] initWithFrame:CGRectMake(14, startY, 40, 40)];
    btn.autoresizingMask = UIViewAutoresizingFlexibleBottomMargin | UIViewAutoresizingFlexibleRightMargin;
    [win addSubview:btn];
    g_buttonAttached = YES;
    NSLog(@"[TTG] ✅ Attached floating button on attempt %d", attempt);
}

#pragma mark - Hooks (NO %property — that CRASHES on registered classes!)

%group SecurityBypass
%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)p {
    if (enableBypass) {
        static NSArray *bypassPaths; static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ bypassPaths = @[
            @"/Applications/Cydia.app", @"/Applications/blackra1n.app", @"/Applications/Sileo.app",
            @"/usr/libexec/cydia/firmware.sh", @"/usr/bin/ssh",
            @"/Library/MobileSubstrate", @"/Library/TweakInject",
            @"/.cydia_no_stash", @"/.installed_unc0ver",
            @"/private/var/lib/cydia", @"/var/lib/cydia",
            @"/usr/lib/libjailbreak.dylib", @"/jb",
            @"/etc/apt", @"/var/log/apt", @"/Library/Application Support/Substrate"]; });
        if ([bypassPaths containsObject:p]) return NO;
    }
    return %orig;
}
- (BOOL)fileExistsAtPath:(NSString *)p isDirectory:(BOOL *)d { return [self fileExistsAtPath:p]; }
%end

%hook BDADeviceHelper +(BOOL)isJailBroken { return enableBypass ? NO : %orig; } %end
%hook TTInstallUtil +(BOOL)isJailBroken { return enableBypass ? NO : %orig; } %end
%hook IESLiveDeviceInfo +(BOOL)isJailBroken { return enableBypass ? NO : %orig; } %end
%hook AppsFlyerUtils +(BOOL)isJailBroken { return enableBypass ? NO : %orig; } %end
%hook BDInstallNetworkUtility +(BOOL)isJailBroken { return enableBypass ? NO : %orig; } %end
%hook TTAdSplashDeviceHelper +(BOOL)isJailBroken { return enableBypass ? NO : %orig; } %end
%hook GULAppEnvironmentUtil +(BOOL)isFromAppStore { return enableBypass ? YES : %orig; } +(BOOL)isAppStoreReceiptSandbox { return enableBypass ? NO : %orig; } %end
%hook FBSDKAppEventsUtility +(BOOL)isDebugBuild { return enableBypass ? NO : %orig; } %end
%hook AWEAPMManager +(NSString *)signInfo { return enableBypass ? @"AppStore" : %orig; } %end
%hook NSBundle
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)ext { if (enableBypass && [ext isEqualToString:@"mobileprovision"]) return nil; return %orig; }
- (NSData *)dataForResource:(NSString *)name ofType:(NSString *)ext { if (enableBypass && [ext isEqualToString:@"mobileprovision"]) return nil; return %orig; }
%end
%hook AWESecurity - (void)resetCollectMode { if (!enableBypass) %orig; } %end
%end

%group CoreLogic

%hook AWEAwemeModel
- (id)initWithDictionary:(id)arg1 error:(id *)arg2 { id orig = %orig; if (noads && self.isAds) return nil; return orig; }
- (id)init { id orig = %orig; if (noads && self.isAds) return nil; return orig; }
- (BOOL)progressBarDraggable { return showProgressBar || %orig; }
- (BOOL)progressBarVisible { return showProgressBar || %orig; }
%end

%hook CTCarrier
- (NSString *)mobileCountryCode { return (changeRegion && region[@"mcc"] != nil) ? region[@"mcc"] : %orig; }
- (NSString *)isoCountryCode { return (changeRegion && region[@"code"] != nil) ? region[@"code"] : %orig; }
- (NSString *)mobileNetworkCode { return (changeRegion && region[@"mnc"] != nil) ? region[@"mnc"] : %orig; }
%end

%hook AWEPlayVideoPlayerController
- (void)playerWillLoopPlaying:(id)arg1 {
    if (autoPlayNextVideo) {
        @try {
            if ([self.container.parentViewController respondsToSelector:@selector(scrollToNextVideo)]) {
                [self.container.parentViewController performSelector:@selector(scrollToNextVideo)];
                return;
            }
        } @catch (NSException *e) {}
    }
    %orig;
}
%end

%hook UIApplication
- (void)applicationWillResignActive:(UIApplication *)app { if (enableBackgroundPlay) TTGEnableBackgroundPlay(); %orig; }
- (void)applicationDidEnterBackground:(UIApplication *)app { if (enableBackgroundPlay) TTGEnableBackgroundPlay(); %orig; }
%end

// AWEFeedContainerViewController — NO %property! Use associated objects
static AWEFeedContainerViewController *__weak __ttg_shared_fcvc;
%hook AWEFeedContainerViewController
- (id)init { id orig = %orig; __ttg_shared_fcvc = orig; return orig; }
%end

// AWEPlayInteractionViewController — NO %property! Use associated objects
%hook AWEPlayInteractionViewController
- (void)viewDidLoad {
    %orig;
    if (downloadWithoutWatermark) {
        UIButton *dlBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        [dlBtn setImage:TTGIcon(icon_download, icon_download_len) forState:UIControlStateNormal];
        dlBtn.imageEdgeInsets = UIEdgeInsetsMake(3,3,3,3);
        dlBtn.frame = CGRectMake(self.view.bounds.size.width - 44, 135, 30, 30);
        [dlBtn addTarget:self action:@selector(__ttgDownloadAction:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:dlBtn];
        TTGSetAssoc(self, kDownloadButtonKey, dlBtn);
    }
    if (canHideUI) {
        UIButton *hBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        [hBtn setImage:TTGIcon(icon_hideui, icon_hideui_len) forState:UIControlStateNormal];
        hBtn.imageView.contentMode = UIViewContentModeScaleAspectFit;
        hBtn.imageEdgeInsets = UIEdgeInsetsMake(3,3,3,3);
        hBtn.frame = CGRectMake(self.view.bounds.size.width - 44, 100, 30, 30);
        [hBtn addTarget:self action:@selector(__ttgHideUIAction:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:hBtn];
        TTGSetAssoc(self, kHideUIButtonKey, hBtn);
    }
    if (enablePIP && NSClassFromString(@"AVPictureInPictureController")) {
        UIButton *pBtn = [UIButton buttonWithType:UIButtonTypeCustom];
        pBtn.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];
        pBtn.layer.cornerRadius = 14;
        pBtn.titleLabel.font = [UIFont systemFontOfSize:14];
        [pBtn setTitle:@"⤢" forState:UIControlStateNormal];
        [pBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        pBtn.frame = CGRectMake(self.view.bounds.size.width - 44, 170, 28, 28);
        [pBtn addTarget:self action:@selector(__ttgPIPAction:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:pBtn];
        TTGSetAssoc(self, kPipButtonKey, pBtn);
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    CGFloat right = self.view.bounds.size.width - 44;
    UIButton *dlBtn = TTGGetAssoc(self, kDownloadButtonKey);
    UIButton *hBtn = TTGGetAssoc(self, kHideUIButtonKey);
    UIButton *pBtn = TTGGetAssoc(self, kPipButtonKey);
    if (dlBtn) dlBtn.frame = CGRectMake(right, 135, 30, 30);
    if (hBtn) hBtn.frame = CGRectMake(right, 100, 30, 30);
    if (pBtn) pBtn.frame = CGRectMake(right, 170, 28, 28);
}

- (void)stopLoadingAnimation {
    %orig;
    if (canHideUI) dispatch_async(dispatch_get_main_queue(), ^{ [self __ttgUpdateUICheck]; });
}

// %new replaced with direct methods — logos %new might also cause issues
- (void)__ttgHideUIAction:(UIButton *)sender {
    AWEFeedContainerViewController *fcvc = __ttg_shared_fcvc;
    BOOL hidden = !TTGGetBoolAssoc(fcvc, kIsUIHiddenKey);
    TTGSetBoolAssoc(fcvc, kIsUIHiddenKey, hidden);
    [self __ttgUpdateUICheck];
}

- (void)__ttgDownloadAction:(UIButton *)sender {
    NSString *url = TTGGetVideoURL(self.model.video);
    if (!url.length) { TTGShowAlert(@"No video URL found", @"Error", self); return; }
    if ([url containsString:@".m3u8"]) { TTGShowAlert(@"m3u8 not supported", @"Not supported", self); return; }
    void (^startDownload)(void) = ^{
        UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Downloading…" message:@"0%" preferredStyle:UIAlertControllerStyleAlert];
        [self presentViewController:progress animated:YES completion:nil];
        TTGDownloader *dl = [TTGDownloader new];
        dl.onProgress = ^(double f) { progress.message = [NSString stringWithFormat:@"%.0f%%", f * 100]; };
        dl.onDone = ^(BOOL ok, NSString *err) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [progress dismissViewControllerAnimated:NO completion:^{
                    TTGShowAlert(ok ? @"Saved to Photos" : (err ?: @"Failed"), ok ? @"Done" : @"Error", nil);
                }];
            });
        };
        [dl downloadURLString:url];
    };
    if (@available(iOS 14.0, *)) { [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus s) { startDownload(); }]; }
    else { [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus s) { startDownload(); }]; }
}

- (void)__ttgPIPAction:(UIButton *)sender {
    NSString *url = TTGGetVideoURL(self.model.video);
    TTGTogglePIP(url);
}

- (void)__ttgUpdateUICheck {
    AWEFeedContainerViewController *fcvc = __ttg_shared_fcvc;
    BOOL hidden = TTGGetBoolAssoc(fcvc, kIsUIHiddenKey);
    [self setHide:hidden];
    UIButton *dlBtn = TTGGetAssoc(self, kDownloadButtonKey);
    UIButton *hBtn = TTGGetAssoc(self, kHideUIButtonKey);
    UIButton *pBtn = TTGGetAssoc(self, kPipButtonKey);
    [dlBtn setHidden:hidden];
    [hBtn setImage:hidden ? TTGIcon(icon_showui, icon_showui_len) : TTGIcon(icon_hideui, icon_hideui_len) forState:UIControlStateNormal];
    [pBtn setHidden:hidden];
    @try {
        if ([fcvc respondsToSelector:@selector(setAccessoriesHidden:)]) [fcvc setAccessoriesHidden:hidden];
        fcvc.tabControl.hidden = hidden;
        fcvc.specialEventEntranceView.hidden = hidden;
    } @catch (NSException *e) {}
}
%end

%hook AWEFavoriteAwemeViewController
- (id)init {
    if (enableFavoritesCollections) {
        Class cls = objc_getClass("TTKFavoriteAwemeCollectionsViewController");
        if (cls) return [cls new];
    }
    return %orig;
}
%end
%end // CoreLogic

#pragma mark - Ctor

%ctor {
    NSLog(@"[TTG] 🚀 ctor fired — registering hooks + starting button...");

    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    (CFNotificationCallback)reloadPrefs,
                                    CFSTR(PREF_CHANGED_NOTIF), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    reloadPrefs();

    if (enableBackgroundPlay) TTGEnableBackgroundPlay();

    // Attach button — multiple trigger points
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ TTGTryAttachButton(0); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!g_buttonAttached) TTGTryAttachButton(0); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!g_buttonAttached) TTGTryAttachButton(0); });

    // Init hooks
    @try {
        %init(SecurityBypass);
        NSLog(@"[TTG] ✅ SecurityBypass hooks registered");
    } @catch (NSException *e) { NSLog(@"[TTG] ❌ SecurityBypass init crashed: %@", e); }

    @try {
        %init(CoreLogic);
        NSLog(@"[TTG] ✅ CoreLogic hooks registered");
    } @catch (NSException *e) { NSLog(@"[TTG] ❌ CoreLogic init crashed: %@", e); }

    NSLog(@"[TTG] ctor done — hooks registered, button attaching");
}
