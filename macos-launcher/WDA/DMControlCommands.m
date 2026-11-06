// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
#import "FBCommandHandler.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "FBXCTestDaemonsProxy.h"
#import "XCUIScreen.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIDevice+FBHelpers.h"
#import "FBKeyboard.h"
#import "XCUIApplication.h"
#import "XCUIDevice.h"
#import "XCSynthesizedEventRecord.h"
#import "XCPointerEventPath.h"
#import <math.h>

@interface DMControlCommands : NSObject <FBCommandHandler>
@end

@implementation DMControlCommands
+ (NSArray *)routes
{
  return @[
    [[FBRoute GET:@"/wda/devicemirror/info"].withoutSession respondWithTarget:self action:@selector(info:)],
    [[FBRoute POST:@"/wda/devicemirror/tap"] respondWithTarget:self action:@selector(tap:)],
    [[FBRoute POST:@"/wda/devicemirror/gesture"] respondWithTarget:self action:@selector(gesture:)],
    [[FBRoute POST:@"/wda/devicemirror/navigation"] respondWithTarget:self action:@selector(navigation:)],
  ];
}

+ (id<FBResponsePayload>)info:(FBRouteRequest *)request
{
  return FBResponseWithObject(@{@"token": NSProcessInfo.processInfo.environment[@"DEVICE_MIRROR_SESSION_TOKEN"] ?: @"",
    @"screenWidth": @(XCUIScreen.mainScreen.bounds.size.width), @"screenHeight": @(XCUIScreen.mainScreen.bounds.size.height)});
}

+ (id<FBResponsePayload>)tap:(FBRouteRequest *)request
{
  id x = request.arguments[@"x"], y = request.arguments[@"y"];
  if (![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class]
      || !isfinite([x doubleValue]) || !isfinite([y doubleValue])
      || [x doubleValue] < 0 || [x doubleValue] > 1 || [y doubleValue] < 0 || [y doubleValue] > 1) {
    return FBResponseWithUnknownErrorFormat(@"Expected normalized screen coordinates");
  }
  XCUIApplication *app = request.session.activeApplication;
  UIInterfaceOrientation orientation = app.interfaceOrientation;
  CGPoint point = [self screenPoint:CGPointMake([x doubleValue], [y doubleValue]) application:app orientation:orientation];
  XCPointerEventPath *path = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:0];
  [path liftUpAtOffset:0.035];
  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:@"Device Mirror click" interfaceOrientation:orientation];
  [record addPointerEventPath:path];
  NSError *error = nil;
  if (![FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:&error]) return FBResponseWithUnknownError(error);
  return FBResponseWithOK();
}

+ (CGPoint)screenPoint:(CGPoint)normalized application:(XCUIApplication *)app orientation:(UIInterfaceOrientation)orientation
{
  // Screen coordinates avoid resolving several accessibility coordinates for
  // every click. Orientation still comes from the foreground interface, so a
  // rotation-locked device is not mapped using its physical orientation.
  XCUIScreen *screen = XCUIScreen.mainScreen;
  CGSize native = CGSizeMake(screen.bounds.size.width / screen.scale, screen.bounds.size.height / screen.scale);
  CGFloat shortSide = MIN(native.width, native.height), longSide = MAX(native.width, native.height);
  CGSize size = UIInterfaceOrientationIsLandscape(orientation) ? CGSizeMake(longSide, shortSide) : CGSizeMake(shortSide, longSide);
  CGPoint point = CGPointMake(MIN(size.width - 1, normalized.x * size.width), MIN(size.height - 1, normalized.y * size.height));
  // XCTest rotates application coordinates for landscape and upside-down.
  // Resolve one coordinate in those orientations; portrait needs no AX lookup.
  if (orientation != UIInterfaceOrientationPortrait && orientation != UIInterfaceOrientationUnknown) {
    XCUICoordinate *origin = [app coordinateWithNormalizedOffset:CGVectorMake(0, 0)];
    point = [origin coordinateWithOffset:CGVectorMake(point.x, point.y)].screenPoint;
  }
  return point;
}

+ (id<FBResponsePayload>)gesture:(FBRouteRequest *)request
{
  NSArray *points = request.arguments[@"points"];
  if (![points isKindOfClass:NSArray.class] || points.count < 2 || points.count > 512) {
    return FBResponseWithUnknownErrorFormat(@"滑动需要 2 至 512 个轨迹点。");
  }
  double previousTime = -1;
  for (id sample in points) {
    if (![sample isKindOfClass:NSDictionary.class]) return FBResponseWithUnknownErrorFormat(@"Invalid touch sample");
    for (NSString *key in @[@"x", @"y", @"time"]) {
      id value = sample[key];
      if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) {
        return FBResponseWithUnknownErrorFormat(@"Invalid touch sample");
      }
    }
    double x = [sample[@"x"] doubleValue], y = [sample[@"y"] doubleValue], time = [sample[@"time"] doubleValue];
    if (x < 0 || x > 1 || y < 0 || y > 1 || time <= previousTime || time > 30 || (previousTime < 0 && time != 0)) {
      return FBResponseWithUnknownErrorFormat(@"轨迹坐标应在画面内，时间须从零递增且不超过 30 秒。");
    }
    previousTime = time;
  }
  NSError *error = nil;
  if (![self synthesizePath:points application:request.session.activeApplication
                      name:@"Device Mirror touch path" error:&error]) return FBResponseWithUnknownError(error);
  return FBResponseWithOK();
}

+ (BOOL)synthesizePath:(NSArray<NSDictionary *> *)points application:(XCUIApplication *)app
                  name:(NSString *)name error:(NSError **)error
{
  UIInterfaceOrientation orientation = app.interfaceOrientation;
  // Resolve the rotated coordinate basis once, rather than querying AX for
  // every sample. The touch record preserves the captured sample times.
  CGPoint origin = [self screenPoint:CGPointZero application:app orientation:orientation];
  CGPoint right = [self screenPoint:CGPointMake(1, 0) application:app orientation:orientation];
  CGPoint bottom = [self screenPoint:CGPointMake(0, 1) application:app orientation:orientation];
  XCPointerEventPath *path = nil;
  for (NSDictionary *sample in points) {
    CGFloat x = [sample[@"x"] doubleValue], y = [sample[@"y"] doubleValue];
    CGPoint point = CGPointMake(origin.x + x * (right.x - origin.x) + y * (bottom.x - origin.x),
                               origin.y + x * (right.y - origin.y) + y * (bottom.y - origin.y));
    if (path == nil) path = [[XCPointerEventPath alloc] initForTouchAtPoint:point offset:0];
    else [path moveToPoint:point atOffset:[sample[@"time"] doubleValue]];
  }
  [path liftUpAtOffset:[points.lastObject[@"time"] doubleValue] + 0.001];
  XCSynthesizedEventRecord *record = [[XCSynthesizedEventRecord alloc] initWithName:name interfaceOrientation:orientation];
  [record addPointerEventPath:path];
  return [FBXCTestDaemonsProxy synthesizeEventWithRecord:record error:error];
}

+ (id<FBResponsePayload>)navigation:(FBRouteRequest *)request
{
  NSString *action = request.arguments[@"action"];
  if ([action isEqual:@"back"]) {
    XCUIApplication *app = request.session.activeApplication;
    // UIKit's standard navigation Back button carries the accessibility Back
    // trait (bit 27), or the BackButton identifier used by newer system apps.
    // A leading button or a parent-page title alone is not enough: it may
    // represent Compose, Cancel or a menu.
    const unsigned long long backTrait = 1ULL << 27;
    for (XCUIElement *bar in app.navigationBars.allElementsBoundByIndex.reverseObjectEnumerator) {
      for (XCUIElement *button in bar.buttons.allElementsBoundByIndex) {
        id<FBXCElementSnapshot> snapshot = button.fb_standardSnapshot;
        if ((snapshot.traits & backTrait) == 0 && ![snapshot.identifier isEqualToString:@"BackButton"]) continue;
        if (!button.enabled || !button.hittable) continue;
        [button tap];
        return FBResponseWithObject(@{@"method": @"navigationButton"});
      }
    }
    // Web views and custom screens may expose Back outside a navigation bar.
    // Require an explicit Back label/identifier; never infer it from position.
    NSArray *backNames = @[@"back", @"go back", @"navigate back", @"backbutton", @"back-button", @"back_button",
      @"返回", @"后退", @"上一页", @"返回上一页", @"返回按钮", @"返回上一頁", @"上一頁"];
    NSMutableArray<NSPredicate *> *names = [NSMutableArray array];
    for (NSString *name in backNames) {
      [names addObject:[NSPredicate predicateWithFormat:@"label ==[c] %@ OR identifier ==[c] %@", name, name]];
    }
    NSPredicate *predicate = [NSCompoundPredicate orPredicateWithSubpredicates:names];
    NSArray<XCUIElement *> *candidates = [[app descendantsMatchingType:XCUIElementTypeButton] matchingPredicate:predicate].allElementsBoundByIndex;
    NSMutableArray<XCUIElement *> *available = [NSMutableArray array];
    for (XCUIElement *button in candidates) {
      if (button.enabled && button.hittable) [available addObject:button];
    }
    if (available.count == 1) {
      [available.firstObject tap];
      return FBResponseWithObject(@{@"method": @"labeledBackButton"});
    }
    if (available.count > 1) {
      return FBResponseWithUnknownErrorFormat(@"当前页面有多个返回控件，请直接点击需要的那个。");
    }
    // At a navigation root, Back first dismisses a visible keyboard.
    if ([FBKeyboard waitUntilVisibleForApplication:app timeout:0 error:nil]) {
      NSError *error = nil;
      return [app fb_dismissKeyboardWithKeyNames:nil error:&error]
        ? FBResponseWithObject(@{@"method": @"dismissKeyboard"}) : FBResponseWithUnknownError(error);
    }
    XCUIApplication *system = [[XCUIApplication alloc] initWithBundleIdentifier:@"com.apple.springboard"];
    if (app.alerts.firstMatch.exists || system.alerts.firstMatch.exists) {
      return FBResponseWithUnknownErrorFormat(@"设备上有弹窗遮挡页面，请先处理弹窗，再执行返回。");
    }
    return FBResponseWithUnknownErrorFormat(@"当前页面未找到可用的返回控件或键盘（%@）。iOS 没有全局返回键；未标注的自定义返回控件请直接点击。", app.bundleID);
  }
  if ([action isEqual:@"home"]) {
    // Start at the bottom edge and release while moving upward. A pause at
    // the end would turn the system's Home gesture into the App Switcher.
    NSArray *points = @[
      @{@"x": @0.5, @"y": @1.0,  @"time": @0.0},
      @{@"x": @0.5, @"y": @0.9,  @"time": @0.04},
      @{@"x": @0.5, @"y": @0.62, @"time": @0.12},
      @{@"x": @0.5, @"y": @0.45, @"time": @0.20},
    ];
    NSError *error = nil;
    if (![self synthesizePath:points application:request.session.activeApplication
                        name:@"Device Mirror bottom-edge Home swipe" error:&error]) return FBResponseWithUnknownError(error);
    return FBResponseWithObject(@{@"method": @"bottomEdgeSwipe"});
  }
  if (![action isEqual:@"appSwitcher"]) return FBResponseWithUnknownErrorFormat(@"Unsupported navigation action");
  NSError *error = nil;
  // Apple vendor keyboard usage for the system App Switcher. A single device
  // event works independently of screen orientation, app geometry and Dock.
  // This explicit navigation command is independent of recorded mouse drags.
  if (![XCUIDevice.sharedDevice fb_performIOHIDEventWithPage:0xFF01 usage:0x10 duration:0.08 error:&error]) {
    return FBResponseWithUnknownError(error);
  }
  return FBResponseWithOK();
}
@end
