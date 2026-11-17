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
//   * unchanged refreshes skip string formatting and label relayout entirely
//   * the four counters are read straight from the instance (ivar offset + real
//     runtime type encoding) instead of KVC; KVC stays as the fallback path

#import "WeChatCompat.h"
#import "WeChatHeaders.h"

#import <objc/runtime.h>
#import <objc/message.h>

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#import <string.h>
#import <stddef.h>
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

// valueForKey: on a key the object does not have throws and unwinds, which is
// expensive on a per-appearance path. The answer is the same either way, so
// check first and skip the throw.
static BOOL WCZZObjectHasKey(id obj, NSString *key) {
    if (!obj || !key) return NO;
    if ([obj respondsToSelector:NSSelectorFromString(key)]) return YES;

    Class cls = object_getClass(obj);
    const char *name = key.UTF8String;
    if (!name) return NO;
    if (class_getInstanceVariable(cls, name)) return YES;

    size_t length = strlen(name);
    if (length + 2 > 64) return NO;
    char underscored[64];
    underscored[0] = '_';
    memcpy(underscored + 1, name, length + 1);
    return class_getInstanceVariable(cls, underscored) != NULL;
}

#pragma mark - Red envelope summary overlay

static const void *WCZZRedDataKey = &WCZZRedDataKey;
static const void *WCZZRedSummaryLabelKey = &WCZZRedSummaryLabelKey;
static const void *WCZZRedApplyTokenKey = &WCZZRedApplyTokenKey;
static const void *WCZZRedAppliedValueKey = &WCZZRedAppliedValueKey;

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

#pragma mark - Fast field reads

// The four counters are plain scalar ivars. Reading them straight out of the
// instance removes four KVC round-trips per refresh. Offsets are resolved once
// per class and the width comes from the real runtime type encoding, so even a
// future type change (long long -> int) still reads the right bytes. Anything
// unusual - missing ivar, object/struct typed field, dictionary model - falls
// back to KVC, so the values are always identical to the old code.

#define WCZZ_FIELD_COUNT 4

static NSString *const WCZZRedFieldKeys[WCZZ_FIELD_COUNT] = {
    @"m_lTotalAmount", @"m_lTotalNum", @"m_lRecAmount", @"m_lRecNum"
};
static const char *const WCZZRedFieldNames[WCZZ_FIELD_COUNT] = {
    "m_lTotalAmount", "m_lTotalNum", "m_lRecAmount", "m_lRecNum"
};

typedef struct {
    Class cls;
    ptrdiff_t offset[WCZZ_FIELD_COUNT];
    char encoding[WCZZ_FIELD_COUNT];   // 0 = unusable, use KVC
} WCZZRedFieldCache;

// A hand-rolled cache instead of NSMapTable: four slots cover the individual and
// group red packet model classes, lookups are a pointer compare, no allocation.
#define WCZZ_FIELD_CACHE_SLOTS 4

static WCZZRedFieldCache WCZZFieldCaches[WCZZ_FIELD_CACHE_SLOTS];
static int WCZZFieldCacheNext = 0;

static WCZZRedFieldCache *WCZZFieldsFor(id obj) {
    Class cls = object_getClass(obj);

    WCZZRedFieldCache *empty = NULL;
    for (int i = 0; i < WCZZ_FIELD_CACHE_SLOTS; i++) {
        if (WCZZFieldCaches[i].cls == cls) return &WCZZFieldCaches[i];
        if (!empty && WCZZFieldCaches[i].cls == Nil) empty = &WCZZFieldCaches[i];
    }

    WCZZRedFieldCache *slot = empty;
    if (!slot) {
        slot = &WCZZFieldCaches[WCZZFieldCacheNext];
        WCZZFieldCacheNext = (WCZZFieldCacheNext + 1) % WCZZ_FIELD_CACHE_SLOTS;
    }

    memset(slot, 0, sizeof(*slot));
    slot->cls = cls;

    for (int i = 0; i < WCZZ_FIELD_COUNT; i++) {
        Ivar ivar = class_getInstanceVariable(cls, WCZZRedFieldNames[i]);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || !type[0]) continue;
        slot->offset[i] = ivar_getOffset(ivar);
        slot->encoding[i] = type[0];
    }
    return slot;
}

static BOOL WCZZReadField(WCZZRedFieldCache *cache, id obj, int index, long long *out) {
    char encoding = cache->encoding[index];
    if (!encoding) return NO;

    const char *base = (const char *)(__bridge void *)obj + cache->offset[index];
    long long value;
    switch (encoding) {
        case 'q': value = *(const long long *)base; break;
        case 'Q': value = (long long)*(const unsigned long long *)base; break;
        case 'l': value = (long long)*(const long *)base; break;
        case 'L': value = (long long)*(const unsigned long *)base; break;
        case 'i': value = *(const int *)base; break;
        case 'I': value = (long long)*(const unsigned int *)base; break;
        case 's': value = *(const short *)base; break;
        case 'S': value = (long long)*(const unsigned short *)base; break;
        case 'c': case 'B': value = *(const signed char *)base; break;
        case 'C': value = (long long)*(const unsigned char *)base; break;
        default: return NO;   // object / struct / unhandled -> KVC
    }
    if (out) *out = value;
    return YES;
}

static long long WCZZRedField(WCZZRedFieldCache *cache, id info, int index) {
    long long value = 0;
    if (WCZZReadField(cache, info, index, &value)) return value;
    return WCZZLongLong(info, WCZZRedFieldKeys[index]);
}

// Same condition as the original: only bail out when the detail info itself is
// missing. A model that is still filling in is applied as-is (zeros), exactly
// like before.
static BOOL WCZZParseRedSummary(id data, WCZZRedSummary *out) {
    id info = WCZZRedDetailInfo(data);
    if (!info || !out) return NO;

    WCZZRedFieldCache *fields = WCZZFieldsFor(info);

    WCZZRedSummary summary;
    summary.totalAmount = MAX(0LL, WCZZRedField(fields, info, 0));
    summary.totalNum    = MAX(0LL, WCZZRedField(fields, info, 1));
    summary.recAmount   = MAX(0LL, WCZZRedField(fields, info, 2));
    summary.recNum      = MAX(0LL, WCZZRedField(fields, info, 3));
    *out = summary;

    return YES;
}

static NSString *WCZZRedSummaryText(WCZZRedSummary summary) {
    long long remainAmount = MAX(0LL, summary.totalAmount - summary.recAmount);
    long long remainNum    = MAX(0LL, summary.totalNum - summary.recNum);

    // This is a standalone overlay label. Never touch m_receivedInfoLable: that
    // one belongs to WeChat's sender/amount area ("小号发出的红包" / "0.01元").
    return [NSString stringWithFormat:@"总金额:%.2f元\n总个数:%lld个\n剩余:%lld个\n剩余:%.2f元",
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
    // Bolder than the original regular weight: monospaced digits + Medium.
    // Swap UIFontWeightMedium for UIFontWeightSemibold / UIFontWeightBold to go heavier.
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

    CGFloat width  = MIN(280.0, MAX(230.0, size.width * 0.68));
    CGFloat height = 102.0;

    CGRect frame = CGRectMake((size.width - width) * 0.5, WCZZRedSummaryTop, width, height);
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

    // Consecutive passes almost always see the same numbers. Compare the parsed
    // snapshot first so an unchanged refresh costs no string formatting and no
    // label relayout at all.
    if (label.text.length > 0) {
        NSValue *applied = objc_getAssociatedObject(vc, WCZZRedAppliedValueKey);
        if (applied && strcmp(applied.objCType, @encode(WCZZRedSummary)) == 0) {
            WCZZRedSummary previous;
            [applied getValue:&previous];
            if (memcmp(&previous, &summary, sizeof(summary)) == 0) {
                WCZZLayoutRedSummaryLabel(vc);
                return;
            }
        }
    }

    label.text = WCZZRedSummaryText(summary);
    objc_setAssociatedObject(vc, WCZZRedAppliedValueKey,
                             [NSValue valueWithBytes:&summary objCType:@encode(WCZZRedSummary)],
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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

    // Same cadence as the original: 6 passes, 0.15s apart (0 ~ 0.75s). Unchanged
    // passes are now nearly free thanks to the snapshot check in the apply step.
    static const double delays[] = { 0.00, 0.15, 0.30, 0.45, 0.60, 0.75 };
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
    if (!data && WCZZObjectHasKey(vc, @"m_data")) data = WCZZValue(vc, @"m_data");
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
