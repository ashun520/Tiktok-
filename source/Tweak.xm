/**
 * TikTok God — LCSign injection port (enhanced)
 * Based on haoict/tiktok-god (MIT) — https://github.com/haoict/tiktok-god
 *
 * Enhancements for LCSign injection:
 *   - Jailbreak bypass (non-jailbreak env also needs this for TikTok security)
 *   - All features ON by default
 *   - In-app settings panel (long-press floating dot in top-left)
 *   - Picture-in-Picture support
 *   - Background video playback
 *   - Cleaner watermark-free URL (downloadURL preferred)
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

// PiP global refs
static AVPictureInPictureController *g_pipController;
static AVPlayerLayer *g_pipPlayerLayer;
static AVPlayer *g_pipPlayer;

#pragma mark - Prefs (sandbox plist, NOT /var/mobile)

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
    if (s.allKeys.count == 0) return; // first run, keep all-on defaults

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

#pragma mark - Helpers

static UIImage *TTGIcon(const unsigned char *bytes, unsigned int len) {
    return [UIImage imageWithData:[NSData dataWithBytes:bytes length:len]];
}

static UIViewController *TTGTopViewController(void) {
    UIViewController *rootVC = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]] && scene.activationState == UISceneActivationStateForegroundActive) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (@available(iOS 15.0, *)) rootVC = ws.keyWindow.rootViewController;
                else rootVC = ws.windows.firstObject.rootViewController;
                break;
            }
        }
    }
    if (!rootVC) rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
    return rootVC;
}

static void TTGShowAlert(NSString *msg, NSString *title, UIViewController *fromVC) {
    UIViewController *vc = fromVC ?: TTGTopViewController();
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

/// Pick the cleanest watermark-free URL for download
static NSString *TTGGetVideoURL(AWEVideoModel *video) {
    NSArray *dlList = video.downloadURL.originURLList;
    NSString *dlURL = (NSString *)dlList.firstObject;
    if (dlURL.length > 0) return dlURL;

    NSArray *plList = video.playURL.originURLList;
    NSString *plURL = (NSString *)plList.firstObject;
    if (plURL.length > 0) return plURL;

    return nil;
}

#pragma mark - Native downloader (replaces libhdev)

@interface TTGDownloader : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) void (^onProgress)(double);
@property (nonatomic, copy) void (^onDone)(BOOL, NSString *);
- (void)downloadURLString:(NSString *)urlString;
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
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:dest];
    } error:&saveErr];
    [[NSFileManager defaultManager] removeItemAtURL:dest error:nil];
    if (self.onDone) self.onDone(saveErr == nil, saveErr.localizedDescription ?: nil);
}

- (void)URLSession:(NSURLSession *)s task:(NSURLSessionTask *)t didCompleteWithError:(NSError *)error {
    if (error && self.onDone) dispatch_async(dispatch_get_main_queue(), ^{ self.onDone(NO, error.localizedDescription); });
}
@end

#pragma mark - Picture-in-Picture helper

static void TTGTogglePIP(NSString *videoURL) {
    Class pipCls = NSClassFromString(@"AVPictureInPictureController");
    if (!pipCls || !videoURL.length) {
        TTGShowAlert(@"PiP not supported or no video URL", @"PiP", nil);
        return;
    }

    if (g_pipController && g_pipController.isPictureInPictureActive) {
        [g_pipController stopPictureInPicture];
        return;
    }

    NSURL *url = [NSURL URLWithString:videoURL];
    if (!g_pipPlayer) g_pipPlayer = [AVPlayer playerWithURL:url];
    else { [g_pipPlayer replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:url]]; }

    if (!g_pipPlayerLayer) {
        g_pipPlayerLayer = [AVPlayerLayer layer];
        g_pipPlayerLayer.frame = CGRectMake(0, 0, 100, 100);
        UIView *host = TTGTopViewController().view;
        if (host) [host.layer addSublayer:g_pipPlayerLayer];
    }
    g_pipPlayerLayer.player = g_pipPlayer;

    if (!g_pipController) g_pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:g_pipPlayerLayer];
    if ([AVPictureInPictureController isPictureInPictureSupported]) {
        [g_pipController startPictureInPicture];
    } else {
        TTGShowAlert(@"PiP not supported on this device", @"PiP", nil);
    }
}

#pragma mark - Background play helper

static void TTGEnableBackgroundPlay(void) {
    if (!enableBackgroundPlay) return;
    NSError *err = nil;
    [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback
                                     withOptions:AVAudioSessionCategoryOptionMixWithOthers
                                           error:&err];
    [[AVAudioSession sharedInstance] setActive:YES error:&err];
}

#pragma mark - Settings Panel (robust, iOS 13+ safe)

// Globals for window creation retry
static UIWindow *g_settingsWindow = nil;
static BOOL g_windowCreated = NO;

/// Find an active foreground UIWindowScene (iOS 13+)
static id TTGFindActiveWindowScene(void) {
    if (@available(iOS 13.0, *)) {
        Class WSCls = NSClassFromString(@"UIWindowScene");
        if (!WSCls) return nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:WSCls] && scene.activationState == UISceneActivationStateForegroundActive) {
                return scene;
            }
        }
        // Fallback: any UIWindowScene
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:WSCls]) return scene;
        }
    }
    return nil;
}

/// Get a visible keyWindow the old way (pre-iOS 13 or scenes missing)
static UIWindow *TTGGetOldKeyWindow(void) {
    return [UIApplication sharedApplication].keyWindow;
}

@interface TTGSettingsButton : UIButton
@property (nonatomic, assign) BOOL dragging;
@end

@implementation TTGSettingsButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // BIG, bright, impossible-to-miss
        self.backgroundColor = [UIColor colorWithRed:1.0 green:0.2 blue:0.2 alpha:0.9]; // semi-transparent red
        self.layer.cornerRadius = frame.size.width / 2.0;
        self.layer.borderWidth = 2;
        self.layer.borderColor = [UIColor whiteColor].CGColor;
        self.titleLabel.font = [UIFont boldSystemFontOfSize:frame.size.width * 0.55];
        [self setTitle:@"G" forState:UIControlStateNormal];
        [self setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.accessibilityLabel = @"TikTok God";
        self.accessibilityHint = @"点击或长按打开 TikTok God 设置";

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
        lp.minimumPressDuration = 0.4;
        [self addGestureRecognizer:lp];
        [self addTarget:self action:@selector(tapped) forControlEvents:UIControlEventTouchUpInside];

        // Draggable — pan overwrites tap if moved far enough
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragging:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}

- (void)tapped {
    if (self.dragging) { self.dragging = NO; return; }
    [self showPanel];
}

- (void)longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) [self showPanel];
}

- (void)dragging:(UIPanGestureRecognizer *)g {
    UIView *parent = self.superview;
    if (!parent) return;
    CGPoint p = [g translationInView:parent];
    CGPoint c = self.center;
    CGPoint newCenter = CGPointMake(c.x + p.x, c.y + p.y);

    // Bound to parent
    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    newCenter.x = MAX(halfW + 4, MIN(parent.bounds.size.width - halfW - 4, newCenter.x));
    newCenter.y = MAX(halfH + 50, MIN(parent.bounds.size.height - halfH - 100, newCenter.y));

    self.center = newCenter;
    [g setTranslation:CGPointZero inView:parent];

    if (g.state == UIGestureRecognizerStateChanged && (fabs(p.x) > 3 || fabs(p.y) > 3)) {
        self.dragging = YES;
    }
    if (g.state == UIGestureRecognizerStateEnded) {
        // Snap to nearest horizontal edge
        CGFloat bx = self.center.x, screenW = parent.bounds.size.width;
        CGFloat snapX = bx < screenW / 2 ? halfW + 14 : screenW - halfW - 14;
        [UIView animateWithDuration:0.25 animations:^{
            self.center = CGPointMake(snapX, self.center.y);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.dragging = NO;
        });
    }
}

- (void)showPanel {
    UIViewController *vc = TTGTopViewController();
    if (!vc) {
        // Retry after short delay — topVC not ready yet
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showPanel];
        });
        return;
    }

    UIAlertController *panel = [UIAlertController alertControllerWithTitle:@"TikTok God"
                                                                   message:@"点击 ✅/⬜️ 切换开关"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    void (^addToggle)(NSString *, BOOL *, BOOL) = ^(NSString *title, BOOL *flag, BOOL restart) {
        NSString *prefix = *flag ? @"✅ " : @"⬜️ ";
        NSString *fullTitle = [[prefix stringByAppendingString:title] stringByAppendingString:restart ? @" (重启 TikTok)" : @""];
        UIAlertAction *a = [UIAlertAction actionWithTitle:fullTitle
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(UIAlertAction * _Nonnull action) {
            *flag = !*flag;
            TTGSavePrefs();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self showPanel]; // refresh
            });
        }];
        [panel addAction:a];
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

/// Create the floating settings window — called multiple times until scene is ready
static void TTGTryCreateSettingsWindow(int attempt) {
    if (g_windowCreated) return;
    if (attempt > 30) { // give up after ~7.5 seconds
        NSLog(@"[TTG] ⚠️ Gave up creating settings window after %d retries", attempt);
        return;
    }

    // Path A: iOS 13+ UIWindowScene (the correct way)
    if (@available(iOS 13.0, *)) {
        id scene = TTGFindActiveWindowScene();
        if (scene) {
            CGRect bounds = [(id)scene coordinateSpace].bounds;

            // Use objc_msgSend to avoid ARC retain warning on init performSelector
            UIWindow *(*initWithScene)(id, SEL, id) = (UIWindow *(*)(id, SEL, id))objc_msgSend;
            UIWindow *w = initWithScene([UIWindow alloc], @selector(initWithWindowScene:), scene);
            w.frame = bounds;
            w.windowLevel = UIWindowLevelNormal + 1;
            w.backgroundColor = [UIColor clearColor];
            w.opaque = NO;
            w.hidden = NO;

            TTGSettingsButton *btn = [[TTGSettingsButton alloc] initWithFrame:CGRectMake(14, 140, 40, 40)];
            [w addSubview:btn];
            [w makeKeyAndVisible];

            g_settingsWindow = w;
            g_windowCreated = YES;
            NSLog(@"[TTG] Created floating button on attempt %d (scene=%@)", attempt, scene);
            return;
        }
    }

    // Path B: pre-iOS 13 OR iOS 13+ but no scene yet — try hooking to existing keyWindow
    UIWindow *keyWin = TTGGetOldKeyWindow();
    if (keyWin && !g_windowCreated) {
        // Check if it's already got our button
        BOOL already = NO;
        for (UIView *v in keyWin.subviews) {
            if ([v isKindOfClass:[TTGSettingsButton class]]) { already = YES; break; }
        }
        if (!already) {
            TTGSettingsButton *btn = [[TTGSettingsButton alloc] initWithFrame:CGRectMake(14, 140, 40, 40)];
            [keyWin addSubview:btn];
            g_windowCreated = YES;
            NSLog(@"[TTG] Attached button to existing keyWindow on attempt %d", attempt);
            return;
        }
    }

    // Path C: still no scene/keyWindow — retry with delay
    NSTimeInterval delay = 0.25; // 250ms per attempt
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TTGTryCreateSettingsWindow(attempt + 1);
    });
}

#pragma mark - Hooks

%group SecurityBypass
%hook NSFileManager
- (BOOL)fileExistsAtPath:(NSString *)p {
    if (enableBypass) {
        static NSArray *bypassPaths = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            bypassPaths = @[
                @"/Applications/Cydia.app", @"/Applications/blackra1n.app", @"/Applications/Sileo.app",
                @"/usr/libexec/cydia/firmware.sh", @"/usr/bin/ssh",
                @"/Library/MobileSubstrate", @"/Library/TweakInject",
                @"/.cydia_no_stash", @"/.installed_unc0ver",
                @"/private/var/lib/cydia", @"/var/lib/cydia",
                @"/usr/lib/libjailbreak.dylib", @"/jb",
                @"/etc/apt", @"/var/log/apt", @"/Library/Application Support/Substrate"
            ];
        });
        if ([bypassPaths containsObject:p]) return NO;
    }
    return %orig;
}
- (BOOL)fileExistsAtPath:(NSString *)p isDirectory:(BOOL *)d {
    if (enableBypass) {
        static NSArray *bypassPaths = nil;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            bypassPaths = @[
                @"/Applications/Cydia.app", @"/Applications/blackra1n.app", @"/Applications/Sileo.app",
                @"/usr/libexec/cydia/firmware.sh", @"/usr/bin/ssh",
                @"/Library/MobileSubstrate", @"/Library/TweakInject",
                @"/.cydia_no_stash", @"/.installed_unc0ver",
                @"/private/var/lib/cydia", @"/var/lib/cydia",
                @"/usr/lib/libjailbreak.dylib", @"/jb",
                @"/etc/apt", @"/var/log/apt", @"/Library/Application Support/Substrate"
            ];
        });
        if ([bypassPaths containsObject:p]) return NO;
    }
    return %orig;
}
%end

// Hook common jailbreak helper classes — logos internal generator skips unknown classes gracefully
%hook BDADeviceHelper
+(BOOL)isJailBroken { return enableBypass ? NO : %orig; }
%end
%hook TTInstallUtil
+(BOOL)isJailBroken { return enableBypass ? NO : %orig; }
%end
%hook IESLiveDeviceInfo
+(BOOL)isJailBroken { return enableBypass ? NO : %orig; }
%end
%hook AppsFlyerUtils
+(BOOL)isJailBroken { return enableBypass ? NO : %orig; }
%end
%hook BDInstallNetworkUtility
+(BOOL)isJailBroken { return enableBypass ? NO : %orig; }
%end
%hook TTAdSplashDeviceHelper
+(BOOL)isJailBroken { return enableBypass ? NO : %orig; }
%end

%hook GULAppEnvironmentUtil
+(BOOL)isFromAppStore { return enableBypass ? YES : %orig; }
+(BOOL)isAppStoreReceiptSandbox { return enableBypass ? NO : %orig; }
%end

%hook FBSDKAppEventsUtility
+(BOOL)isDebugBuild { return enableBypass ? NO : %orig; }
%end

%hook AWEAPMManager
+(NSString *)signInfo { return enableBypass ? @"AppStore" : %orig; }
%end

%hook NSBundle
- (NSString *)pathForResource:(NSString *)name ofType:(NSString *)ext {
    if (enableBypass && [ext isEqualToString:@"mobileprovision"]) return nil;
    return %orig;
}
- (NSData *)dataForResource:(NSString *)name ofType:(NSString *)ext {
    if (enableBypass && [ext isEqualToString:@"mobileprovision"]) return nil;
    return %orig;
}
%end

%hook AWESecurity
- (void)resetCollectMode { if (!enableBypass) %orig; }
%end
%end // group SecurityBypass

%group CoreLogic

%hook AWEAwemeModel
- (id)initWithDictionary:(id)arg1 error:(id *)arg2 {
    id orig = %orig;
    if (noads && self.isAds) return nil;
    return orig;
}
- (id)init {
    id orig = %orig;
    if (noads && self.isAds) return nil;
    return orig;
}
- (BOOL)progressBarDraggable { return showProgressBar || %orig; }
- (BOOL)progressBarVisible { return showProgressBar || %orig; }
%end

%hook CTCarrier
- (NSString *)mobileCountryCode {
    return (changeRegion && region[@"mcc"] != nil) ? region[@"mcc"] : %orig;
}
- (NSString *)isoCountryCode {
    return (changeRegion && region[@"code"] != nil) ? region[@"code"] : %orig;
}
- (NSString *)mobileNetworkCode {
    return (changeRegion && region[@"mnc"] != nil) ? region[@"mnc"] : %orig;
}
%end

%hook AWEPlayVideoPlayerController
// Auto-advance + maintain audio session for background play
- (void)playerWillLoopPlaying:(id)arg1 {
    if (autoPlayNextVideo && [self.container.parentViewController isKindOfClass:%c(AWEFeedTableViewController)]) {
        [((AWEFeedTableViewController *)self.container.parentViewController) scrollToNextVideo];
        return;
    }
    %orig;
}
%end

// Background audio session — maintain playback when app goes to background
%hook UIApplication
- (void)applicationWillResignActive:(UIApplication *)app {
    if (enableBackgroundPlay) TTGEnableBackgroundPlay();
    %orig;
}
- (void)applicationDidEnterBackground:(UIApplication *)app {
    if (enableBackgroundPlay) TTGEnableBackgroundPlay();
    %orig;
}
%end

%hook AWEFeedContainerViewController
static AWEFeedContainerViewController *__weak __ttg_shared;
%property (nonatomic, assign) BOOL isUIHidden;

- (id)init {
    id orig = %orig;
    self.isUIHidden = NO;
    __ttg_shared = orig;
    return orig;
}

%new
+ (AWEFeedContainerViewController *)sharedInstance { return __ttg_shared; }
%end

%hook AWEPlayInteractionViewController
%property (nonatomic, retain) UIButton *hideUIButton;
%property (nonatomic, retain) UIButton *downloadButton;
%property (nonatomic, retain) UIButton *pipButton;

- (void)viewDidLoad {
    %orig;

    // Download button — cleaner watermark-free URL
    if (downloadWithoutWatermark) {
        self.downloadButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.downloadButton setImage:TTGIcon(icon_download, icon_download_len) forState:UIControlStateNormal];
        self.downloadButton.imageEdgeInsets = UIEdgeInsetsMake(3,3,3,3);
        self.downloadButton.frame = CGRectMake(self.view.bounds.size.width - 44, 135, 30, 30);
        [self.downloadButton addTarget:self action:@selector(__ttgDownload:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.downloadButton];
    }

    // Hide UI button
    if (canHideUI) {
        self.hideUIButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.hideUIButton setImage:TTGIcon(icon_hideui, icon_hideui_len) forState:UIControlStateNormal];
        self.hideUIButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.hideUIButton.imageEdgeInsets = UIEdgeInsetsMake(3,3,3,3);
        self.hideUIButton.frame = CGRectMake(self.view.bounds.size.width - 44, 100, 30, 30);
        [self.hideUIButton addTarget:self action:@selector(__ttgHideUI:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.hideUIButton];
    }

    // PiP button — show as a small circle
    if (enablePIP && NSClassFromString(@"AVPictureInPictureController")) {
        self.pipButton = [UIButton buttonWithType:UIButtonTypeCustom];
        self.pipButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.35];
        self.pipButton.layer.cornerRadius = 14;
        self.pipButton.titleLabel.font = [UIFont systemFontOfSize:14];
        [self.pipButton setTitle:@"⤢" forState:UIControlStateNormal];
        [self.pipButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.pipButton.frame = CGRectMake(self.view.bounds.size.width - 44, 170, 28, 28);
        [self.pipButton addTarget:self action:@selector(__ttgPIP:) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:self.pipButton];
    }
}

- (void)viewDidLayoutSubviews {
    %orig;
    CGFloat right = self.view.bounds.size.width - 44;
    if (self.downloadButton) self.downloadButton.frame = CGRectMake(right, 135, 30, 30);
    if (self.hideUIButton) self.hideUIButton.frame = CGRectMake(right, 100, 30, 30);
    if (self.pipButton) self.pipButton.frame = CGRectMake(right, 170, 28, 28);
}

- (void)stopLoadingAnimation {
    %orig;
    if (canHideUI) dispatch_async(dispatch_get_main_queue(), ^{ [self __ttgUpdateUI]; });
}

%new
- (void)__ttgHideUI:(UIButton *)sender {
    AWEFeedContainerViewController *afcVC = (AWEFeedContainerViewController *)[%c(AWEFeedContainerViewController) sharedInstance];
    afcVC.isUIHidden = !afcVC.isUIHidden;
    [self __ttgUpdateUI];
}

%new
- (void)__ttgDownload:(UIButton *)sender {
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
                    TTGShowAlert(ok ? @"Saved to Photos" : (err ?: @"Failed"), ok ? @"Done" : @"Error", TTGTopViewController());
                }];
            });
        };
        [dl downloadURLString:url];
    };

    if (@available(iOS 14.0, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus s) { startDownload(); }];
    } else {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus s) { startDownload(); }];
    }
}

%new
- (void)__ttgPIP:(UIButton *)sender {
    NSString *url = TTGGetVideoURL(self.model.video);
    TTGTogglePIP(url);
}

%new
- (void)__ttgUpdateUI {
    AWEFeedContainerViewController *afcVC = (AWEFeedContainerViewController *)[%c(AWEFeedContainerViewController) sharedInstance];
    [self setHide:afcVC.isUIHidden];
    [self.downloadButton setHidden:afcVC.isUIHidden];
    [self.hideUIButton setImage:afcVC.isUIHidden ? TTGIcon(icon_showui, icon_showui_len) : TTGIcon(icon_hideui, icon_hideui_len) forState:UIControlStateNormal];
    [self.pipButton setHidden:afcVC.isUIHidden];
    if ([self.parentViewController isKindOfClass:%c(AWEFeedCellViewController)]) {
        [afcVC setAccessoriesHidden:afcVC.isUIHidden];
    }
    afcVC.tabControl.hidden = afcVC.isUIHidden;
    afcVC.specialEventEntranceView.hidden = afcVC.isUIHidden;
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
%end // group CoreLogic

#pragma mark - Ctor + App Launch Hook

/// Hook UIApplication -applicationDidFinishLaunching: as 2nd guarantee window gets created
%group AppLifecycle
%hook UIApplication
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    %orig;
    NSLog(@"[TTG] applicationDidFinishLaunching fired — dylib definitely loaded!");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TTGTryCreateSettingsWindow(0);
    });
}
%end
%end // group AppLifecycle

%ctor {
    NSLog(@"[TTG] constructor fired — dylib loaded by dyld");

    // Observe pref changes so toggles take effect live
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    (CFNotificationCallback)reloadPrefs,
                                    CFSTR(PREF_CHANGED_NOTIF), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    reloadPrefs();

    // Maintain audio session for background play when enabled
    if (enableBackgroundPlay) TTGEnableBackgroundPlay();

    // Try creating immediately — scene may not exist yet, retry loop handles it
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"[TTG] Starting window creation retry loop...");
        TTGTryCreateSettingsWindow(0);
    });

    %init(SecurityBypass);
    %init(CoreLogic);
    %init(AppLifecycle);
    NSLog(@"[TTG] All hooks registered");
}
