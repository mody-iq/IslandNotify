#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <math.h>

@interface NCNotificationShortLookView : UIView
@end

static char kIsBannerKey;
static char kLastAnimKey;

static const CGFloat kNotchBottom = 30.0;
static const CFTimeInterval kTravel = 0.46;
static const CFTimeInterval kMorphStart = 0.34;
static const CFTimeInterval kReveal = 0.80;
static const CFTimeInterval kFadeStart = 0.84;
static const CFTimeInterval kFadeLen = 0.22;
static const CFTimeInterval kEnd = 1.10;

static inline CGFloat IN_Clamp01(CGFloat x) {
    return x < 0.0 ? 0.0 : (x > 1.0 ? 1.0 : x);
}

static inline CGFloat IN_Lerp(CGFloat a, CGFloat b, CGFloat t) {
    return a + (b - a) * t;
}

static inline CGFloat IN_Smooth(CGFloat x) {
    return x * x * (3.0 - 2.0 * x);
}

static inline CGFloat IN_EaseInOutCubic(CGFloat x) {
    if (x < 0.5) {
        return 4.0 * x * x * x;
    }
    CGFloat p = -2.0 * x + 2.0;
    return 1.0 - (p * p * p) / 2.0;
}

static CGFloat IN_Spring(CFTimeInterval m) {
    if (m <= 0.0) {
        return 0.0;
    }
    const CGFloat zeta = 0.82;
    const CGFloat omega = 13.0;
    CGFloat wd = omega * sqrt(1.0 - zeta * zeta);
    CGFloat decay = exp(-zeta * omega * m);
    return 1.0 - decay * (cos(wd * m) + (zeta * omega / wd) * sin(wd * m));
}

static NSString *IN_Chain(UIView *v) {
    NSMutableArray *names = [NSMutableArray array];
    UIView *p = v;
    int depth = 0;
    while (p && depth < 12) {
        [names addObject:NSStringFromClass([p class])];
        p = p.superview;
        depth++;
    }
    UIWindow *w = v.window;
    return [NSString stringWithFormat:@"window=%@ chain=%@",
            w ? NSStringFromClass([w class]) : @"nil",
            [names componentsJoinedByString:@" > "]];
}

static void IN_Log(NSString *line) {
    @try {
        NSString *path = @"/var/mobile/Documents/IslandNotify.log";
        NSString *entry = [line stringByAppendingString:@"\n"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [entry writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        [fh seekToEndOfFile];
        [fh writeData:[entry dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } @catch (NSException *e) {
    }
}

static BOOL IN_IsBannerView(UIView *v) {
    UIWindow *w = v.window;
    if (w) {
        NSString *wn = NSStringFromClass([w class]);
        if ([wn rangeOfString:@"Banner" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    UIView *p = v.superview;
    int depth = 0;
    while (p && depth < 30) {
        NSString *n = NSStringFromClass([p class]);
        if ([n rangeOfString:@"Banner" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
        p = p.superview;
        depth++;
    }
    return NO;
}

static CGRect IN_TargetRect(UIView *banner, UIView *overlay) {
    CGFloat W = CGRectGetWidth(overlay.bounds);
    CGRect r = [banner convertRect:banner.bounds toView:overlay];
    BOOL ok = (!CGRectIsNull(r) && !CGRectIsInfinite(r) &&
               r.size.width > 150.0 && r.size.width <= W + 1.0 &&
               r.size.height > 40.0 && r.size.height < 220.0 &&
               CGRectGetMinY(r) > 20.0 && CGRectGetMaxY(r) < 400.0);
    if (ok) {
        return r;
    }
    CGFloat w = MIN(W - 32.0, 396.0);
    return CGRectMake((W - w) / 2.0, 52.0, w, 80.0);
}

static UIBezierPath *IN_NeckPath(CGFloat cx, CGFloat topY, CGFloat botY, CGFloat hTop, CGFloat hMid) {
    CGFloat midY = topY + (botY - topY) * 0.5;
    CGFloat seg = midY - topY;
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(cx - hTop, topY)];
    [p addCurveToPoint:CGPointMake(cx - hMid, midY)
         controlPoint1:CGPointMake(cx - hTop, topY + seg * 0.6)
         controlPoint2:CGPointMake(cx - hMid, midY - seg * 0.5)];
    [p addLineToPoint:CGPointMake(cx - hMid, botY)];
    [p addLineToPoint:CGPointMake(cx + hMid, botY)];
    [p addLineToPoint:CGPointMake(cx + hMid, midY)];
    [p addCurveToPoint:CGPointMake(cx + hTop, topY)
         controlPoint1:CGPointMake(cx + hMid, midY - seg * 0.5)
         controlPoint2:CGPointMake(cx + hTop, topY + seg * 0.6)];
    [p closePath];
    return p;
}

@interface INDriver : NSObject
@property (nonatomic, weak) UIView *banner;
@property (nonatomic, strong) UIView *overlay;
@property (nonatomic, strong) CAGradientLayer *neckGradient;
@property (nonatomic, strong) CAShapeLayer *neckMask;
@property (nonatomic, strong) CAShapeLayer *bulb;
@property (nonatomic, strong) CADisplayLink *link;
@property (nonatomic, assign) CFTimeInterval startTime;
@property (nonatomic, assign) BOOL revealed;
@property (nonatomic, assign) BOOL finished;
@property (nonatomic, assign) BOOL dark;
@property (nonatomic, assign) BOOL loggedRect;
+ (BOOL)startForBanner:(UIView *)banner;
- (void)render:(CFTimeInterval)t;
- (void)tick:(CADisplayLink *)link;
- (void)finish;
@end

@implementation INDriver

+ (BOOL)startForBanner:(UIView *)banner {
    UIWindow *window = banner.window;
    if (!window) {
        return NO;
    }
    UIScreen *screen = [UIScreen mainScreen];
    CGRect rect = [window convertRect:screen.bounds fromCoordinateSpace:screen.coordinateSpace];
    if (CGRectGetWidth(rect) < 200.0 || CGRectGetHeight(rect) < 400.0) {
        rect = window.bounds;
    }
    if (CGRectGetWidth(rect) < 200.0 || CGRectGetWidth(rect) >= CGRectGetHeight(rect)) {
        return NO;
    }

    INDriver *d = [[INDriver alloc] init];
    d.banner = banner;
    d.dark = (window.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);

    UIView *ov = [[UIView alloc] initWithFrame:rect];
    ov.userInteractionEnabled = NO;
    ov.backgroundColor = [UIColor clearColor];
    ov.clipsToBounds = NO;

    CAShapeLayer *mask = [CAShapeLayer layer];
    mask.frame = ov.bounds;
    mask.fillColor = [UIColor blackColor].CGColor;

    CAGradientLayer *grad = [CAGradientLayer layer];
    grad.frame = ov.bounds;
    grad.startPoint = CGPointMake(0.5, 0.0);
    grad.endPoint = CGPointMake(0.5, 1.0);
    grad.mask = mask;

    CAShapeLayer *bulb = [CAShapeLayer layer];
    bulb.frame = ov.bounds;
    bulb.shadowColor = [UIColor blackColor].CGColor;
    bulb.shadowOffset = CGSizeMake(0.0, 8.0);
    bulb.shadowRadius = 16.0;
    bulb.shadowOpacity = 0.0;

    [ov.layer addSublayer:grad];
    [ov.layer addSublayer:bulb];

    d.overlay = ov;
    d.neckMask = mask;
    d.neckGradient = grad;
    d.bulb = bulb;
    d.startTime = CACurrentMediaTime();

    [window addSubview:ov];
    [d render:0.0];

    CADisplayLink *link = [CADisplayLink displayLinkWithTarget:d selector:@selector(tick:)];
    [link addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    d.link = link;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [d finish];
    });
    return YES;
}

- (void)render:(CFTimeInterval)t {
    UIView *banner = self.banner;
    UIView *ov = self.overlay;
    if (!banner || !ov) {
        return;
    }

    CGFloat W = CGRectGetWidth(ov.bounds);
    CGFloat H = CGRectGetHeight(ov.bounds);
    CGFloat cx = W / 2.0;
    CGFloat y0 = kNotchBottom;
    CGRect R = IN_TargetRect(banner, ov);
    CGFloat cyT = CGRectGetMidY(R);
    CGFloat dist = MAX(cyT - y0, 40.0);

    if (!self.loggedRect && t >= kMorphStart) {
        self.loggedRect = YES;
        static int rectLogCount = 0;
        if (rectLogCount < 4) {
            rectLogCount++;
            IN_Log([NSString stringWithFormat:@"TARGET x=%.1f y=%.1f w=%.1f h=%.1f",
                    R.origin.x, R.origin.y, R.size.width, R.size.height]);
        }
    }

    CGFloat x = IN_Clamp01((CGFloat)(t / kTravel));
    CGFloat pos = IN_EaseInOutCubic(x);
    CGFloat growth = IN_Smooth(IN_Clamp01(pos / 0.18));
    CGFloat pinch = IN_Smooth(IN_Clamp01((pos - 0.35) / 0.20));
    CGFloat retract = IN_Smooth(IN_Clamp01((pos - 0.50) / 0.30));

    CGFloat rb = IN_Lerp(6.0, 18.0, IN_Smooth(IN_Clamp01((CGFloat)(t / 0.30))));
    CGFloat by = y0 + dist * pos;
    CGFloat tw = 2.0 * rb;
    CGFloat th = 2.0 * rb + 14.0 * sin(M_PI * pos);
    CGFloat hTop = IN_Lerp(IN_Lerp(14.0, 34.0, growth), 6.0, retract);
    CGFloat hMid = 14.0 * growth * (1.0 - pinch);
    CGFloat neckBottom = IN_Lerp(by, y0 + 10.0, retract);
    BOOL neckVisible = (retract < 0.98);

    CGFloat sp = IN_Spring(t - kMorphStart);
    CGFloat w = MAX(IN_Lerp(tw, CGRectGetWidth(R), sp), 4.0);
    CGFloat h = MAX(IN_Lerp(th, CGRectGetHeight(R), sp), 4.0);
    CGFloat cxB = IN_Lerp(cx, CGRectGetMidX(R), sp);

    CGFloat f = IN_Smooth(IN_Clamp01((CGFloat)((t - 0.08) / 0.55)));
    CGFloat finalLum = self.dark ? 0.17 : 1.0;
    UIColor *color = [UIColor colorWithWhite:IN_Lerp(0.0, finalLum, f) alpha:1.0];

    CGRect br = CGRectMake(cxB - w / 2.0, by - h / 2.0, w, h);
    UIBezierPath *bulbPath = [UIBezierPath bezierPathWithRoundedRect:br
                                                        cornerRadius:MIN(MIN(w, h) / 2.0, 34.0)];

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    CGFloat topY = y0 - 6.0;
    if (neckVisible) {
        self.neckGradient.hidden = NO;
        self.neckMask.path = IN_NeckPath(cx, topY, neckBottom, hTop, hMid).CGPath;
        self.neckGradient.startPoint = CGPointMake(0.5, topY / H);
        self.neckGradient.endPoint = CGPointMake(0.5, MAX(neckBottom, topY + 1.0) / H);
        self.neckGradient.colors = @[(id)[UIColor blackColor].CGColor, (id)color.CGColor];
    } else {
        self.neckGradient.hidden = YES;
    }

    self.bulb.path = bulbPath.CGPath;
    self.bulb.fillColor = color.CGColor;
    self.bulb.shadowPath = bulbPath.CGPath;
    self.bulb.shadowOpacity = (float)(0.20 * IN_Smooth(IN_Clamp01((CGFloat)((t - 0.34) / 0.30))));

    [CATransaction commit];
}

- (void)tick:(CADisplayLink *)link {
    if (self.finished) {
        return;
    }
    UIView *banner = self.banner;
    if (!banner || !banner.window) {
        [self finish];
        return;
    }
    CFTimeInterval t = CACurrentMediaTime() - self.startTime;
    [self render:t];

    if (!self.revealed && t >= kReveal) {
        self.revealed = YES;
        [UIView animateWithDuration:0.22
                              delay:0.0
                            options:(UIViewAnimationOptionCurveEaseOut | UIViewAnimationOptionAllowUserInteraction)
                         animations:^{
            banner.alpha = 1.0;
        } completion:nil];
    }
    if (t >= kFadeStart) {
        self.overlay.alpha = 1.0 - IN_Clamp01((CGFloat)((t - kFadeStart) / kFadeLen));
    }
    if (t >= kEnd) {
        [self finish];
    }
}

- (void)finish {
    if (self.finished) {
        return;
    }
    self.finished = YES;
    [self.link invalidate];
    self.link = nil;
    [self.overlay removeFromSuperview];
    self.overlay = nil;
    UIView *banner = self.banner;
    if (banner && banner.alpha < 1.0) {
        banner.alpha = 1.0;
    }
}

@end

%group IslandHooks

%hook NCNotificationShortLookView

- (void)didMoveToWindow {
    %orig;
    if (!self.window) {
        return;
    }

    static int bannerLogCount = 0;
    static int otherLogCount = 0;

    if (!IN_IsBannerView(self)) {
        if (otherLogCount < 6) {
            otherLogCount++;
            IN_Log([@"OTHER " stringByAppendingString:IN_Chain(self)]);
        }
        return;
    }

    objc_setAssociatedObject(self, &kIsBannerKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    if (bannerLogCount < 6) {
        bannerLogCount++;
        IN_Log([@"BANNER " stringByAppendingString:IN_Chain(self)]);
    }

    NSNumber *last = objc_getAssociatedObject(self, &kLastAnimKey);
    CFTimeInterval now = CACurrentMediaTime();
    if (last && (now - [last doubleValue]) < 2.5) {
        return;
    }
    objc_setAssociatedObject(self, &kLastAnimKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    self.alpha = 0.0;
    if (![INDriver startForBanner:self]) {
        self.alpha = 1.0;
    }
}

- (void)layoutSubviews {
    %orig;
    NSNumber *flag = objc_getAssociatedObject(self, &kIsBannerKey);
    if (![flag boolValue]) {
        return;
    }
    CGFloat h = CGRectGetHeight(self.bounds);
    if (h < 1.0) {
        return;
    }
    CGFloat r = MIN(h / 2.0, 34.0);
    CALayer *l = self.layer;
    if (l.cornerRadius != r) {
        l.cornerRadius = r;
    }
    l.cornerCurve = kCACornerCurveContinuous;
    l.masksToBounds = YES;
}

%end

%end

%ctor {
    @autoreleasepool {
        if (![[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"]) {
            return;
        }
        if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){16, 0, 0}]) {
            return;
        }
        if (!objc_getClass("NCNotificationShortLookView")) {
            IN_Log(@"NCNotificationShortLookView not found, tweak inactive");
            return;
        }
        IN_Log([NSString stringWithFormat:@"IslandNotify v3 loaded on iOS %@",
                [[UIDevice currentDevice] systemVersion]]);
        %init(IslandHooks);
    }
}
