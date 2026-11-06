#import <UIKit/UIKit.h>
#import <AVKit/AVKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Photos/Photos.h>
#import <objc/message.h>
#import <objc/runtime.h>

#pragma mark - 前向声明

static void TTGDownloadAndSave(void);
static void TTGDownloadImage(void);
static void TTGCopyShareLink(void);
static void TTGDownloadMusic(void);
static void TTGDownloadLivePhoto(void);

@class TTGSettingsViewController;

static void TTGInstallGesturesOnWindow(UIWindow *win);

// 递归禁用整个 view 树里除了保留的 window 上的手势之外的所有 UILongPressGestureRecognizer
// Kill 子视图长按手势，但跳过评论/搜索/输入区域
static BOOL TTGIsProtectedView(UIView *v) {
    UIView *check = v;
    while (check) {
        NSString *cls = NSStringFromClass([check class]);
        if ([cls rangeOfString:@"Comment" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([cls rangeOfString:@"Search" options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
        if ([check isKindOfClass:[UITextField class]] || [check isKindOfClass:[UITextView class]]) return YES;
        if ([check isKindOfClass:[UIButton class]]) return YES;
        check = check.superview;
    }
    return NO;
}

static void TTGKillAllLongPressInViewExcept(UIView *v, UIGestureRecognizer *except) {
    if (TTGIsProtectedView(v)) return;  // 跳过评论/搜索区，保留 TikTok 的长按（翻译/复制菜单）
    for (UIGestureRecognizer *gr in v.gestureRecognizers) {
        if (gr == except) continue;
        if (![gr isKindOfClass:[UILongPressGestureRecognizer class]]) continue;
        if (gr.view && [gr.view isKindOfClass:[UIWindow class]]) continue;
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
@interface TTGSinglePressRecognizer : UILongPressGestureRecognizer <UIGestureRecognizerDelegate> {
    dispatch_block_t _ttg_timer_block;
    CGPoint _ttg_startPoint;
    BOOL _ttg_fired;
}
@end

@implementation TTGSinglePressRecognizer

#define TTG_SINGLE_DELAY      0.40
#define TTG_SINGLE_MOVE_LIMIT 25.0

// 关键：不依赖容器类型过滤（TikTok 视频 feed 可能在 UICollectionView 里）
// 改用类名关键词识别评论/搜索/输入区域
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldReceiveTouch:(UITouch *)touch {
    UIView *hitView = touch.view;
    UIView *v = hitView;
    while (v) {
        NSString *clsName = NSStringFromClass([v class]);
        // 评论区
        if ([clsName rangeOfString:@"Comment" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSLog(@"[TTG] 👆 忽略 — 触摸在评论区(%@)", clsName);
            return NO;
        }
        // 搜索区域
        if ([clsName rangeOfString:@"Search" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            NSLog(@"[TTG] 👆 忽略 — 触摸在搜索区(%@)", clsName);
            return NO;
        }
        if ([v isKindOfClass:[UIButton class]]) {
            NSLog(@"[TTG] 👆 忽略 — 触摸在 UIButton");
            return NO;
        }
        if ([v isKindOfClass:[UITextField class]] || [v isKindOfClass:[UITextView class]]) {
            NSLog(@"[TTG] 👆 忽略 — 触摸在文本框");
            return NO;
        }
        if ([v isKindOfClass:[UINavigationBar class]] || [v isKindOfClass:[UITabBar class]]) {
            NSLog(@"[TTG] 👆 忽略 — 触摸在导航/标签栏");
            return NO;
        }
        v = v.superview;
    }
    // 只要有任何 present 的 VC 覆盖 → 都不触发长按
    // 包括评论 sheet、搜索页、我们的设置面板、我们的详情页
    UIViewController *rootVC = self.view.window.rootViewController;
    if (rootVC.presentedViewController) {
        NSLog(@"[TTG] 👆 忽略 — 有 present VC 覆盖: %@", NSStringFromClass([rootVC.presentedViewController class]));
        return NO;
    }
    return YES;
}

// 关键：我们不跟任何人竞争！不 cancel TikTok 内部的长按手势（翻译/复制菜单）
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

// 关键：不让别人 require 我们 Fail —— 我们的 0.4s timer 必须正常跑完
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
}

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
static BOOL showProgressBar = YES;
static BOOL canHideUI = YES;
static BOOL enablePIP = YES;
static BOOL enableBackgroundPlay = YES;
static BOOL enableBypass = YES;
static BOOL tabBarTransparent = NO;   // 底栏透明总开关
static CGFloat tabBarAlpha = 0.15;   // 底栏透明度（0=全透明，1=不透明）
static BOOL tabBarFloating = NO;     // 悬浮底栏（圆角浮在底部）
static BOOL hideTopBarItems = NO;     // 隐藏顶栏总开关
// 顶栏元素：用户勾选要隐藏的
static BOOL hide_Tab_Recommended = NO;  // 推荐/For You
static BOOL hide_Tab_Following = NO;    // 关注/Following
static BOOL hide_Tab_Friends = NO;      // 好友/Friends
static BOOL hide_Tab_Live = NO;         // LIVE
static BOOL hide_Tab_Plus = YES;        // 中间 + 号（默认隐藏，省空间）
static BOOL hide_Tab_Avatar = YES;      // 头像（默认隐藏）
static BOOL hide_Tab_Search = NO;       // 🔍 搜索

#pragma mark - 地区切换（国家码 → mcc/mnc/iso/language/emoji）

static NSString *ttgSelectedRegion = @"US"; // 默认美国

static NSDictionary *TTGCountryList(void) {
    static NSDictionary *dict = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dict = @{
            @"US":  @{@"name": @"🇺🇸 美国",   @"mcc": @"310", @"mnc": @"001", @"iso": @"us", @"lang": @"en"},
            @"CA":  @{@"name": @"🇨🇦 加拿大", @"mcc": @"302", @"mnc": @"001", @"iso": @"ca", @"lang": @"en"},
            @"GB":  @{@"name": @"🇬🇧 英国",   @"mcc": @"234", @"mnc": @"02",  @"iso": @"gb", @"lang": @"en"},
            @"AU":  @{@"name": @"🇦🇺 澳大利亚", @"mcc": @"505", @"mnc": @"01", @"iso": @"au", @"lang": @"en"},
            @"JP":  @{@"name": @"🇯🇵 日本",   @"mcc": @"440", @"mnc": @"01",  @"iso": @"jp", @"lang": @"ja"},
            @"KR":  @{@"name": @"🇰🇷 韩国",   @"mcc": @"450", @"mnc": @"00",  @"iso": @"kr", @"lang": @"ko"},
            @"CN":  @{@"name": @"🇨🇳 中国大陆", @"mcc": @"460", @"mnc": @"00", @"iso": @"cn", @"lang": @"zh-Hans"},
            @"HK":  @{@"name": @"🇭🇰 香港",   @"mcc": @"454", @"mnc": @"00",  @"iso": @"hk", @"lang": @"zh-Hant"},
            @"TW":  @{@"name": @"🇹🇼 台湾",   @"mcc": @"466", @"mnc": @"01",  @"iso": @"tw", @"lang": @"zh-Hant"},
            @"SG":  @{@"name": @"🇸🇬 新加坡", @"mcc": @"525", @"mnc": @"01",  @"iso": @"sg", @"lang": @"en"},
            @"MY":  @{@"name": @"🇲🇾 马来西亚", @"mcc": @"502", @"mnc": @"01", @"iso": @"my", @"lang": @"en"},
            @"TH":  @{@"name": @"🇹🇭 泰国",   @"mcc": @"520", @"mnc": @"00",  @"iso": @"th", @"lang": @"th"},
            @"VN":  @{@"name": @"🇻🇳 越南",   @"mcc": @"452", @"mnc": @"00",  @"iso": @"vn", @"lang": @"vi"},
            @"ID":  @{@"name": @"🇮🇩 印尼",   @"mcc": @"510", @"mnc": @"01",  @"iso": @"id", @"lang": @"id"},
            @"PH":  @{@"name": @"🇵🇭 菲律宾", @"mcc": @"515", @"mnc": @"01",  @"iso": @"ph", @"lang": @"en"},
            @"IN":  @{@"name": @"🇮🇳 印度",   @"mcc": @"404", @"mnc": @"01",  @"iso": @"in", @"lang": @"en"},
            @"FR":  @{@"name": @"🇫🇷 法国",   @"mcc": @"208", @"mnc": @"01",  @"iso": @"fr", @"lang": @"fr"},
            @"DE":  @{@"name": @"🇩🇪 德国",   @"mcc": @"262", @"mnc": @"01",  @"iso": @"de", @"lang": @"de"},
            @"ES":  @{@"name": @"🇪🇸 西班牙", @"mcc": @"214", @"mnc": @"01",  @"iso": @"es", @"lang": @"es"},
            @"IT":  @{@"name": @"🇮🇹 意大利", @"mcc": @"222", @"mnc": @"01",  @"iso": @"it", @"lang": @"it"},
            @"NL":  @{@"name": @"🇳🇱 荷兰",   @"mcc": @"204", @"mnc": @"01",  @"iso": @"nl", @"lang": @"nl"},
            @"RU":  @{@"name": @"🇷🇺 俄罗斯", @"mcc": @"250", @"mnc": @"01",  @"iso": @"ru", @"lang": @"ru"},
            @"BR":  @{@"name": @"🇧🇷 巴西",   @"mcc": @"724", @"mnc": @"01",  @"iso": @"br", @"lang": @"pt"},
            @"MX":  @{@"name": @"🇲🇽 墨西哥", @"mcc": @"334", @"mnc": @"01",  @"iso": @"mx", @"lang": @"es"},
            @"ZA":  @{@"name": @"🇿🇦 南非",   @"mcc": @"655", @"mnc": @"01",  @"iso": @"za", @"lang": @"en"},
            @"EG":  @{@"name": @"🇪🇬 埃及",   @"mcc": @"602", @"mnc": @"01",  @"iso": @"eg", @"lang": @"ar"},
            @"SA":  @{@"name": @"🇸🇦 沙特",   @"mcc": @"420", @"mnc": @"01",  @"iso": @"sa", @"lang": @"ar"},
            @"AE":  @{@"name": @"🇦🇪 阿联酋", @"mcc": @"424", @"mnc": @"02",  @"iso": @"ae", @"lang": @"ar"},
            @"UA":  @{@"name": @"🇺🇦 乌克兰", @"mcc": @"255", @"mnc": @"01",  @"iso": @"ua", @"lang": @"uk"},
            @"SE":  @{@"name": @"🇸🇪 瑞典",   @"mcc": @"240", @"mnc": @"01",  @"iso": @"se", @"lang": @"sv"},
            @"NO":  @{@"name": @"🇳🇴 挪威",   @"mcc": @"242", @"mnc": @"01",  @"iso": @"no", @"lang": @"no"},
            @"FI":  @{@"name": @"🇫🇮 芬兰",   @"mcc": @"244", @"mnc": @"01",  @"iso": @"fi", @"lang": @"fi"},
            @"DK":  @{@"name": @"🇩🇰 丹麦",   @"mcc": @"238", @"mnc": @"01",  @"iso": @"dk", @"lang": @"da"},
            @"PL":  @{@"name": @"🇵🇱 波兰",   @"mcc": @"260", @"mnc": @"01",  @"iso": @"pl", @"lang": @"pl"},
            @"TR":  @{@"name": @"🇹🇷 土耳其", @"mcc": @"286", @"mnc": @"01",  @"iso": @"tr", @"lang": @"tr"},
        };
    });
    return dict;
}

static NSDictionary *TTGRegionInfo(NSString *code) {
    return TTGCountryList()[code] ?: TTGCountryList()[@"US"];
}

// 获取当前选中地区的显示名（带 emoji）
static NSString *TTGRegionDisplayName(void) {
    return TTGRegionInfo(ttgSelectedRegion)[@"name"] ?: @"🇺🇸 美国";
}

// 应用地区切换（保存到 UserDefaults + 重新 hook CTCarrier + NSLocale）
static void TTGApplyRegionChange(void) {
    NSDictionary *info = TTGRegionInfo(ttgSelectedRegion);
    NSString *iso = info[@"iso"];
    NSString *mcc = info[@"mcc"];
    NSString *mnc = info[@"mnc"];
    NSString *lang = info[@"lang"];

    NSLog(@"[TTG] 🌍 切换地区: %@ → iso=%@ mcc=%@ mnc=%@ lang=%@", ttgSelectedRegion, iso, mcc, mnc, lang);

    // 1. 保存到 UserDefaults（下次启动恢复）
    [[NSUserDefaults standardUserDefaults] setObject:ttgSelectedRegion forKey:@"ttg_selected_region"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // 2. hook CTCarrier（运营商信息）
    Class CTCarrier = NSClassFromString(@"CTCarrier");
    if (CTCarrier) {
        class_replaceMethod(CTCarrier, @selector(mcc), imp_implementationWithBlock(^id(id s){ return mcc; }), "@@:");
        class_replaceMethod(CTCarrier, @selector(mnc), imp_implementationWithBlock(^id(id s){ return mnc; }), "@@:");
        class_replaceMethod(CTCarrier, @selector(isoCountryCode), imp_implementationWithBlock(^id(id s){ return iso; }), "@@:");
        NSLog(@"[TTG] ✅ CTCarrier 已 hook → mcc=%@ mnc=%@ iso=%@", mcc, mnc, iso);
    }

    // 3. 写入 AppleLanguages（影响系统语言偏好，TikTok 会读这个）
    NSArray *languages = @[lang, @"en"]; // 首选目标语言，英文兜底
    [[NSUserDefaults standardUserDefaults] setObject:languages forKey:@"AppleLanguages"];

    // 4. 刷新当前 app 语言环境（不重启）
    [[NSUserDefaults standardUserDefaults] setObject:@{
        @"AppleLanguages": languages,
        @"AppleLocale": [NSString stringWithFormat:@"%@_%@", lang, iso.uppercaseString]
    } forKey:@"NSGlobalDomain"];

    NSLog(@"[TTG] ✅ 地区切换完成");
}

#pragma mark - 底栏透明

static UIWindow *TTGFrontmostWindow(void);
static void TTGApplyTabBarTransparentToView(UIView *v);
static void TTGScanTopBarItems(UIView *v);

static void TTGApplyTabBarTransparent(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = TTGFrontmostWindow();
        if (!win) return;
        for (UIView *v in win.subviews) {
            TTGApplyTabBarTransparentToView(v);
        }
        NSLog(@"[TTG] 🎛️ 底栏透明 %@", tabBarTransparent ? @"开启" : @"关闭");
    });
}

static void TTGApplyTabBarTransparentToView(UIView *v) {
    // UITabBar（系统类）
    if ([v isKindOfClass:[UITabBar class]]) {
        UITabBar *tabBar = (UITabBar *)v;
        if (tabBarTransparent) {
            tabBar.backgroundColor = [UIColor clearColor];
            tabBar.alpha = tabBarAlpha; // 用户可调
            tabBar.layer.borderWidth = 0;
            tabBar.layer.shadowOpacity = 0;
            if (@available(iOS 13.0, *)) {
                UITabBarAppearance *app = [[UITabBarAppearance alloc] init];
                [app configureWithTransparentBackground];
                app.backgroundColor = [UIColor clearColor];
                app.shadowColor = [UIColor clearColor];
                [tabBar setStandardAppearance:app];
                if (@available(iOS 15.0, *)) { [tabBar setScrollEdgeAppearance:app]; }
            }
            // 悬浮模式：缩窄 + 圆角 + 上移
            if (tabBarFloating) {
                CGRect f = tabBar.frame;
                CGFloat margin = 20;
                f.origin.x += margin;
                f.size.width -= margin * 2;
                f.origin.y -= 8; // 稍微上浮
                tabBar.frame = f;
                tabBar.layer.cornerRadius = 20;
                tabBar.layer.masksToBounds = YES;
                tabBar.layer.shadowColor = [UIColor blackColor].CGColor;
                tabBar.layer.shadowOpacity = 0.3;
                tabBar.layer.shadowOffset = CGSizeMake(0, 4);
                tabBar.layer.shadowRadius = 10;
                tabBar.layer.masksToBounds = NO;
                // 用一个模糊背景
                UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleLight];
                UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:blur];
                blurView.frame = tabBar.bounds;
                blurView.layer.cornerRadius = 20;
                blurView.layer.masksToBounds = YES;
                blurView.tag = 99999;
                [tabBar insertSubview:blurView atIndex:0];
            }
        } else {
            tabBar.alpha = 1.0;
            // 还原 frame
            if (tabBarFloating) {
                CGRect f = tabBar.frame;
                f.origin.x = 0;
                f.size.width = tabBar.superview.bounds.size.width;
                f.origin.y += 8;
                tabBar.frame = f;
                tabBar.layer.cornerRadius = 0;
                tabBar.layer.shadowOpacity = 0;
                UIView *old = [tabBar viewWithTag:99999];
                if (old) [old removeFromSuperview];
            }
        }
    }
    // TikTok 自定义底栏：包含 tabbar/bottombar/homebar/TTBar 的
    NSString *clsName = NSStringFromClass([v class]);
    if (tabBarTransparent && (
        [clsName caseInsensitiveCompare:@"TTTabBar"] == NSOrderedSame ||
        [clsName rangeOfString:@"tabbar" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [clsName rangeOfString:@"bottombar" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [clsName rangeOfString:@"homebar" options:NSCaseInsensitiveSearch].location != NSNotFound
    )) {
        v.alpha = tabBarAlpha;
    }
    for (UIView *sub in v.subviews) {
        TTGApplyTabBarTransparentToView(sub);
    }
}

#pragma mark - 隐藏顶栏元素

// 递归找并隐藏顶栏上的小花按钮、"+" 号按钮等干扰元素
static void TTGApplyHideTopBar(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *win = TTGFrontmostWindow();
        if (!win) return;
        for (UIView *v in win.subviews) {
            TTGScanTopBarItems(v);
        }
        NSLog(@"[TTG] 🔝 隐藏顶栏元素 %@", hideTopBarItems ? @"开启" : @"关闭");
    });
}

static void TTGScanTopBarItems(UIView *v) {
    NSString *clsName = NSStringFromClass([v class]);
    NSString *viewID = v.accessibilityIdentifier ?: @"";
    NSString *label = v.accessibilityLabel ?: @"";
    NSString *text = ([v respondsToSelector:@selector(text)] && [(id)v text]) ? [(id)v text] : @"";

    // + 号/小花按钮（中间的创建按钮）
    BOOL isPlus =
        hide_Tab_Plus && (
        [clsName rangeOfString:@"addbutton" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [clsName rangeOfString:@"createbutton" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [clsName rangeOfString:@"plusbutton" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [clsName rangeOfString:@"flower" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [clsName rangeOfString:@"doodle" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [viewID rangeOfString:@"add" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [viewID rangeOfString:@"create" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [viewID rangeOfString:@"plus" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [viewID rangeOfString:@"flower" options:NSCaseInsensitiveSearch].location != NSNotFound);

    // 头像按钮
    BOOL isAvatar =
        hide_Tab_Avatar && (
        [clsName rangeOfString:@"avatarbutton" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [clsName rangeOfString:@"avatarcontainer" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [clsName rangeOfString:@"profilebutton" options:NSCaseInsensitiveSearch].location != NSNotFound);

    // 搜索按钮 🔍
    BOOL isSearch =
        hide_Tab_Search && (
        [clsName rangeOfString:@"searchbutton" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [clsName rangeOfString:@"searchicon" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [viewID rangeOfString:@"search" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [label rangeOfString:@"search" options:NSCaseInsensitiveSearch].location != NSNotFound);

    // Tab 文字匹配（For You/Recommended/Following/Friends/Live/社区/东京都）
    BOOL isTab = NO;
    if (hideTopBarItems) {
        if (hide_Tab_Recommended && (
            [text caseInsensitiveCompare:@"For You"] == NSOrderedSame ||
            [text caseInsensitiveCompare:@"Recommended"] == NSOrderedSame ||
            [text isEqualToString:@"推荐"] ||
            [text isEqualToString:@"推荐"])) isTab = YES;
        if (hide_Tab_Following && (
            [text caseInsensitiveCompare:@"Following"] == NSOrderedSame ||
            [text isEqualToString:@"关注"])) isTab = YES;
        if (hide_Tab_Friends && (
            [text caseInsensitiveCompare:@"Friends"] == NSOrderedSame ||
            [text isEqualToString:@"好友"])) isTab = YES;
        if (hide_Tab_Live && (
            [text caseInsensitiveCompare:@"LIVE"] == NSOrderedSame ||
            [text caseInsensitiveCompare:@"Live"] == NSOrderedSame ||
            [text caseInsensitiveCompare:@"live"] == NSOrderedSame ||
            [text isEqualToString:@"直播"])) isTab = YES;
    }

    if ((isPlus || isAvatar || isSearch || isTab) && hideTopBarItems) {
        v.hidden = YES;
    } else if (!hideTopBarItems) {
        v.hidden = NO; // 总开关关掉 → 全部恢复
    }

    for (UIView *sub in v.subviews) {
        TTGScanTopBarItems(sub);
    }
}

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

// 全局标志：我们自己的面板打开期间 → 定时器不能把手势装回去
static BOOL _ttg_gesturesSuspended = NO;
// 暂存被移除的手势（present 面板时 remove，dismiss 时加回去）
static NSMutableArray *_ttg_saved_gestures = nil;
static NSMutableArray *_ttg_saved_gesture_windows = nil;

// present 面板前 → 把手势从 window 上彻底 removeFromSuperview（不是只设 enabled=NO）
// dismiss 面板后 → 再加回 window
// 彻底绕开 iOS 手势系统对 window 触摸路由的干扰
static void TTGSetWindowLongPressEnabled(BOOL enabled) {
    _ttg_gesturesSuspended = !enabled;

    if (!enabled) {
        // ====== DISABLE: 从所有 window 上彻底移除我们的长按手势 ======
        NSLog(@"[TTG] ✋✋✋ TTGSetWindowLongPressEnabled(NO) → 彻底 removeFromSuperview 所有长按手势");
        if (!_ttg_saved_gestures) _ttg_saved_gestures = [NSMutableArray array];
        if (!_ttg_saved_gesture_windows) _ttg_saved_gesture_windows = [NSMutableArray array];
        [_ttg_saved_gestures removeAllObjects];
        [_ttg_saved_gesture_windows removeAllObjects];

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
            // copy gestures 数组避免遍历中修改
            NSArray *grs = [win.gestureRecognizers copy];
            for (UIGestureRecognizer *gr in grs) {
                BOOL isOurSingle = [gr isKindOfClass:NSClassFromString(@"TTGSinglePressRecognizer")];
                BOOL isOurDouble = [gr isKindOfClass:[UILongPressGestureRecognizer class]] &&
                                   ![gr isKindOfClass:NSClassFromString(@"TTGSinglePressRecognizer")] &&
                                   ((UILongPressGestureRecognizer *)gr).numberOfTouchesRequired == 2;
                if (isOurSingle || isOurDouble) {
                    NSLog(@"[TTG] ✋ removeFromSuperview %@ (window=%@)", NSStringFromClass([gr class]), win);
                    [_ttg_saved_gestures addObject:gr];
                    [_ttg_saved_gesture_windows addObject:win];
                    [win removeGestureRecognizer:gr];
                }
            }
        }
        NSLog(@"[TTG] ✋ 已移除 %lu 个手势，suspended=%d", (unsigned long)_ttg_saved_gestures.count, _ttg_gesturesSuspended);
    } else {
        // ====== ENABLE: 把暂存的手势加回 window ======
        NSLog(@"[TTG] ✋✋✋ TTGSetWindowLongPressEnabled(YES) → 把手势加回 window");
        if (_ttg_saved_gestures && _ttg_saved_gestures.count > 0) {
            for (int i = 0; i < (int)_ttg_saved_gestures.count; i++) {
                UIGestureRecognizer *gr = _ttg_saved_gestures[i];
                UIWindow *win = _ttg_saved_gesture_windows[i];
                if (win && gr) {
                    NSLog(@"[TTG] ✋ addGestureRecognizer %@ → window", NSStringFromClass([gr class]));
                    [win addGestureRecognizer:gr];
                }
            }
            [_ttg_saved_gestures removeAllObjects];
            [_ttg_saved_gesture_windows removeAllObjects];
        } else {
            NSLog(@"[TTG] ✋ 没暂存手势 → 让定时器重新装");
        }
        // 让定时器立即跑一遍装好手势
        dispatch_async(dispatch_get_main_queue(), ^{
            UIWindow *win = TTGFrontmostWindow();
            if (win) TTGInstallGesturesOnWindow(win);
        });
    }
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
    title.text = @"🌿 那年夏天 🌊";
    title.font = [UIFont boldSystemFontOfSize:18];
    title.textColor = [UIColor colorWithWhite:0 alpha:0.9];
    [_sheet addSubview:title];

    UILabel *sub = [[UILabel alloc] init];
    sub.text = @"";  // 已删除副标题
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
    // 3 行 × 2 列：保存视频、保存图片、保存音频、保存实况、复制链接、设置面板
    NSArray *actionBtns = @[
        @{@"icon": @"arrow.down.circle.fill", @"title": @"保存视频", @"action": ^{ TTGDownloadAndSave(); }},
        @{@"icon": @"photo.on.rectangle", @"title": @"保存图片", @"action": ^{ TTGDownloadImage(); }},
        @{@"icon": @"music.note", @"title": @"保存音频", @"action": ^{ TTGDownloadMusic(); }},
        @{@"icon": @"livephoto", @"title": @"保存实况", @"action": ^{ TTGDownloadLivePhoto(); }},
        @{@"icon": @"link", @"title": @"复制链接", @"action": ^{ TTGCopyShareLink(); }},
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
    footer.text = @"by ashun520 · 长按视频唤起";
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
        if (!cls) { _panelShowing = NO; return; }
        UIViewController *vc = [[cls alloc] init];
        if (!vc) { _panelShowing = NO; return; }

        // 恢复 v36 的 present 方式：不做任何手势 disable/remove
        // OverFullScreen present 应该自动把触摸路由到 presented view
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
        // 两个都在 → 尊重全局 suspended 标志，不要强制 enable！
        if (!_ttg_gesturesSuspended) {
            for (UIGestureRecognizer *gr in win.gestureRecognizers) {
                if ([gr isKindOfClass:[TTGSinglePressRecognizer class]]) gr.enabled = YES;
                if ([gr isKindOfClass:[UILongPressGestureRecognizer class]] &&
                    ![gr isKindOfClass:[TTGSinglePressRecognizer class]] &&
                    ((UILongPressGestureRecognizer *)gr).numberOfTouchesRequired == 2) gr.enabled = YES;
            }
        }
        return;
    }

    // ====== 关键修复！suspended 期间绝对不能装新手势！======
    if (_ttg_gesturesSuspended) {
        NSLog(@"[TTG] 🔒 suspended=YES → 不装新手势，等面板关闭");
        return;
    }

    // 缺哪个装哪个（不要重复装）
    if (!hasSingle) {
        TTGSinglePressRecognizer *single = [[TTGSinglePressRecognizer alloc]
            initWithTarget:[TTGLongPressHandler shared] action:@selector(handleSingleLongPress:)];
        single.delegate = single;  // shouldReceiveTouch 过滤非视频区域
        single.minimumPressDuration = 999.0;  // 让 super 的 timer 永不触发，我们有自研的
        single.numberOfTouchesRequired = 1;
        single.allowableMovement = 25;
        // 关键：NO = 不吞触摸事件！否则底下的 switch/slider/按钮全点不动
        // 我们自研 timer，到点才 Began，不需要 cancel 别人的触摸
        single.cancelsTouchesInView = NO;
        single.delaysTouchesBegan = NO;
        single.delaysTouchesEnded = NO;
        [win addGestureRecognizer:single];
        NSLog(@"[TTG] ✋ 单指长按手势已装到 window (cancelsTouchesInView=NO 不吞触摸)");
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

#pragma mark - 地区选择页

@interface TTGRegionPickerViewController : UITableViewController
@end

@implementation TTGRegionPickerViewController {
    NSArray *_sortedKeys;
    NSString *_originalRegion;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    self.title = @"选择地区";
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
    }
    self.tableView.rowHeight = 52;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 0);

    // 按国家名排序（🇺🇸 美国 会在🇦🇺 澳大利亚之前等）
    _sortedKeys = [[TTGCountryList() allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [TTGCountryList()[a][@"name"] compare:TTGCountryList()[b][@"name"]];
    }];
    _originalRegion = ttgSelectedRegion;

    // 右上角取消按钮
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelTapped)];
}

- (void)cancelTapped {
    // 没改动 → 什么都不做
    [self.navigationController popViewControllerAnimated:YES];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _sortedKeys.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *rid = @"TTGRegionCell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:rid];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:rid];
    }
    NSString *code = _sortedKeys[indexPath.row];
    NSDictionary *info = TTGCountryList()[code];
    cell.textLabel.text = info[@"name"];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"ISO: %@  MCC: %@  MNC: %@  Lang: %@", info[@"iso"], info[@"mcc"], info[@"mnc"], info[@"lang"]];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:11];

    if ([code isEqualToString:ttgSelectedRegion]) {
        cell.accessoryType = UITableViewCellAccessoryCheckmark;
    } else {
        cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *code = _sortedKeys[indexPath.row];
    if ([code isEqualToString:ttgSelectedRegion]) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }

    ttgSelectedRegion = code;
    TTGApplyRegionChange();

    // 震动反馈
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [fb impactOccurred];
    }

    NSString *name = TTGRegionDisplayName();
    TTGShowToast([NSString stringWithFormat:@"✅ 已切换到 %@（建议重启 TikTok）", name]);

    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - 底栏设置详情页（滑块 + 悬浮）

@interface TTGTabBarSettingsViewController : UIViewController
@end

@implementation TTGTabBarSettingsViewController {
    UISwitch *_mainSwitch;
    UISwitch *_floatSwitch;
    UISlider *_slider;
    UILabel *_alphaLabel;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"🎛️ 底栏设置";
    self.view.backgroundColor = [UIColor systemBackgroundColor];
    [self setupUI];
}

- (void)setupUI {
    // 清旧的 label/hint/preview（tag >= 9000 的）
    [[self.view.subviews copy] enumerateObjectsUsingBlock:^(UIView *v, NSUInteger idx, BOOL *stop) {
        if (v.tag >= 9000 && v.tag != 9101 && v.tag != 9102 && v.tag != 9103) [v removeFromSuperview];
    }];

    CGFloat h = self.view.bounds.size.height;
    CGFloat w = self.view.bounds.size.width;
    if (w <= 0) w = [UIScreen mainScreen].bounds.size.width;
    if (h <= 0) h = [UIScreen mainScreen].bounds.size.height;

    CGFloat pad = 20;
    CGFloat top = 120;

    // 总开关 Label
    UILabel *lbl1 = (UILabel *)[self.view viewWithTag:9001];
    if (!lbl1) {
        lbl1 = [[UILabel alloc] init];
        lbl1.tag = 9001;
        lbl1.text = @"启用底栏设置";
        lbl1.font = [UIFont boldSystemFontOfSize:16];
        [self.view addSubview:lbl1];
    }
    lbl1.frame = CGRectMake(pad, top, w - pad * 2 - 80, 30);

    // 总开关 Switch
    if (!_mainSwitch) {
        _mainSwitch = [[UISwitch alloc] init];
        _mainSwitch.on = tabBarTransparent;
        [_mainSwitch addTarget:self action:@selector(mainChanged:) forControlEvents:UIControlEventValueChanged];
    }
    _mainSwitch.frame = CGRectMake(w - pad - 60, top, 60, 30);
    [self.view addSubview:_mainSwitch];

    top += 60;

    // 悬浮 Label
    UILabel *lbl2 = (UILabel *)[self.view viewWithTag:9002];
    if (!lbl2) {
        lbl2 = [[UILabel alloc] init];
        lbl2.tag = 9002;
        lbl2.text = @"🧊 悬浮底栏（圆角+阴影+毛玻璃）";
        lbl2.font = [UIFont systemFontOfSize:15];
        [self.view addSubview:lbl2];
    }
    lbl2.frame = CGRectMake(pad, top, w - pad * 2 - 80, 30);

    if (!_floatSwitch) {
        _floatSwitch = [[UISwitch alloc] init];
        _floatSwitch.on = tabBarFloating;
        [_floatSwitch addTarget:self action:@selector(floatChanged:) forControlEvents:UIControlEventValueChanged];
    }
    _floatSwitch.frame = CGRectMake(w - pad - 60, top, 60, 30);
    [self.view addSubview:_floatSwitch];

    top += 60;

    UILabel *lbl3 = (UILabel *)[self.view viewWithTag:9003];
    if (!lbl3) {
        lbl3 = [[UILabel alloc] init];
        lbl3.tag = 9003;
        lbl3.text = @"透明度";
        lbl3.font = [UIFont boldSystemFontOfSize:16];
        [self.view addSubview:lbl3];
    }
    lbl3.frame = CGRectMake(pad, top, w - pad * 2, 30);

    top += 40;

    if (!_slider) {
        _slider = [[UISlider alloc] init];
        _slider.minimumValue = 0.0;
        _slider.maximumValue = 1.0;
        _slider.value = tabBarAlpha;
        [_slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
        [self.view addSubview:_slider];
    }
    _slider.frame = CGRectMake(pad, top, w - pad * 2, 40);

    top += 40;

    if (!_alphaLabel) {
        _alphaLabel = [[UILabel alloc] init];
        _alphaLabel.textAlignment = NSTextAlignmentCenter;
        _alphaLabel.font = [UIFont fontWithName:@"Menlo" size:15];
        _alphaLabel.textColor = [UIColor systemGrayColor];
        [self.view addSubview:_alphaLabel];
    }
    _alphaLabel.frame = CGRectMake(pad, top, w - pad * 2, 30);
    [self updateAlphaLabel];

    // 说明
    top += 70;
    UILabel *hint = (UILabel *)[self.view viewWithTag:9101];
    if (!hint) {
        hint = [[UILabel alloc] init];
        hint.tag = 9101;
        hint.font = [UIFont systemFontOfSize:13];
        hint.textColor = [UIColor systemGrayColor];
        hint.numberOfLines = 0;
        hint.text = @"💡 滑动调节底栏透明度。0% = 全透明（只剩按钮），100% = 不透明。\n开启悬浮模式后，底栏会变成一个带圆角和毛玻璃的悬浮胶囊，视觉效果更高级。";
        [self.view addSubview:hint];
    }
    CGSize hintSize = [hint sizeThatFits:CGSizeMake(w - pad * 2, 1000)];
    hint.frame = CGRectMake(pad, top, w - pad * 2, hintSize.height);

    // 预览按钮
    top += hintSize.height + 10;
    UIButton *preview = (UIButton *)[self.view viewWithTag:9102];
    if (!preview) {
        preview = [UIButton buttonWithType:UIButtonTypeSystem];
        preview.tag = 9102;
        [preview setTitle:@"👀 实时预览效果" forState:UIControlStateNormal];
        preview.titleLabel.font = [UIFont boldSystemFontOfSize:16];
        preview.backgroundColor = [UIColor systemBlueColor];
        [preview setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        preview.layer.cornerRadius = 10;
        [preview addTarget:self action:@selector(previewNow) forControlEvents:UIControlEventTouchUpInside];
        [self.view addSubview:preview];
    }
    preview.frame = CGRectMake(pad, top, w - pad * 2, 44);
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self setupUI];
}

- (void)updateAlphaLabel {
    if (!_alphaLabel) return;
    int pct = (int)(_slider.value * 100);
    NSString *desc;
    if (pct <= 10) desc = @"几乎全透明";
    else if (pct <= 30) desc = @"极透明（推荐）";
    else if (pct <= 50) desc = @"半透明";
    else if (pct <= 80) desc = @"较实";
    else desc = @"接近不透明";
    _alphaLabel.text = [NSString stringWithFormat:@"%d%% — %@", pct, desc];
}

- (void)mainChanged:(UISwitch *)sw {
    NSLog(@"[TTG] 🎛️ tabbar mainChanged → on=%d", sw.on);
    tabBarTransparent = sw.on;
    TTGApplyTabBarTransparent();
    TTGShowToast(sw.on ? @"✅ 底栏透明已开启" : @"✅ 底栏已还原");
}

- (void)floatChanged:(UISwitch *)sw {
    NSLog(@"[TTG] 🎛️ tabbar floatChanged → on=%d", sw.on);
    tabBarFloating = sw.on;
    if (!tabBarTransparent) {
        tabBarTransparent = YES;
        _mainSwitch.on = YES;
    }
    TTGApplyTabBarTransparent();
    TTGShowToast(sw.on ? @"🧊 悬浮模式已开启" : @"🧊 悬浮模式已关闭");
}

- (void)sliderChanged:(UISlider *)s {
    NSLog(@"[TTG] 🎛️ sliderChanged → value=%.2f", s.value);
    tabBarAlpha = s.value;
    [self updateAlphaLabel];
    if (tabBarTransparent) TTGApplyTabBarTransparent();
}

- (void)previewNow {
    TTGApplyTabBarTransparent();
    TTGShowToast(@"👀 已应用，去 TikTok 主界面看效果");
}

@end

#pragma mark - 隐藏顶栏元素详情页（checklist）

@interface TTGTopBarSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation TTGTopBarSettingsViewController {
    UISwitch *_mainSwitch;
    UITableView *_tv;
    NSArray *_items; // @[@{title, ptr:BOOL*, desc}]
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"🔝 隐藏顶栏元素";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    // frame 里存的是相对偏移，viewDidLayoutSubviews 再算绝对坐标
    [self setupUI];
}

- (void)setupUI {
    // 清掉旧的（防止 viewDidLayoutSubviews 重复调用）
    [[self.view.subviews copy] enumerateObjectsUsingBlock:^(UIView *v, NSUInteger idx, BOOL *stop) {
        if (v.tag >= 9000) [v removeFromSuperview];
    }];

    CGFloat h = self.view.bounds.size.height;
    CGFloat w = self.view.bounds.size.width;
    if (w <= 0) w = [UIScreen mainScreen].bounds.size.width;
    if (h <= 0) h = [UIScreen mainScreen].bounds.size.height;

    CGFloat pad = 20;
    CGFloat top = 120; // 避开导航栏
    CGFloat contentW = w - pad * 2;

    // 总开关 Label
    UILabel *lbl1 = [[UILabel alloc] init];
    lbl1.tag = 9001;
    lbl1.frame = CGRectMake(pad, top, contentW - 80, 30);
    lbl1.text = @"启用顶栏元素隐藏";
    lbl1.font = [UIFont boldSystemFontOfSize:16];
    [self.view addSubview:lbl1];

    // 总开关 UISwitch
    if (!_mainSwitch) {
        _mainSwitch = [[UISwitch alloc] init];
        _mainSwitch.on = hideTopBarItems;
        [_mainSwitch addTarget:self action:@selector(mainChanged:) forControlEvents:UIControlEventValueChanged];
    }
    _mainSwitch.frame = CGRectMake(w - pad - 60, top, 60, 30);
    [self.view addSubview:_mainSwitch];

    top += 50;

    // 小标题
    UILabel *lbl2 = [[UILabel alloc] init];
    lbl2.tag = 9002;
    lbl2.frame = CGRectMake(pad, top, contentW, 30);
    lbl2.text = @"选择要隐藏的元素";
    lbl2.font = [UIFont boldSystemFontOfSize:16];
    lbl2.textColor = [UIColor systemGray2Color];
    [self.view addSubview:lbl2];

    top += 30;

    // 数据
    if (!_items) {
        _items = @[
            @{@"title": @"📺 推荐 / For You Tab",    @"ptr": [NSValue valueWithPointer:(const void *)&hide_Tab_Recommended], @"desc": @"For You / 推荐 文字 tab"},
            @{@"title": @"👥 关注 / Following Tab",  @"ptr": [NSValue valueWithPointer:(const void *)&hide_Tab_Following],   @"desc": @"Following / 关注 文字 tab"},
            @{@"title": @"🤝 好友 / Friends Tab",     @"ptr": [NSValue valueWithPointer:(const void *)&hide_Tab_Friends],     @"desc": @"Friends / 好友 文字 tab"},
            @{@"title": @"🔴 LIVE 直播入口",           @"ptr": [NSValue valueWithPointer:(const void *)&hide_Tab_Live],         @"desc": @"LIVE / 直播 tab"},
            @{@"title": @"➕ 中间 + 号 / 小花按钮",    @"ptr": [NSValue valueWithPointer:(const void *)&hide_Tab_Plus],        @"desc": @"发视频的创建按钮，默认隐藏"},
            @{@"title": @"👤 右上角头像",              @"ptr": [NSValue valueWithPointer:(const void *)&hide_Tab_Avatar],      @"desc": @"头像/个人主页入口，默认隐藏"},
            @{@"title": @"🔍 搜索按钮",                @"ptr": [NSValue valueWithPointer:(const void *)&hide_Tab_Search],       @"desc": @"顶栏右上角搜索图标"},
        ];
    }

    // TableView
    if (!_tv) {
        _tv = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleGrouped];
        _tv.dataSource = self;
        _tv.delegate = self;
        _tv.backgroundColor = [UIColor systemBackgroundColor];
    }
    _tv.frame = CGRectMake(0, top, w, h - top);
    [self.view addSubview:_tv];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self setupUI];
    // 不要在这里 reloadData —— 会触发 cellForRow 重复创建 switch
}

- (void)mainChanged:(UISwitch *)sw {
    NSLog(@"[TTG] 🔝 mainChanged → on=%d", sw.on);
    hideTopBarItems = sw.on;
    TTGApplyHideTopBar();
    TTGShowToast(sw.on ? @"✅ 隐藏顶栏已开启" : @"✅ 顶栏已还原");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _items.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *ReuseId = @"topbarcell";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ReuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:ReuseId];
    }
    NSDictionary *it = _items[indexPath.row];
    cell.textLabel.text = it[@"title"];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.detailTextLabel.text = it[@"desc"];
    cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
    cell.detailTextLabel.textColor = [UIColor systemGrayColor];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    BOOL *flag = (BOOL *)[(NSValue *)it[@"ptr"] pointerValue];
    // 复用 accessoryView，不要每次新建
    UISwitch *sw = (UISwitch *)cell.accessoryView;
    if (!sw || ![sw isKindOfClass:[UISwitch class]]) {
        sw = [[UISwitch alloc] init];
        if (@available(iOS 13.0, *)) sw.onTintColor = [UIColor systemGreenColor];
        cell.accessoryView = sw;
    }
    sw.tag = indexPath.row;
    sw.on = flag ? *flag : NO;
    [sw removeTarget:nil action:nil forControlEvents:UIControlEventValueChanged];
    [sw addTarget:self action:@selector(itemToggled:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (void)itemToggled:(UISwitch *)sw {
    if (sw.tag < 0 || sw.tag >= (int)_items.count) return;
    NSDictionary *it = _items[sw.tag];
    BOOL *flag = (BOOL *)[(NSValue *)it[@"ptr"] pointerValue];
    if (flag) *flag = sw.isOn;
    // 至少勾了一个 → 自动开总开关
    BOOL any = NO;
    for (NSDictionary *d in _items) {
        BOOL *f = (BOOL *)[(NSValue *)d[@"ptr"] pointerValue];
        if (f && *f) { any = YES; break; }
    }
    if (any && !hideTopBarItems) {
        hideTopBarItems = YES;
        _mainSwitch.on = YES;
    } else if (!any && hideTopBarItems) {
        hideTopBarItems = NO;
        _mainSwitch.on = NO;
    }
    TTGApplyHideTopBar();
}

@end

#pragma mark - 设置页（液态玻璃）

@interface TTGSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@implementation TTGSettingsViewController {
    NSArray *_rows;
    UITableView *_tableView;
    UIView *_dimmingView;
    UIView *_card;
    UINavigationController *_detailNav;  // 强持有详情页 nav，防止 vc 被释放
}

- (void)viewDidLoad {
    [super viewDidLoad];
    NSLog(@"[TTG] 🎬 TTGSettingsViewController viewDidLoad 开始 — self=%@", self);
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

    // 数据（两种类型：switch 行带 ptr；action 行带 action key）
    NSMutableArray *rows = [NSMutableArray array];
    [rows addObject:@{@"title": @"去广告",       @"ptr": [NSValue valueWithPointer:(const void *)&noads]}];
    [rows addObject:@{@"title": @"无水印下载",    @"ptr": [NSValue valueWithPointer:(const void *)&downloadWithoutWatermark]}];
    [rows addObject:@{@"title": @"自动连播下一个", @"ptr": [NSValue valueWithPointer:(const void *)&autoPlayNextVideo]}];
    [rows addObject:@{@"title": @"🌍 切换地区",   @"action": @"region"}];  // 特殊行，点击弹选择列表
    [rows addObject:@{@"title": @"强制显示进度条", @"ptr": [NSValue valueWithPointer:(const void *)&showProgressBar]}];
    [rows addObject:@{@"title": @"隐藏视频上的UI", @"ptr": [NSValue valueWithPointer:(const void *)&canHideUI]}];
    [rows addObject:@{@"title": @"画中画（PiP）", @"ptr": [NSValue valueWithPointer:(const void *)&enablePIP]}];
    [rows addObject:@{@"title": @"后台继续播放",   @"ptr": [NSValue valueWithPointer:(const void *)&enableBackgroundPlay]}];
    [rows addObject:@{@"title": @"安全检测绕过",   @"ptr": [NSValue valueWithPointer:(const void *)&enableBypass]}];
    [rows addObject:@{@"title": @"🎛️ 底栏设置",    @"action": @"tabbar"}];      // 点击进详情（滑块+悬浮）
    [rows addObject:@{@"title": @"🔝 隐藏顶栏元素", @"action": @"topbar"}];      // 点击进详情（子选项）
    _rows = rows;

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

    // 点遮罩关闭 — 已删除 tap 手势！任何 tap 手势都可能干扰 card 内的 switch 触摸
    // 用户用右上角 ✕ 关闭即可
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
    noads = downloadWithoutWatermark = autoPlayNextVideo = showProgressBar = canHideUI = enablePIP = enableBackgroundPlay = enableBypass = YES;
    // 子项默认：隐藏 + 号和头像
    hide_Tab_Plus = YES;
    hide_Tab_Avatar = YES;
    hideTopBarItems = YES;
    tabBarTransparent = YES;
    tabBarAlpha = 0.15;
    tabBarFloating = NO;
    TTGApplyTabBarTransparent();
    TTGApplyHideTopBar();
    [_tableView reloadData];
    TTGShowToast(@"✅ 所有功能已开启");
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return _rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *ReuseId = @"TTGSettingsCell3";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:ReuseId];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:ReuseId];
        cell.backgroundColor = [UIColor clearColor];
        cell.contentView.backgroundColor = [UIColor clearColor];
    }
    NSDictionary *row = _rows[indexPath.row];
    cell.textLabel.text = row[@"title"];
    cell.textLabel.font = [UIFont systemFontOfSize:15];
    cell.textLabel.textColor = [UIColor colorWithWhite:0 alpha:0.85];

    if (row[@"action"]) {
        // Action 行
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.accessoryView = nil;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        cell.detailTextLabel.font = [UIFont systemFontOfSize:13];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:0 alpha:0.5];

        if ([row[@"action"] isEqualToString:@"region"]) {
            cell.detailTextLabel.text = TTGRegionDisplayName();
        } else if ([row[@"action"] isEqualToString:@"tabbar"]) {
            if (tabBarTransparent) {
                NSString *alphaStr = [NSString stringWithFormat:@"%.0f%%", tabBarAlpha * 100];
                cell.detailTextLabel.text = tabBarFloating ? [NSString stringWithFormat:@"🧊 悬浮 %@", alphaStr] : alphaStr;
            } else {
                cell.detailTextLabel.text = @"关闭";
            }
        } else if ([row[@"action"] isEqualToString:@"topbar"]) {
            int count = 0;
            if (hide_Tab_Recommended) count++;
            if (hide_Tab_Following) count++;
            if (hide_Tab_Friends) count++;
            if (hide_Tab_Live) count++;
            if (hide_Tab_Plus) count++;
            if (hide_Tab_Avatar) count++;
            if (hide_Tab_Search) count++;
            cell.detailTextLabel.text = count > 0 ? [NSString stringWithFormat:@"已隐藏 %d 项", count] : @"关闭";
        } else {
            cell.detailTextLabel.text = nil;
        }
    } else {
        // Switch 行
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.detailTextLabel.text = nil;
        BOOL *flag = (BOOL *)[(NSValue *)row[@"ptr"] pointerValue];

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
        NSLog(@"[TTG] 📋 cellForRow[%ld] → switch tag=%ld target=%@ self=%@",
              (long)indexPath.row, (long)sw.tag, NSStringFromClass([self class]), self);
    }
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *row = _rows[indexPath.row];
    NSString *action = row[@"action"];
    if (!action) return;

    UIViewController *vc = nil;
    if ([action isEqualToString:@"region"]) {
        vc = [[TTGRegionPickerViewController alloc] init];
    } else if ([action isEqualToString:@"tabbar"]) {
        vc = [[TTGTabBarSettingsViewController alloc] init];
    } else if ([action isEqualToString:@"topbar"]) {
        vc = [[TTGTopBarSettingsViewController alloc] init];
    }
    if (!vc) return;

    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.navigationBar.tintColor = [UIColor systemBlueColor];
    vc.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"关闭" style:UIBarButtonItemStylePlain target:self
        action:@selector(removeNavFromWindow)];

    // 关键：强持有 nav！否则 ARC 立即释放 nav 和 vc → switch 的 target 变野指针
    _detailNav = nav;

    // 不走 present！直接把 nav.view 加到 window 上
    UIWindow *win = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if ([scene isKindOfClass:NSClassFromString(@"UIWindowScene")]) {
                NSArray *ws = [(id)scene windows];
                if (ws.count > 0) { win = ws[0]; break; }
            }
        }
    }
    if (!win) win = [UIApplication sharedApplication].windows.firstObject;
    if (!win) return;

    nav.view.frame = win.bounds;
    nav.view.alpha = 0;
    nav.view.tag = 9999;
    [win addSubview:nav.view];

    [UIView animateWithDuration:0.25 animations:^{ nav.view.alpha = 1; }];
    NSLog(@"[TTG] 📱 详情页 %@ 已加到 window", NSStringFromClass([vc class]));
}

- (void)removeNavFromWindow {
    // 找到所有 window 里 tag=9999 的 view，移除
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
        UIView *v = [win viewWithTag:9999];
        if (v) {
            [UIView animateWithDuration:0.2 animations:^{ v.alpha = 0; } completion:^(BOOL done) {
                [v removeFromSuperview];
                self->_detailNav = nil;
            }];
            return;
        }
    }
    self->_detailNav = nil;
}

// 兼容旧方法（如果哪里还在调）
- (void)dismissDetail:(id)sender {
    [self removeNavFromWindow];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    cell.backgroundColor = [UIColor clearColor];
    cell.contentView.backgroundColor = [UIColor clearColor];
}

- (void)switchToggled:(UISwitch *)sw {
    NSLog(@"[TTG] 🎛️ switchToggled: tag=%ld on=%d title=%@", (long)sw.tag, sw.isOn, _rows[sw.tag][@"title"]);
    if (sw.tag < 0 || sw.tag >= (int)_rows.count) return;
    NSDictionary *row = _rows[sw.tag];
    BOOL *flag = (BOOL *)[(NSValue *)row[@"ptr"] pointerValue];
    if (flag) *flag = sw.isOn;

    // 振动反馈 —— 让用户无电脑也能验证触摸是否到达！
    if (@available(iOS 10.0, *)) {
        UIImpactFeedbackGenerator *fb = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [fb impactOccurred];
    }

    // 立即应用
    if (flag == &tabBarTransparent) {
        TTGApplyTabBarTransparent();
    } else if (flag == &hideTopBarItems) {
        TTGApplyHideTopBar();
    }

    // 强制刷新 tableView（保险起见）
    [_tableView reloadData];
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

        // 恢复用户上次选择的地区 + 应用
        NSString *savedRegion = [[NSUserDefaults standardUserDefaults] stringForKey:@"ttg_selected_region"];
        if (savedRegion.length > 0 && TTGCountryList()[savedRegion]) {
            ttgSelectedRegion = savedRegion;
        }
        TTGApplyRegionChange(); // 无论用户选了啥都 apply（默认 US）
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

#pragma mark - 复制视频/帖子链接

static void TTGCopyShareLink(void) {
    @try {
        id aweme = TTGFindAwemeFromViewHierarchy();
        if (!aweme) { TTGShowToast(@"❌ 没找到当前内容"); return; }

        // TikTok aweme 有多种链接字段，逐个试
        NSString *link = nil;

        // 1. aweme.shareURL / aweme.shareInfo.shareUrl
        id shareInfo = TTGGetValue(aweme, @"shareInfo");
        if (shareInfo) {
            for (NSString *key in @[@"shareUrl", @"url", @"shareURL"]) {
                id v = TTGGetValue(shareInfo, key);
                if ([v isKindOfClass:[NSString class]] && [v hasPrefix:@"http"]) { link = v; break; }
            }
        }
        if (!link) {
            for (NSString *key in @[@"shareURL", @"shareUrl", @"share_link", @"webURL"]) {
                id v = TTGGetValue(aweme, key);
                if ([v isKindOfClass:[NSString class]] && [v hasPrefix:@"http"]) { link = v; break; }
            }
        }

        // 2. 兜底：用 awemeID 拼一个 web 链接（TikTok 网页版）
        if (!link) {
            id awemeID = TTGGetValue(aweme, @"awemeID");
            if (!awemeID) awemeID = TTGGetValue(aweme, @"aid");
            if (awemeID) {
                // 尝试找 author 的 secUid / uniqueID
                id author = TTGGetValue(aweme, @"author");
                NSString *secUid = nil;
                if (author) {
                    for (NSString *key in @[@"secUid", @"sec_uid", @"uniqueID", @"unique_id"]) {
                        id v = TTGGetValue(author, key);
                        if ([v isKindOfClass:[NSString class]] && [v length] > 0) { secUid = v; break; }
                    }
                }
                if (secUid) {
                    link = [NSString stringWithFormat:@"https://www.tiktok.com/@%@/video/%@", secUid, awemeID];
                } else {
                    link = [NSString stringWithFormat:@"https://www.tiktok.com/video/%@", awemeID];
                }
                NSLog(@"[TTG] 🔗 用 awemeID 拼了链接: %@", link);
            }
        }

        if (!link) {
            TTGShowToast(@"❌ 没找到可复制的链接");
            return;
        }

        NSLog(@"[TTG] 🔗 复制链接: %@", link);
        [UIPasteboard generalPasteboard].string = link;
        TTGShowToast(@"✅ 链接已复制到剪贴板");
    } @catch (NSException *e) {
        NSLog(@"[TTG] copy link err: %@", e);
        TTGShowToast(@"❌ 复制出错");
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
        if (!urlStr) { TTGShowToast(@"❌ 这首没音频可存"); return; }

        NSString *musicName = TTGExtractMusicName(aweme);
        NSLog(@"[TTG] 🎵 音频名: %@ URL: %@", musicName, urlStr);

        TTGShowToast(@"⏳ 正在提取音频...");

        // 清洗文件名（iOS 文件系统不允许的字符）
        NSString *cleanName = [musicName stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
        cleanName = [cleanName stringByReplacingOccurrencesOfString:@"\\" withString:@"_"];
        cleanName = [cleanName stringByReplacingOccurrencesOfString:@":" withString:@"_"];
        cleanName = [cleanName stringByReplacingOccurrencesOfString:@"*" withString:@"_"];
        cleanName = [cleanName stringByReplacingOccurrencesOfString:@"?" withString:@"_"];
        cleanName = [cleanName stringByReplacingOccurrencesOfString:@"\"" withString:@"_"];
        cleanName = [cleanName stringByReplacingOccurrencesOfString:@"<" withString:@"_"];
        cleanName = [cleanName stringByReplacingOccurrencesOfString:@">" withString:@"_"];
        cleanName = [cleanName stringByReplacingOccurrencesOfString:@"|" withString:@"_"];
        if (cleanName.length == 0) cleanName = @"tiktok_audio";

        // 下载到 Documents（进程 100% 有写权限）
        NSString *docDir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        NSString *outPath = [docDir stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@_%ld.mp3", cleanName, (long)[[NSDate date] timeIntervalSince1970]]];
        NSURL *outURL = [NSURL fileURLWithPath:outPath];
        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];

        NSLog(@"[TTG] 🎵 outPath = %@, docDir writable=%d", outPath, [[NSFileManager defaultManager] isWritableFileAtPath:docDir]);

        NSURL *url = [NSURL URLWithString:urlStr];
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        [req setValue:@"com.ss.android.ugc.aweme" forHTTPHeaderField:@"X-App-Pkg"];
        [req setValue:@"Mozilla/5.0 (iPhone; CPU iPhone OS 16_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 com.ss.android.ugc.aweme/47.6.0" forHTTPHeaderField:@"User-Agent"];
        [req setTimeoutInterval:120];

        NSURLSessionDownloadTask *task = [[NSURLSession sharedSession] downloadTaskWithRequest:req
            completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error || !location) {
                        NSLog(@"[TTG] 🎵 ❌ download err: %@", error);
                        TTGShowToast(@"❌ 下载音频失败");
                        return;
                    }
                    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
                    if (http.statusCode >= 400) {
                        TTGShowToast([NSString stringWithFormat:@"❌ 音频链接失效(%ld)", (long)http.statusCode]);
                        return;
                    }

                    // 用 NSData 直接读，绕开 CFNetwork 临时文件的 copyItem 问题
                    NSError *readErr = nil;
                    NSData *data = [NSData dataWithContentsOfURL:location options:0 error:&readErr];
                    if (!data) {
                        NSLog(@"[TTG] 🎵 ❌ 读临时文件失败: %@", readErr);
                        TTGShowToast(@"❌ 读取下载数据失败");
                        return;
                    }
                    NSLog(@"[TTG] 🎵 下载完成 %ld bytes, 写 → %@", (long)data.length, outPath);

                    NSError *writeErr = nil;
                    if (![data writeToURL:outURL options:NSDataWritingAtomic error:&writeErr]) {
                        NSLog(@"[TTG] 🎵 ❌ writeToURL 失败: %@", writeErr);
                        TTGShowToast([NSString stringWithFormat:@"❌ 保存失败: %@", writeErr.localizedDescription ?: @"未知"]);
                        return;
                    }
                    NSLog(@"[TTG] 🎵 ✅ 写入成功 → present 分享菜单");
                    TTGShowToast(@"✅ 提取成功，选择存储方式");

                    // 弹出系统分享菜单（UIActivityViewController）
                    UIViewController *topVC = TTGTopVC();
                    if (!topVC) { TTGShowToast(@"❌ 没找到顶层界面"); return; }

                    UIActivityViewController *avc = [[UIActivityViewController alloc]
                        initWithActivityItems:@[outURL] applicationActivities:nil];
                    avc.completionWithItemsHandler = ^(UIActivityType activityType, BOOL completed,
                        NSArray *returnedItems, NSError *activityError) {
                        if (completed) {
                            NSLog(@"[TTG] 🎵 ✅ 用户完成分享: %@", activityType);
                            TTGShowToast(@"✅ 已保存");
                        }
                        // 清理临时文件
                        [[NSFileManager defaultManager] removeItemAtURL:outURL error:nil];
                    };

                    // iPad 需要 sourceView/sourceRect
                    if (avc.popoverPresentationController) {
                        avc.popoverPresentationController.sourceView = topVC.view;
                        avc.popoverPresentationController.sourceRect = CGRectMake(topVC.view.bounds.size.width/2 - 100, topVC.view.bounds.size.height - 200, 200, 100);
                        avc.popoverPresentationController.permittedArrowDirections = 0;
                    }

                    [topVC presentViewController:avc animated:YES completion:nil];
                });
            }];
        [task resume];
    } @catch (NSException *e) {
        NSLog(@"[TTG] save audio err: %@", e);
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
                    // 3. 底栏透明保持
                    if (tabBarTransparent) TTGApplyTabBarTransparent();
                    // 4. 隐藏顶栏元素保持
                    if (hideTopBarItems) TTGApplyHideTopBar();
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
