// WCZZRed 0.2-1
// Standalone red packet detail overlay for WeChat 8.0.75.
// Extracted from WCZZ: always on, no switches, no settings, no plugin registration.
//
// 0.2 (optimized):
//   * WCZZLog compiles out entirely when WCZZ_DEBUG == 0
//   * red packet model is parsed once into a plain struct (was 4+ KVC calls per pass)
//   * one apply token per view controller: old deferred passes bail out instead of
//     re-running, and deferred blocks hold the VC weakly
//   * no bringSubviewToFront (zPosition already guarantees draw order)
//   * the label is never created inside a layout pass
//   * hooks install synchronously when the classes are already registered
//   * no strong global reference to WeChat's data model

#import "WeChatCompat.h"
#import "WeChatHeaders.h"

#import <objc/runtime.h>
#import <objc/message.h>

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <stdarg.h>

#ifndef WCZZ_DEBUG
#define WCZZ_DEBUG 0
#endif

#if WCZZ_DEBUG
#define WCZZLog(fmt, ...) NSLog((@"[WCZZRed] " fmt), ##__VA_ARGS__)
#else
#define WCZZLog(fmt, ...) do { } while (0)
#endif

#pragma mark - Helpers

static inline id WCZZValue(id obj, NSString *key) {
    if (!obj) return nil;
    @try { return [obj valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}

static inline long long WCZZLongLong(id obj, NSString *key) {
    id value = WCZZValue(obj, key);
    return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0LL;
}

#pragma mark - Red envelope summary overlay

static const void *WCZZRedDataKey = &WCZZRedDataKey;
static const void *WCZZRedSummaryLabelKey = &WCZZRedSummaryLabelKey;
static const void *WCZZRedApplyTokenKey = &WCZZRedApplyTokenKey;

static const NSInteger WCZZRedSummaryLabelTag = 0x575A01;

// The red header is drawn above/around the safe-area region on this screen.
// Anchoring to safeAreaInsets.top clipped three of the four lines, so the
// overlay stays pinned near the top edge.
static const CGFloat WCZZRedSummaryTop = 40.0;

// Weak on purpose: WeChat's control logic owns the model for the lifetime of the
// flow. A strong static here would keep the last red packet model alive forever.
static __weak id WCZZLatestRedData = nil;

typedef struct {
    long long totalAmount;   // in cents
    long long totalNum;
    long long recAmount;     // in cents
    long long recNum;
} WCZZRedSummary;

static id WCZZRedDetailInfo(id data) {
    if (!data) return nil;
    id info = WCZZValue(data, @"m_oWCRedEnvelopesDetailInfo");
    if (info) return info;
    id nested = WCZZValue(data, @"m_data");
    return nested ? WCZZValue(nested, @"m_oWCRedEnvelopesDetailInfo") : nil;
}

// Returns NO while WeChat is still filling the model in, so a half-built packet
// never overwrites a good value with zeros.
static BOOL WCZZParseRedSummary(id data, WCZZRedSummary *out) {
    id info = WCZZRedDetailInfo(data);
    if (!info || !out) return NO;

    WCZZRedSummary summary;
    summary.totalAmount = MAX(0LL, WCZZLongLong(info, @"m_lTotalAmount"));
    summary.totalNum    = MAX(0LL, WCZZLongLong(info, @"m_lTotalNum"));
    summary.recAmount   = MAX(0LL, WCZZLongLong(info, @"m_lRecAmount"));
    summary.recNum      = MAX(0LL, WCZZLongLong(info, @"m_lRecNum"));
    *out = summary;

    return (summary.totalAmount > 0 || summary.totalNum > 0);
}

static NSString *WCZZRedSummaryText(WCZZRedSummary summary) {
    long long remainAmount = MAX(0LL, summary.totalAmount - summary.recAmount);
    long long remainNum    = MAX(0LL, summary.totalNum - summary.recNum);

    // This is a standalone overlay label. Never touch m_receivedInfoLable: that
    // one belongs to WeChat's sender/amount area ("小号发出的红包" / "0.01元").
    return [NSString stringWithFormat:@"总金额:%.2f元\n总个数:%lld个\n剩余个数:%lld个\n剩余金额:%.2f元",
            summary.totalAmount / 100.0,
            summary.totalNum,
            remainNum,
            remainAmount / 100.0];
}

static UILabel *WCZZRedSummaryLabel(id vc) {
    if (![vc isKindOfClass:[UIViewController class]]) return nil;

    id associated = objc_getAssociatedObject(vc, WCZZRedSummaryLabelKey);
    if ([associated isKindOfClass:[UILabel class]]) return associated;

    // Re-adopt an existing label if the view hierarchy was rebuilt.
    UIView *root = [(UIViewController *)vc view];
    UIView *found = root ? [root viewWithTag:WCZZRedSummaryLabelTag] : nil;
    if ([found isKindOfClass:[UILabel class]]) {
        objc_setAssociatedObject(vc, WCZZRedSummaryLabelKey, found, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return (UILabel *)found;
    }
    return nil;
}

static UILabel *WCZZEnsureRedSummaryLabel(id vc) {
    if (![vc isKindOfClass:[UIViewController class]]) return nil;

    UIView *root = [(UIViewController *)vc view];
    if (!root) return nil;

    UILabel *label = WCZZRedSummaryLabel(vc);
    if (label) {
        if (label.superview != root) [root addSubview:label];
        return label;
    }

    label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.tag = WCZZRedSummaryLabelTag;
    label.numberOfLines = 4;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor clearColor];
    // Monospaced digits keep the four numbers aligned between refreshes.
    label.font = [UIFont monospacedDigitSystemFontOfSize:14.0 weight:UIFontWeightMedium];
    label.userInteractionEnabled = NO;
    label.layer.zPosition = 1000.0;
    [root addSubview:label];
    objc_setAssociatedObject(vc, WCZZRedSummaryLabelKey, label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    return label;
}

// Layout only: never creates a subview, so it is safe to call from
// viewDidLayoutSubviews.
static void WCZZLayoutRedSummaryLabel(id vc) {
    if (![vc isKindOfClass:[UIViewController class]]) return;

    UILabel *label = WCZZRedSummaryLabel(vc);
    UIView *root = [(UIViewController *)vc view];
    if (!label || !root) return;

    CGSize size = root.bounds.size;
    if (size.width <= 0.0 || size.height <= 0.0) return;

    CGFloat width  = MIN(300.0, MAX(230.0, size.width * 0.68));
    CGFloat height = MIN(102.0, size.height - 2.0 * WCZZRedSummaryTop);
    if (height < 44.0) height = 44.0;

    CGRect frame = CGRectMake(floor((size.width - width) * 0.5), WCZZRedSummaryTop, width, height);
    if (!CGRectEqualToRect(label.frame, frame)) label.frame = frame;
}

static void WCZZApplyRedSummary(id vc, id data) {
    if (!vc || !data) return;

    WCZZRedSummary summary;
    if (!WCZZParseRedSummary(data, &summary)) {
        WCZZLog(@"red summary: data not ready %p", data);
        return;
    }

    UILabel *label = WCZZEnsureRedSummaryLabel(vc);
    if (!label) return;

    NSString *text = WCZZRedSummaryText(summary);
    if (![label.text isEqualToString:text]) label.text = text;
    WCZZLayoutRedSummaryLabel(vc);

    WCZZLog(@"red summary applied total=%.2f num=%lld remain=%.2f/%lld label=%p",
            summary.totalAmount / 100.0, summary.totalNum,
            (summary.totalAmount - summary.recAmount) / 100.0,
            (summary.totalNum - summary.recNum), label);
}

static int64_t WCZZRedApplySequence = 0;

static void WCZZScheduleRedSummary(id vc, id data) {
    if (!vc || !data) return;

    objc_setAssociatedObject(vc, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Any newer schedule invalidates the deferred passes of the previous one, so
    // viewDidLoad / viewWillAppear / viewDidAppear collapse into one update.
    int64_t token = ++WCZZRedApplySequence;
    objc_setAssociatedObject(vc, WCZZRedApplyTokenKey, @(token), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    __weak UIViewController *weakVC = vc;
    __weak id weakData = data;

    static const double delays[] = { 0.0, 0.20, 0.50, 1.00 };
    for (size_t i = 0; i < sizeof(delays) / sizeof(delays[0]); i++) {
        double delay = delays[i];
        dispatch_block_t block = ^{
            UIViewController *strongVC = weakVC;
            if (!strongVC) return;

            NSNumber *current = objc_getAssociatedObject(strongVC, WCZZRedApplyTokenKey);
            if (current.longLongValue != token) return;   // superseded

            id latest = objc_getAssociatedObject(strongVC, WCZZRedDataKey) ?: weakData;
            WCZZApplyRedSummary(strongVC, latest);
        };

        if (delay <= 0.0) {
            if ([NSThread isMainThread]) {
                block();
            } else {
                dispatch_async(dispatch_get_main_queue(), block);
            }
        } else {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), block);
        }
    }
}

static id WCZZResolveRedData(id vc) {
    id data = objc_getAssociatedObject(vc, WCZZRedDataKey);
    if (!data) data = WCZZValue(vc, @"m_data");
    if (!data) data = WCZZLatestRedData;
    if (data) objc_setAssociatedObject(vc, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return data;
}

%group WCZZRedHooks

%hook WCRedEnvelopesControlLogic
- (id)initWithData:(id)data {
    id obj = %orig(data);
    if (data) WCZZLatestRedData = data;
    if (obj && data) objc_setAssociatedObject(obj, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLog(@"red control init data=%p", data);
    return obj;
}
- (void)showDetailView {
    %orig;
    id data = WCZZResolveRedData(self);
    if (!data) data = WCZZLatestRedData;
    WCZZLog(@"red base showDetailView data=%p", data);
}
%end

%hook WCRedEnvelopesReceiveControlLogic
- (id)initWithData:(id)data Scene:(int)scene {
    id obj = %orig(data, scene);
    if (data) WCZZLatestRedData = data;
    if (obj && data) objc_setAssociatedObject(obj, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLog(@"red receive init scene=%d data=%p obj=%p", scene, data, obj);
    return obj;
}
- (id)initWithData:(id)data {
    id obj = %orig(data);
    if (data) WCZZLatestRedData = data;
    if (obj && data) objc_setAssociatedObject(obj, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLog(@"red receive init data=%p obj=%p", data, obj);
    return obj;
}
- (void)showDetailView {
    %orig;
    id data = WCZZResolveRedData(self);
    if (!data) data = WCZZLatestRedData;
    WCZZLog(@"red receive showDetailView data=%p", data);
}
%end

%hook WCRedEnvelopesRedEnvelopesDetailViewController
- (id)init {
    id obj = %orig;
    id data = WCZZLatestRedData;
    if (obj && data) objc_setAssociatedObject(obj, WCZZRedDataKey, data, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    WCZZLog(@"red detail init vc=%p data=%p", obj, data);
    return obj;
}
- (void)viewDidLoad {
    %orig;
    id data = WCZZResolveRedData(self);
    WCZZLog(@"red detail viewDidLoad data=%p", data);
    if (data) WCZZScheduleRedSummary(self, data);
    WCZZLayoutRedSummaryLabel(self);
}
- (void)viewDidLayoutSubviews {
    %orig;
    WCZZLayoutRedSummaryLabel(self);
}
- (void)refreshViewWithData:(id)data {
    %orig(data);
    WCZZLog(@"red refreshViewWithData data=%p", data);
    if (data) WCZZScheduleRedSummary(self, data);
}
- (void)viewWillAppear:(BOOL)animated {
    %orig(animated);
    id data = WCZZResolveRedData(self);
    WCZZLog(@"red detail viewWillAppear data=%p", data);
    if (data) WCZZScheduleRedSummary(self, data);
}
- (void)viewDidAppear:(BOOL)animated {
    %orig(animated);
    id data = WCZZResolveRedData(self);
    WCZZLog(@"red detail viewDidAppear data=%p", data);
    if (data) WCZZScheduleRedSummary(self, data);
}
%end

%end

#pragma mark - Delayed hook installation

static BOOL WCZZRedHooksStarted = NO;
static NSInteger WCZZInstallAttempts = 0;

static void WCZZInstallRedHooksWhenReady(void);

static void WCZZScheduleInstallRetry(void) {
    if (WCZZInstallAttempts >= 40) return;
    WCZZInstallAttempts++;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.50 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WCZZInstallRedHooksWhenReady();
    });
}

static void WCZZInstallRedHooksWhenReady(void) {
    if (WCZZRedHooksStarted) return;

    if (objc_getClass("WCRedEnvelopesControlLogic") &&
        objc_getClass("WCRedEnvelopesReceiveControlLogic") &&
        objc_getClass("WCRedEnvelopesRedEnvelopesDetailViewController")) {
        %init(WCZZRedHooks);
        WCZZRedHooksStarted = YES;
        WCZZLog(@"red hooks installed");
        return;
    }
    WCZZScheduleInstallRetry();
}

%ctor {
    @autoreleasepool {
        // These three classes are normally registered by the time tweaks load, so
        // install immediately; the retry loop only covers the late-load case.
        if ([NSThread isMainThread]) {
            WCZZInstallRedHooksWhenReady();
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ WCZZInstallRedHooksWhenReady(); });
        }
    }
}
