// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
#import "FBCommandHandler.h"
#import "FBRouteRequest.h"
#import "FBSession.h"
#import "XCUIScreen.h"
#import "XCUIElement+FBUtilities.h"
#import "XCUIApplication+FBHelpers.h"
#import "XCUIDevice+FBHelpers.h"
#import "FBKeyboard.h"
#import "XCUIApplication.h"
#import "XCUIDevice.h"
#import <math.h>

@interface DMControlCommands : NSObject <FBCommandHandler>
@end

@implementation DMControlCommands
+ (NSArray *)routes
{
  return @[
    [[FBRoute GET:@"/wda/devicemirror/info"].withoutSession respondWithTarget:self action:@selector(info:)],
    [[FBRoute GET:@"/wda/devicemirror/display"] respondWithTarget:self action:@selector(display:)],
    [[FBRoute POST:@"/wda/devicemirror/navigation"] respondWithTarget:self action:@selector(navigation:)],
  ];
}

+ (id<FBResponsePayload>)info:(FBRouteRequest *)request
{
  return FBResponseWithObject(@{@"token": NSProcessInfo.processInfo.environment[@"DEVICE_MIRROR_SESSION_TOKEN"] ?: @"",
    @"screenWidth": @(XCUIScreen.mainScreen.bounds.size.width), @"screenHeight": @(XCUIScreen.mainScreen.bounds.size.height)});
}

+ (id<FBResponsePayload>)display:(FBRouteRequest *)request
{
  return FBResponseWithObject(@{@"orientation": @(request.session.activeApplication.interfaceOrientation)});
}

+ (id<FBResponsePayload>)backTarget:(XCUIElement *)button application:(XCUIApplication *)app method:(NSString *)method
{
  CGRect frame = button.frame;
  CGSize size = app.frame.size;
  if (CGRectIsEmpty(frame) || size.width <= 0 || size.height <= 0) {
    return FBResponseWithUnknownErrorFormat(@"无法读取返回控件的位置，请直接点击画面中的返回按钮。");
  }
  double x = CGRectGetMidX(frame) / size.width, y = CGRectGetMidY(frame) / size.height;
  if (!isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1) {
    return FBResponseWithUnknownErrorFormat(@"返回控件位于当前画面之外。");
  }
  return FBResponseWithObject(@{@"x": @(x), @"y": @(y), @"orientation": @(app.interfaceOrientation), @"method": method});
}

+ (id<FBResponsePayload>)navigation:(FBRouteRequest *)request
{
  NSString *action = request.arguments[@"action"];
  if (![action isEqual:@"back"] || ![request.arguments[@"resolveOnly"] isEqual:@YES]) {
    return FBResponseWithUnknownErrorFormat(@"控制需要 iOS / iPadOS 27 或以上的实时输入通道。");
  }
  {
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
        return [self backTarget:button application:app method:@"navigationButton"];
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
      return [self backTarget:available.firstObject application:app method:@"labeledBackButton"];
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
}
@end
