#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@interface NCNotificationShortLookView : UIView
@end

static char kIsBannerKey;
static char kLastAnimKey;

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

static void IN_Animate(UIView *v) {
    CALayer *layer = v.layer;
    CGFloat h = CGRectGetHeight(v.bounds);
    if (h < 1.0) {
        h = 90.0;
    }
    CGFloat s = 0.35;
    CGFloat ty = -h * (1.0 - s) / 2.0;
    CATransform3D from = CATransform3DConcat(CATransform3DMakeScale(s, s, 1.0),
                                             CATransform3DMakeTranslation(0.0, ty, 0.0));

    CASpringAnimation *spring = [CASpringAnimation animationWithKeyPath:@"transform"];
    spring.fromValue = [NSValue valueWithCATransform3D:from];
    spring.toValue = [NSValue valueWithCATransform3D:CATransform3DIdentity];
    spring.mass = 1.0;
    spring.stiffness = 220.0;
    spring.damping = 17.0;
    spring.initialVelocity = 0.0;
    spring.duration = spring.settlingDuration;
    spring.fillMode = kCAFillModeBackwards;
    [layer addAnimation:spring forKey:@"IslandNotify.transform"];

    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(0.0);
    fade.toValue = @(layer.opacity);
    fade.duration = 0.18;
    fade.fillMode = kCAFillModeBackwards;
    [layer addAnimation:fade forKey:@"IslandNotify.opacity"];
}

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
    if (last && (now - [last doubleValue]) < 1.0) {
        return;
    }
    objc_setAssociatedObject(self, &kLastAnimKey, @(now), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    IN_Animate(self);
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
        IN_Log([NSString stringWithFormat:@"IslandNotify loaded on iOS %@",
                [[UIDevice currentDevice] systemVersion]]);
        %init(IslandHooks);
    }
}
