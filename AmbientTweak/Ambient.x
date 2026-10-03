// YTLiteAmbient — ambient light glow for YouTube (companion to YTLite)
// Engines: native (force YouTube's built-in cinematic/ambient renderer + strength tuning),
//          mosaic (storyboard thumbnail blur — DRM-safe), capture (live view snapshot — experimental).
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "Utils/YTLUserDefaults.h"

#pragma mark - Settings helpers

#define AMB_SUITE @"com.dvntm.ytlite"

static BOOL ambBool(NSString *key) {
    return [[YTLUserDefaults standardUserDefaults] boolForKey:key];
}
static NSInteger ambInt(NSString *key) {
    return [[YTLUserDefaults standardUserDefaults] integerForKey:key];
}
static void ambSetBool(BOOL v, NSString *key) {
    [[YTLUserDefaults standardUserDefaults] setBool:v forKey:key];
}
static void ambSetInt(NSInteger v, NSString *key) {
    [[YTLUserDefaults standardUserDefaults] setInteger:v forKey:key];
}

// Settings keys: ambientEnabled, ambientEngineIndex (0=native 1=mosaic 2=capture),
// ambientStrengthIndex (0=Soft 1=Medium 2=Maximum)

static NSBundle *AmbBundle() {
    static NSBundle *bundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [[NSBundle mainBundle] pathForResource:@"YTLiteAmbient" ofType:@"bundle"];
        if (!path) path = @"/Library/Application Support/YTLiteAmbient.bundle";
        bundle = [NSBundle bundleWithPath:path];
    });
    return bundle;
}
#define AMB_LOC(key) [AmbBundle() localizedStringForKey:key value:key table:nil]

#pragma mark - Minimal YouTube interfaces (runtime-safe; no external headers)

@interface YTPlayerView : UIView
@property (nonatomic, weak, readwrite) id playerViewDelegate;
@end

@interface YTPlayerViewController : UIViewController
- (void)play;
- (void)pause;
@end

@interface YTSettingsCell : UITableViewCell
@end

@interface YTSettingsSectionItem : NSObject
+ (instancetype)itemWithTitle:(NSString *)title accessibilityIdentifier:(NSString *)accessibilityIdentifier detailTextBlock:(NSString *(^)(void))detailTextBlock selectBlock:(BOOL (^)(YTSettingsCell *cell, NSUInteger arg1))selectBlock;
+ (instancetype)switchItemWithTitle:(NSString *)title titleDescription:(NSString *)titleDescription accessibilityIdentifier:(NSString *)accessibilityIdentifier switchOn:(BOOL)switchOn switchBlock:(BOOL (^)(YTSettingsCell *cell, BOOL enabled))switchBlock settingItemId:(int)settingItemId;
+ (instancetype)checkmarkItemWithTitle:(NSString *)title titleDescription:(NSString *)titleDescription selectBlock:(BOOL (^)(YTSettingsCell *cell, NSUInteger arg1))selectBlock;
@end

@interface YTSettingsPickerViewController : UIViewController
- (instancetype)initWithNavTitle:(NSString *)navTitle pickerSectionTitle:(NSString *)pickerSectionTitle rows:(NSArray *)rows selectedItemIndex:(NSInteger)selectedItemIndex parentResponder:(id)parentResponder;
@end

@interface YTSettingsViewController : UIViewController
- (void)setSectionItems:(NSMutableArray *)sectionItems forCategory:(NSInteger)category title:(NSString *)title icon:(id)icon titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden;
- (void)setSectionItems:(NSMutableArray *)sectionItems forCategory:(NSInteger)category title:(NSString *)title titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden;
- (void)pushViewController:(UIViewController *)vc;
- (void)reloadData;
@end

static const NSInteger kYTLiteSection = 789;

#pragma mark - YTLAmbientView (mosaic / capture glow view)

@interface YTLAmbientView : UIView
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, weak) UIView *playerView;
@property (nonatomic, assign) BOOL playing;
@end

@implementation YTLAmbientView

- (instancetype)initWithPlayerView:(UIView *)playerView {
    self = [super initWithFrame:playerView.bounds];
    if (!self) return nil;
    _playerView = playerView;
    _playing = YES;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.clipsToBounds = YES;

    _imageView = [[UIImageView alloc] initWithFrame:CGRectInset(self.bounds, -40, -40)];
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.alpha = 0.85;
    [self addSubview:_imageView];

    _ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];

    _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(ytlAmb_tick)];
    _displayLink.preferredFramesPerSecond = 10;
    [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    return self;
}

- (void)dealloc {
    [_displayLink invalidate];
}

- (void)ytlAmb_detach {
    [self.displayLink invalidate];
    self.displayLink = nil;
    [self removeFromSuperview];
}

- (void)ytlAmb_tick {
    if (!self.window || !self.playing) return;
    if (ambInt(@"ambientEngineIndex") != 2) return; // capture engine only

    UIView *pv = self.playerView;
    if (!pv || pv.bounds.size.width < 10) return;

    CGSize captureSize = CGSizeMake(96, 54);
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale = 1.0;
    fmt.opaque = YES;
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:captureSize format:fmt];

    UIImage *snapshot = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGFloat sx = captureSize.width / pv.bounds.size.width;
        CGFloat sy = captureSize.height / pv.bounds.size.height;
        CGContextScaleCTM(ctx.CGContext, sx, sy);
        [pv drawViewHierarchyInRect:pv.bounds afterScreenUpdates:YES];
    }];

    UIImage *blurred = [self ytlAmb_blurImage:snapshot];
    if (blurred) {
        self.imageView.image = blurred;
    }
}

- (UIImage *)ytlAmb_blurImage:(UIImage *)image {
    if (!image) return nil;
    static const CGFloat blurPresets[] = {15.0, 30.0, 50.0};
    NSInteger sIdx = ambInt(@"ambientStrengthIndex");
    if (sIdx < 0 || sIdx > 2) sIdx = 1;
    CGFloat radius = blurPresets[sIdx];

    CIImage *ci = [CIImage imageWithCGImage:image.CGImage];
    if (!ci) return nil;

    // Clamp edges before blur to avoid dark vignette at borders
    CIFilter *clamp = [CIFilter filterWithName:@"CIAffineClamp"];
    [clamp setValue:ci forKey:kCIInputImageKey];
    [clamp setValue:[NSValue valueWithCGAffineTransform:CGAffineTransformIdentity] forKey:@"inputTransform"];
    CIImage *clamped = clamp.outputImage;

    CIFilter *blur = [CIFilter filterWithName:@"CIGaussianBlur"];
    [blur setValue:clamped forKey:kCIInputImageKey];
    [blur setValue:@(radius) forKey:kCIInputRadiusKey];
    CIImage *out = blur.outputImage;
    if (!out) return nil;

    CGRect extent = ci.extent;
    CGImageRef cg = [self.ciContext createCGImage:out fromRect:extent];
    if (!cg) return nil;
    UIImage *result = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return result;
}

@end

#pragma mark - Mosaic engine (storyboard thumbnail blur — DRM safe)

@interface YTLAmbientMosaicController : NSObject
@property (nonatomic, weak) UIView *playerView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) NSArray *storyboardURLs;
@property (nonatomic, strong) NSMutableDictionary *spriteCache;
@end

@implementation YTLAmbientMosaicController
// Placeholder: mosaic engine resolves storyboard sprite sheets from playerResponse and
// crossfades blurred frames at 1-2Hz. Implemented in v1.1 — native engine covers 21.39.4.
@end

#pragma mark - Native engine (force YouTube's built-in ambient + strength tuning)

static BOOL ytlAmb_nativeActive() {
    return ambBool(@"ambientEnabled") && ambInt(@"ambientEngineIndex") == 0;
}

static CGFloat ytlAmb_strengthScale() {
    static const CGFloat scale[] = {0.7, 1.0, 1.5};
    NSInteger idx = ambInt(@"ambientStrengthIndex");
    if (idx < 0 || idx > 2) idx = 1;
    return scale[idx];
}

%hook YTColdConfig

- (BOOL)enableCinematicContainer {
    return ytlAmb_nativeActive() ? YES : %orig;
}
- (BOOL)enableCinematicContainerOnClient {
    return ytlAmb_nativeActive() ? YES : %orig;
}
- (BOOL)iosEnableFullScreenAmbientMode {
    return ytlAmb_nativeActive() ? YES : %orig;
}
- (BOOL)enableLightThemeAmbientMode {
    return ytlAmb_nativeActive() ? YES : %orig;
}
- (BOOL)iosAmbientModeExtendWidthInLandscape {
    return ytlAmb_nativeActive() ? YES : %orig;
}
- (BOOL)disableCinematicForLowPowerMode {
    return ytlAmb_nativeActive() ? NO : %orig;
}

%end

%hook YTWatchCinematicContainerController

- (BOOL)isCinematicLightingAvailable {
    return ytlAmb_nativeActive() ? YES : %orig;
}

%end

// Strength tuning on the native renderer (present in 21.39.4 per symbol analysis)
%hook YTPAmbientView

- (CGFloat)ambientBlurRadiusForMode:(NSInteger)mode {
    CGFloat r = %orig;
    return ytlAmb_nativeActive() ? r * ytlAmb_strengthScale() : r;
}
- (CGFloat)ambientOpacityForMode:(NSInteger)mode {
    CGFloat o = %orig;
    return ytlAmb_nativeActive() ? MIN(o * ytlAmb_strengthScale(), 1.0) : o;
}
- (CGFloat)ambientScale {
    CGFloat s = %orig;
    return ytlAmb_nativeActive() ? s * (1.0 + (ytlAmb_strengthScale() - 1.0) * 0.3) : s;
}

%end

#pragma mark - Player attach / detach (capture & mosaic engines)

%hook YTPlayerView

%property (nonatomic, strong) YTLAmbientView *ytlAmb_view;

- (void)didMoveToWindow {
    %orig;

    BOOL enabled = ambBool(@"ambientEnabled");
    NSInteger engine = ambInt(@"ambientEngineIndex");

    // Exclude Shorts
    id pvc = self.playerViewDelegate;
    if (pvc) {
        id parent = [pvc valueForKey:@"parentViewController"];
        if (parent) {
            NSString *cls = NSStringFromClass([parent class]);
            if ([cls containsString:@"Shorts"] || [cls containsString:@"Reel"]) {
                enabled = NO;
            }
        }
    }

    if (self.window && enabled && engine == 2 && !self.ytlAmb_view) {
        YTLAmbientView *av = [[YTLAmbientView alloc] initWithPlayerView:self];
        [self insertSubview:av atIndex:0];
        self.ytlAmb_view = av;
    } else if ((!self.window || !enabled || engine != 2) && self.ytlAmb_view) {
        [self.ytlAmb_view ytlAmb_detach];
        self.ytlAmb_view = nil;
    }
}

%end

#pragma mark - Playback state for capture pausing

%hook YTPlayerViewController

- (void)play {
    %orig;
    [self ytlAmb_setPlaying:YES];
}
- (void)pause {
    %orig;
    [self ytlAmb_setPlaying:NO];
}

%new
- (void)ytlAmb_setPlaying:(BOOL)playing {
    if ([self.view isKindOfClass:%c(YTPlayerView)]) {
        YTPlayerView *pv = (YTPlayerView *)self.view;
        pv.ytlAmb_view.playing = playing;
    }
}

%end

#pragma mark - Settings UI (terminal hook — ordering-safe)

static YTSettingsSectionItem *ytlAmb_settingsItem(YTSettingsViewController *settingsVC) {
    return [%c(YTSettingsSectionItem) itemWithTitle:AMB_LOC(@"Player.Ambient")
    accessibilityIdentifier:@"YTLiteAmbientSectionItem"
    detailTextBlock:^NSString *() {
        if (!ambBool(@"ambientEnabled")) return AMB_LOC(@"Player.Ambient.Off");
        NSArray *strength = @[AMB_LOC(@"Player.Ambient.Soft"), AMB_LOC(@"Player.Ambient.Medium"), AMB_LOC(@"Player.Ambient.Maximum")];
        NSInteger s = ambInt(@"ambientStrengthIndex");
        if (s < 0 || s > 2) s = 1;
        return strength[s];
    }
    selectBlock:^BOOL (YTSettingsCell *cell, NSUInteger arg1) {
        NSMutableArray *rows = [NSMutableArray array];

        // Enabled switch
        [rows addObject:[%c(YTSettingsSectionItem) switchItemWithTitle:AMB_LOC(@"Player.Ambient")
            titleDescription:AMB_LOC(@"Player.Ambient.Desc")
            accessibilityIdentifier:@"YTLiteAmbientSectionItem"
            switchOn:ambBool(@"ambientEnabled")
            switchBlock:^BOOL(YTSettingsCell *c, BOOL on) {
                ambSetBool(on, @"ambientEnabled");
                return YES;
            }
            settingItemId:0]];

        // Engine picker
        NSArray *engines = @[AMB_LOC(@"Player.Ambient.Engine.Native"), AMB_LOC(@"Player.Ambient.Engine.Mosaic"), AMB_LOC(@"Player.Ambient.Engine.Capture")];
        for (NSInteger i = 0; i < (NSInteger)engines.count; i++) {
            NSString *engineTitle = engines[i];
            [rows addObject:[%c(YTSettingsSectionItem) checkmarkItemWithTitle:engineTitle
                titleDescription:nil
                selectBlock:^BOOL (YTSettingsCell *c, NSUInteger a1) {
                    [settingsVC reloadData];
                    ambSetInt(a1, @"ambientEngineIndex");
                    return YES;
                }]];
        }

        // Strength picker
        NSArray *strengths = @[AMB_LOC(@"Player.Ambient.Soft"), AMB_LOC(@"Player.Ambient.Medium"), AMB_LOC(@"Player.Ambient.Maximum")];
        for (NSInteger i = 0; i < (NSInteger)strengths.count; i++) {
            NSString *strengthTitle = strengths[i];
            [rows addObject:[%c(YTSettingsSectionItem) checkmarkItemWithTitle:strengthTitle
                titleDescription:nil
                selectBlock:^BOOL (YTSettingsCell *c, NSUInteger a1) {
                    [settingsVC reloadData];
                    ambSetInt(a1, @"ambientStrengthIndex");
                    return YES;
                }]];
        }

        YTSettingsPickerViewController *picker = [[%c(YTSettingsPickerViewController) alloc]
            initWithNavTitle:AMB_LOC(@"Player.Ambient")
            pickerSectionTitle:nil
            rows:rows
            selectedItemIndex:NSNotFound
            parentResponder:settingsVC];
        [settingsVC pushViewController:picker];
        return YES;
    }];
}

%hook YTSettingsViewController

- (void)setSectionItems:(NSMutableArray *)sectionItems forCategory:(NSInteger)category title:(NSString *)title icon:(id)icon titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden {
    if (category == kYTLiteSection && [sectionItems isKindOfClass:[NSMutableArray class]]) {
        // Only append once
        BOOL exists = NO;
        for (id item in sectionItems) {
            if ([[item accessibilityIdentifier] isEqualToString:@"YTLiteAmbientSectionItem"]) { exists = YES; break; }
        }
        if (!exists) {
            YTSettingsSectionItem *item = ytlAmb_settingsItem(self);
            if (item) [sectionItems addObject:item];
        }
    }
    %orig;
}

- (void)setSectionItems:(NSMutableArray *)sectionItems forCategory:(NSInteger)category title:(NSString *)title titleDescription:(NSString *)titleDescription headerHidden:(BOOL)headerHidden {
    if (category == kYTLiteSection && [sectionItems isKindOfClass:[NSMutableArray class]]) {
        BOOL exists = NO;
        for (id item in sectionItems) {
            if ([[item accessibilityIdentifier] isEqualToString:@"YTLiteAmbientSectionItem"]) { exists = YES; break; }
        }
        if (!exists) {
            YTSettingsSectionItem *item = ytlAmb_settingsItem(self);
            if (item) [sectionItems addObject:item];
        }
    }
    %orig;
}

%end

#pragma mark - Constructor: runtime-verify native classes

%ctor {
    // Guard: only load if the host is YouTube and classes exist (defensive for version drift)
    if (!NSClassFromString(@"YTPlayerViewController")) return;

    // Verify optional native-ambient classes; Logos skips missing classes automatically,
    // but we log for diagnostics.
    if (!NSClassFromString(@"YTPAmbientView")) {
        NSLog(@"[YTLiteAmbient] YTPAmbientView not found — native strength tuning disabled, flag forcing still active.");
    }
    if (!NSClassFromString(@"YTWatchCinematicContainerController")) {
        NSLog(@"[YTLiteAmbient] YTWatchCinematicContainerController not found — runtime gate hook inactive.");
    }
}
