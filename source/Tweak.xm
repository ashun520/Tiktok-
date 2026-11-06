/**
 * TikTok God — LCSign injection port
 * Based on haoict/tiktok-god (MIT) — https://github.com/haoict/tiktok-god
 * Changes for non-jailbreak injection:
 *   - libhdev dependency replaced with native download/alert implementation
 *   - icons embedded into the dylib (no /Library/Application Support)
 *   - prefs read from app sandbox instead of /var/mobile
 */

#include "Tweak.h"
#include "icons.h"

BOOL noads;
BOOL downloadWithoutWatermark;
BOOL autoPlayNextVideo;
BOOL changeRegion;
BOOL showProgressBar;
BOOL canHideUI;
BOOL enableFavoritesCollections;
NSDictionary *region;

#pragma mark - Prefs

static NSString *TTGPrefsPath(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences/com.haoict.tiktokgodpref.plist"];
}

static void reloadPrefs(void) {
    NSDictionary *settings = [[NSMutableDictionary alloc] initWithContentsOfFile:TTGPrefsPath()] ?: [@{} mutableCopy];

    noads = [[settings objectForKey:@"noads"] ?: @(YES) boolValue];
    downloadWithoutWatermark = [[settings objectForKey:@"downloadWithoutWatermark"] ?: @(YES) boolValue];
    autoPlayNextVideo = [[settings objectForKey:@"autoPlayNextVideo"] ?: @(NO) boolValue];
    changeRegion = [[settings objectForKey:@"changeRegion"] ?: @(NO) boolValue];
    region = [settings objectForKey:@"region"] ?: [@{} mutableCopy];
    showProgressBar = [[settings objectForKey:@"showProgressBar"] ?: @(NO) boolValue];
    enableFavoritesCollections = [[settings objectForKey:@"enableFavoritesCollections"] ?: @(NO) boolValue];
    canHideUI = [[settings objectForKey:@"canHideUI"] ?: @(YES) boolValue];
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
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                if (@available(iOS 15.0, *)) {
                    rootVC = windowScene.keyWindow.rootViewController;
                } else {
                    rootVC = windowScene.windows.firstObject.rootViewController;
                }
                break;
            }
        }
    }
    if (!rootVC) rootVC = [UIApplication sharedApplication].keyWindow.rootViewController;
    while (rootVC.presentedViewController) rootVC = rootVC.presentedViewController;
    return rootVC;
}

static void TTGShowAlert(NSString *message, NSString *title, UIViewController *fromVC) {
    UIViewController *vc = fromVC ?: TTGTopViewController();
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:alert animated:YES completion:nil];
    });
}

#pragma mark - Native downloader (replaces libhdev HDownloadMediaWithProgress)

@interface TTGDownloader : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, copy) void (^onProgress)(double fraction);
@property (nonatomic, copy) void (^onDone)(BOOL success, NSString *error);
- (void)downloadURLString:(NSString *)urlString;
@end

@implementation TTGDownloader

- (void)downloadURLString:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) {
        if (self.onDone) self.onDone(NO, @"Invalid URL");
        return;
    }
    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg delegate:self delegateQueue:nil];
    [[session downloadTaskWithURL:url] resume];
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
           didWriteData:(int64_t)bytesWritten
      totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    if (totalBytesExpectedToWrite > 0 && self.onProgress) {
        double fraction = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
        dispatch_async(dispatch_get_main_queue(), ^{ self.onProgress(fraction); });
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)task
didFinishDownloadingToURL:(NSURL *)location {
    NSString *destPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"ttg_video.mp4"];
    NSURL *dest = [NSURL fileURLWithPath:destPath];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtURL:dest error:nil];
    NSError *moveErr = nil;
    [fm moveItemAtURL:location toURL:dest error:&moveErr];
    if (moveErr) {
        if (self.onDone) self.onDone(NO, moveErr.localizedDescription);
        return;
    }

    __block NSError *saveErr = nil;
    [[PHPhotoLibrary sharedPhotoLibrary] performChangesAndWait:^{
        [PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:dest];
    } error:&saveErr];

    [fm removeItemAtURL:dest error:nil];
    if (self.onDone) self.onDone(saveErr == nil, saveErr.localizedDescription ?: nil);
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error && self.onDone) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.onDone(NO, error.localizedDescription); });
    }
}

@end

#pragma mark - Hooks

%group CoreLogic
%hook AWEAwemeModel
- (id)initWithDictionary:(id)arg1 error:(id *)arg2 {
    id orig = %orig;
    return noads && self.isAds ? nil : orig;
}

- (id)init {
    id orig = %orig;
    return noads && self.isAds ? nil : orig;
}

- (BOOL)progressBarDraggable {
    return showProgressBar || %orig;
}
- (BOOL)progressBarVisible {
    return showProgressBar || %orig;
}
%end

%hook CTCarrier
// Thanks chenxk-j for this
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
- (void)playerWillLoopPlaying:(id)arg1 {
    if (autoPlayNextVideo) {
        if ([self.container.parentViewController isKindOfClass:%c(AWEFeedTableViewController)]) {
            [((AWEFeedTableViewController *)self.container.parentViewController) scrollToNextVideo];
            return;
        }
    }
    %orig;
}
%end

%hook AWEFeedContainerViewController
static AWEFeedContainerViewController *__weak sharedInstance;
%property (nonatomic, assign) BOOL isUIHidden;

- (id)init {
    id orig = %orig;
    self.isUIHidden = NO;
    sharedInstance = orig;
    return orig;
}

%new
+ (AWEFeedContainerViewController *)sharedInstance {
    return sharedInstance;
}
%end

%hook AWEPlayInteractionViewController
%property (nonatomic, retain) UIButton *hideUIButton;
%property (nonatomic, retain) UIButton *downloadButton;

- (void)viewDidLoad {
    %orig;

    if (downloadWithoutWatermark) {
        self.downloadButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.downloadButton.titleLabel setFont:[UIFont systemFontOfSize:15]];
        [self.downloadButton addTarget:self action:@selector(downloadButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
        [self.downloadButton setImage:TTGIcon(icon_download, icon_download_len) forState:UIControlStateNormal];
        self.downloadButton.imageEdgeInsets = UIEdgeInsetsMake(3.0, 3.0, 3.0, 3.0);
        self.downloadButton.frame = CGRectMake(self.view.frame.size.width - 30 - 10, 135.0, 30.0, 30.0);
        [self.view addSubview:self.downloadButton];
    }

    if (canHideUI) {
        AWEFeedContainerViewController *afcVC = (AWEFeedContainerViewController *)[%c(AWEFeedContainerViewController) sharedInstance];
        self.hideUIButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.hideUIButton.titleLabel setFont:[UIFont systemFontOfSize:15]];
        [self.hideUIButton addTarget:self action:@selector(hideUIButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
        [self.hideUIButton setImage:afcVC.isUIHidden ? TTGIcon(icon_showui, icon_showui_len) : TTGIcon(icon_hideui, icon_hideui_len) forState:UIControlStateNormal];
        self.hideUIButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        self.hideUIButton.imageEdgeInsets = UIEdgeInsetsMake(3.0, 3.0, 3.0, 3.0);
        self.hideUIButton.frame = CGRectMake(self.view.frame.size.width - 30 - 10, 100.0, 30.0, 30.0);
        [self.view addSubview:self.hideUIButton];
    }
}

- (void)stopLoadingAnimation {
    %orig;
    if (canHideUI) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self updateShowOrHideUI];
        });
    }
}

%new
- (void)hideUIButtonPressed:(UIButton *)sender {
    AWEFeedContainerViewController *afcVC = (AWEFeedContainerViewController *)[%c(AWEFeedContainerViewController) sharedInstance];
    afcVC.isUIHidden = !afcVC.isUIHidden;
    [self updateShowOrHideUI];
}

%new
- (void)downloadButtonPressed:(UIButton *)sender {
    NSString *videoURLString = self.model.video.playURL.originURLList.firstObject;
    if (!videoURLString.length) {
        TTGShowAlert(@"No video URL found", @"Error", self);
        return;
    }
    if ([videoURLString containsString:@".m3u8"]) {
        TTGShowAlert(@"This video format is not supported (.m3u8 file extension)", @"Not supported", self);
        return;
    }

    // request add-only photo permission, then download with progress
    void (^startDownload)(void) = ^{
        UIAlertController *progressAlert = [UIAlertController alertControllerWithTitle:@"Downloading" message:@"0%" preferredStyle:UIAlertControllerStyleAlert];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentViewController:progressAlert animated:YES completion:nil];
        });

        TTGDownloader *downloader = [TTGDownloader new];
        downloader.onProgress = ^(double fraction) {
            progressAlert.message = [NSString stringWithFormat:@"%.0f%%", fraction * 100.0];
        };
        downloader.onDone = ^(BOOL success, NSString *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [progressAlert dismissViewControllerAnimated:NO completion:^{
                    UIViewController *top = TTGTopViewController();
                    TTGShowAlert(success ? @"Saved to Photos album \"TikTok\"" : [NSString stringWithFormat:@"%@", error ?: @"Unknown error"], success ? @"Done" : @"Failed", top);
                }];
            });
        };
        [downloader downloadURLString:videoURLString];
    };

    if (@available(iOS 14.0, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
            startDownload();
        }];
    } else {
        [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
            startDownload();
        }];
    }
}

%new
- (void)updateShowOrHideUI {
    AWEFeedContainerViewController *afcVC = (AWEFeedContainerViewController *)[%c(AWEFeedContainerViewController) sharedInstance];
    [self setHide:afcVC.isUIHidden];
    [self.downloadButton setHidden:afcVC.isUIHidden];
    [self.hideUIButton setImage:afcVC.isUIHidden ? TTGIcon(icon_showui, icon_showui_len) : TTGIcon(icon_hideui, icon_hideui_len) forState:UIControlStateNormal];
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
        return [%c(TTKFavoriteAwemeCollectionsViewController) new];
    } else {
        return %orig;
    }
}
%end
%end

%ctor {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, (CFNotificationCallback) reloadPrefs, CFSTR(PREF_CHANGED_NOTIF), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    reloadPrefs();

    %init(CoreLogic);
}
