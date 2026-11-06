#include <dlfcn.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Photos/Photos.h>
#import <objc/runtime.h>

#define PREF_CHANGED_NOTIF "com.haoict.tiktokgodpref/PrefChanged"

@interface AWEURLModel : NSObject
@property(retain, nonatomic) NSArray* originURLList;
@end

@interface AWEVideoModel : NSObject
@property(readonly, nonatomic) AWEURLModel* playURL;
@property(readonly, nonatomic) AWEURLModel* downloadURL;
@property(readonly, nonatomic) NSNumber *duration;
@end

@interface AWEAwemeModel : NSObject
@property(nonatomic) BOOL isAds;
@property(retain, nonatomic) AWEVideoModel* video;
@end

@interface AWEFeedCellViewController : UIViewController
@end

@interface AWEPlayVideoPlayerController : NSObject
@property(nonatomic) AWEFeedCellViewController *container;
- (void)setPlayerSeekTime:(double)arg1 completion:(id)arg2;
@end

@interface AWEAwemePlayVideoPlayerController : NSObject
@property(nonatomic) AWEFeedCellViewController *container;
- (void)setPlayerSeekTime:(double)arg1 completion:(id)arg2;
@end

@interface AWEFeedContainerViewController : UIViewController
@property(retain, nonatomic) UIView *tabControl;
@property(retain, nonatomic) UIView *specialEventEntranceView;
@property(nonatomic) BOOL isUIHidden;
- (void)setAccessoriesHidden:(BOOL)arg1;
+ (AWEFeedContainerViewController *)sharedInstance;
@end

@interface AWEPlayInteractionViewController : UIViewController
@property(retain, nonatomic) AWEAwemeModel *model;
@property(nonatomic, retain) UIButton *hideUIButton;
@property(nonatomic, retain) UIButton *downloadButton;
@property(nonatomic, retain) UIButton *pipButton;
- (void)setHide:(BOOL)arg1;
@end

@interface AWEPlayInteractionViewController (TTGInternal)
- (void)__ttgHideUI:(UIButton *)sender;
- (void)__ttgDownload:(UIButton *)sender;
- (void)__ttgPIP:(UIButton *)sender;
- (void)__ttgUpdateUI;
@end

@interface AWEMediaDownloadOptions : NSObject
@property(retain, nonatomic) AWEAwemeModel *awemeModel;
@end

@interface AWEDownloadShareChannel : NSObject
@property(retain, nonatomic) AWEMediaDownloadOptions *downloadOptions;
@end

@interface AWEFeedTableViewController : UIViewController
- (void)scrollToNextVideo;
@end
