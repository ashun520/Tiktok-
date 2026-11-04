/**
 * @author Hao Nguyen
 */

#include "Tweak.h"

BOOL noads;
BOOL downloadWithoutWatermark;
BOOL autoPlayNextVideo;
BOOL changeRegion;
BOOL showProgressBar;
BOOL canHideUI;
BOOL enableFavoritesCollections;
NSDictionary *region;

static void reloadPrefs() {
    NSDictionary *settings = [[NSMutableDictionary alloc] initWithContentsOfFile:@PLIST_PATH] ?: [@{} mutableCopy];

    noads = [[settings objectForKey:@"noads"] ?: @(YES) boolValue];
    downloadWithoutWatermark = [[settings objectForKey:@"downloadWithoutWatermark"] ?: @(YES) boolValue];
    autoPlayNextVideo = [[settings objectForKey:@"autoPlayNextVideo"] ?: @(NO) boolValue];
    changeRegion = [[settings objectForKey:@"changeRegion"] ?: @(NO) boolValue];
    region = [settings objectForKey:@"region"] ?: [@{} mutableCopy];
    showProgressBar = [[settings objectForKey:@"showProgressBar"] ?: @(NO) boolValue];
    enableFavoritesCollections = [[settings objectForKey:@"enableFavoritesCollections"] ?: @(NO) boolValue];
    canHideUI = [[settings objectForKey:@"canHideUI"] ?: @(YES) boolValue];
}

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
// https://github.com/chenxk-j/hookTikTok/blob/master/hooktiktok/hooktiktok.xm#L23
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
        [self.downloadButton.titleLabel setFont:[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold]];
        [self.downloadButton setTitle:@"去水印" forState:UIControlStateNormal];
        [self.downloadButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        self.downloadButton.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.62];
        self.downloadButton.layer.cornerRadius = 8.0;
        self.downloadButton.clipsToBounds = YES;
        [self.downloadButton addTarget:self action:@selector(downloadButtonPressed:) forControlEvents:UIControlEventTouchUpInside];

        // The icon is optional: the text label remains visible if the PNG is absent.
        UIImage *downloadIcon = [UIImage imageWithContentsOfFile:@"/Library/Application Support/tiktokgod/download.png"];
        if (downloadIcon != nil) {
            [self.downloadButton setImage:downloadIcon forState:UIControlStateNormal];
            self.downloadButton.imageView.contentMode = UIViewContentModeScaleAspectFit;
        }
        self.downloadButton.frame = CGRectMake(self.view.bounds.size.width - 88.0, 135.0, 78.0, 36.0);
        self.downloadButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
        [self.view addSubview:self.downloadButton];
        [self.view bringSubviewToFront:self.downloadButton];
    }

    if (canHideUI) {
        AWEFeedContainerViewController *afcVC = (AWEFeedContainerViewController *)[%c(AWEFeedContainerViewController) sharedInstance];
        self.hideUIButton = [UIButton buttonWithType:UIButtonTypeCustom];
        [self.hideUIButton.titleLabel setFont:[UIFont systemFontOfSize:15]];
        [self.hideUIButton addTarget:self action:@selector(hideUIButtonPressed:) forControlEvents:UIControlEventTouchUpInside];
        // [self.hideUIButton setTitle:afcVC.isUIHidden?@"Show UI":@"Hide UI" forState:UIControlStateNormal];
        [self.hideUIButton setImage:[UIImage imageWithContentsOfFile:afcVC.isUIHidden?@"/Library/Application Support/tiktokgod/showui.png":@"/Library/Application Support/tiktokgod/hideui.png"] forState:UIControlStateNormal];
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
    if (videoURLString.length == 0) {
        [HCommon showAlertMessage:@"当前视频暂时没有可用的下载地址" withTitle:@"无法下载" viewController:self];
        return;
    }
    if ([videoURLString containsString:@".m3u8"]) {
        [HCommon showAlertMessage:@"当前视频为 HLS (.m3u8) 格式，暂不支持此下载方式" withTitle:@"暂不支持" viewController:self];
        return;
    }
    [[[HDownloadMediaWithProgress alloc] init] checkPermissionToPhotosAndDownload:videoURLString appendExtension:@"mp4" mediaType:Video toAlbum:@"TikTok" viewController:self];
}

%new
- (void)updateShowOrHideUI {
    AWEFeedContainerViewController *afcVC = (AWEFeedContainerViewController *)[%c(AWEFeedContainerViewController) sharedInstance];
    [self setHide:afcVC.isUIHidden];
    [self.downloadButton setHidden:afcVC.isUIHidden];
    // [self.hideUIButton setTitle:afcVC.isUIHidden?@"Show UI":@"Hide UI" forState:UIControlStateNormal];
    [self.hideUIButton setImage:[UIImage imageWithContentsOfFile:afcVC.isUIHidden?@"/Library/Application Support/tiktokgod/showui.png":@"/Library/Application Support/tiktokgod/hideui.png"] forState:UIControlStateNormal];
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
