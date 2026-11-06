/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Keye3Tuido
 * Device Mirror addition: per-window Android keys and text input.
 */
#include "device_toolbar.h"
#include "controller.h"
#include "util/log.h"
#undef MIN
#undef MAX
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

@interface DMHeldKeyButton : NSButton
@property(nonatomic, copy) void (^press)(void);
@property(nonatomic, copy) void (^repeatPress)(void);
@property(nonatomic, copy) void (^releasePress)(void);
@property(nonatomic, assign) BOOL trackingKey;
@end

@implementation DMHeldKeyButton
- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) { return; }
    self.trackingKey = YES;
    self.press();
    NSTimer *repeat = [NSTimer timerWithTimeInterval:0.08 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        self.repeatPress();
    }];
    repeat.fireDate = [NSDate dateWithTimeIntervalSinceNow:0.5];
    [NSRunLoop.mainRunLoop addTimer:repeat forMode:NSRunLoopCommonModes];
    @try { [super mouseDown:event]; }
    @finally { [repeat invalidate]; self.releasePress(); self.trackingKey = NO; }
}
@end

@interface DMDeviceToolbar : NSObject <NSToolbarDelegate>
@property(nonatomic, assign) struct sc_controller *controller;
@property(nonatomic, assign) SDL_Window *sdlWindow;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, strong) NSToolbar *toolbar;
@property(nonatomic, strong) NSTitlebarAccessoryViewController *inputAccessory;
@property(nonatomic, strong) NSTextField *input;
@property(nonatomic, strong) NSMenuItem *editMenu;
@property(nonatomic, assign) unsigned pendingTexts;
@property(nonatomic, strong) NSNumber *heldKey;
@property(nonatomic, assign) unsigned keyRepeat;
@property(nonatomic, strong) id resignObserver;
- (void)releaseKey;
- (void)beginKey:(enum android_keycode)keycode;
- (void)repeatKey;
@end

// SDL's application hook runs before AppKit dispatches to native controls.
// Keep the originating event until SDL has queued its converted events.
static const void *DMToolbarKey = &DMToolbarKey;
static NSEvent *DMNativeEvent;
static IMP DMApplicationSendEvent;
static IMP DMWindowSendEvent;
static SDL_EventFilter DMPreviousFilter;
static void *DMPreviousFilterData;
static unsigned DMWindowCount;
static NSHashTable<DMDeviceToolbar *> *DMOwners;

static bool DMKeyboardEvent(Uint32 type) {
    return type == SDL_EVENT_KEY_DOWN || type == SDL_EVENT_KEY_UP
        || type == SDL_EVENT_TEXT_INPUT || type == SDL_EVENT_TEXT_EDITING;
}

static bool DMEditing(DMDeviceToolbar *owner) {
    return owner.input.currentEditor != nil || owner.window.attachedSheet != nil;
}

static NSPoint DMContentPoint(DMDeviceToolbar *owner, NSPoint windowPoint) {
    NSView *view = owner.window.contentView;
    NSPoint point = [view convertPoint:windowPoint fromView:nil];
    int width, height;
    SDL_GetWindowSize(owner.sdlWindow, &width, &height);
    point.x = (point.x - NSMinX(view.bounds)) * width / NSWidth(view.bounds);
    point.y = (NSMaxY(view.bounds) - point.y) * height / NSHeight(view.bounds);
    return point;
}

static DMDeviceToolbar *DMEventOwner(NSEvent *event) {
    NSWindow *window = event.window.sheetParent ?: event.window;
    return objc_getAssociatedObject(window, DMToolbarKey);
}

static bool DMFilterEvent(void *unused, SDL_Event *event) {
    (void) unused;
    DMDeviceToolbar *owner = NSThread.isMainThread ? DMEventOwner(DMNativeEvent) : nil;
    if (owner) {
        if (DMKeyboardEvent(event->type) && DMEditing(owner)) { return false; }
        bool button = event->type == SDL_EVENT_MOUSE_BUTTON_DOWN
                   || event->type == SDL_EVENT_MOUSE_BUTTON_UP;
        bool motion = event->type == SDL_EVENT_MOUSE_MOTION;
        if ((button || motion) && event->button.windowID == SDL_GetWindowID(owner.sdlWindow)) {
            NSPoint location = DMNativeEvent.locationInWindow;
            if (motion) {
                // macOS 26 motion-event positions may be stale after a Space change.
                location = [owner.window convertPointFromScreen:NSEvent.mouseLocation];
            }
            NSPoint point = DMContentPoint(owner, location);
            if (button) { event->button.x = point.x; event->button.y = point.y; }
            else { event->motion.x = point.x; event->motion.y = point.y; }
        }
    }
    return !DMPreviousFilter || DMPreviousFilter(DMPreviousFilterData, event);
}

static void DMApplicationDispatch(id app, SEL selector, NSEvent *event) {
    DMDeviceToolbar *owner = DMEventOwner(event);
    NSEvent *previous = DMNativeEvent;
    DMNativeEvent = event;
    if (owner) {
        if (event.type == NSEventTypeLeftMouseDown && !owner.window.attachedSheet) {
            NSPoint point = [owner.window.contentView convertPoint:event.locationInWindow fromView:nil];
            if (NSPointInRect(point, owner.window.contentView.bounds)) {
                [owner.window endEditingFor:nil];
                if (!SDL_TextInputActive(owner.sdlWindow)) { SDL_StartTextInput(owner.sdlWindow); }
            }
        }
        BOOL editing = DMEditing(owner);
        if (!editing && (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp)
                && !SDL_TextInputActive(owner.sdlWindow)) { SDL_StartTextInput(owner.sdlWindow); }
        if (editing && SDL_TextInputActive(owner.sdlWindow)) {
            // A native editor must be the only input-context interpreter.
            SDL_StopTextInput(owner.sdlWindow);
        }
    }
    ((void (*)(id, SEL, NSEvent *)) DMApplicationSendEvent)(app, selector, event);
    DMNativeEvent = previous;
}

static void DMWindowDispatch(id window, SEL selector, NSEvent *event) {
    DMDeviceToolbar *owner = objc_getAssociatedObject(window, DMToolbarKey);
    if (owner && DMNativeEvent == event && !DMEditing(owner)
            && (event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp)) {
        // SDL already interpreted this key in the application hook. Dispatching
        // it through a second AppKit input context can commit the same text twice.
        return;
    }
    ((void (*)(id, SEL, NSEvent *)) DMWindowSendEvent)(window, selector, event);
}

static void DMInstallEventRouting(DMDeviceToolbar *owner) {
    if (!DMApplicationSendEvent) {
        Class original = object_getClass(NSApp);
        DMApplicationSendEvent = class_getMethodImplementation(original, @selector(sendEvent:));
        class_replaceMethod(original, @selector(sendEvent:), (IMP) DMApplicationDispatch, "v@:@");
        // Keep the window's KVO subclass intact: SDL observes native geometry.
        Class window = NSClassFromString(@"SDL3Window");
        DMWindowSendEvent = class_getMethodImplementation(window, @selector(sendEvent:));
        class_replaceMethod(window, @selector(sendEvent:), (IMP) DMWindowDispatch, "v@:@");
    }
    objc_setAssociatedObject(owner.window, DMToolbarKey, owner, OBJC_ASSOCIATION_ASSIGN);
    if (DMWindowCount++ == 0) {
        SDL_GetEventFilter(&DMPreviousFilter, &DMPreviousFilterData);
        SDL_SetEventFilter(DMFilterEvent, NULL);
    }
}

@implementation DMDeviceToolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    (void) toolbar;
    return @[@"back", @"home", @"recents", @"rotate", @"send-text", NSToolbarFlexibleSpaceItemIdentifier,
             @"volume-down", @"volume-up", @"power", @"notifications"];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [self toolbarDefaultItemIdentifiers:toolbar];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar
    itemForItemIdentifier:(NSToolbarItemIdentifier)identifier
 willBeInsertedIntoToolbar:(BOOL)flag {
    (void) toolbar; (void) flag;
    NSDictionary *items = @{
        @"back": @[@"返回", @"chevron.backward", @(AKEYCODE_BACK)],
        @"home": @[@"主页", @"house", @(AKEYCODE_HOME)],
        @"recents": @[@"最近任务", @"square.on.square", @(AKEYCODE_APP_SWITCH)],
        @"rotate": @[@"旋转", @"rotate.right", @(-2)],
        @"send-text": @[@"发送文本", @"text.bubble", @(0)],
        @"volume-down": @[@"音量减", @"speaker.minus", @(AKEYCODE_VOLUME_DOWN)],
        @"volume-up": @[@"音量加", @"speaker.plus", @(AKEYCODE_VOLUME_UP)],
        @"power": @[@"电源", @"power", @(AKEYCODE_POWER)],
        @"notifications": @[@"通知", @"bell", @(-1)]
    };
    NSArray *spec = items[identifier];
    if (!spec) { return nil; }
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:identifier];
    item.label = spec[0];
    item.paletteLabel = spec[0];
    item.toolTip = [NSString stringWithFormat:@"%@ · 仅控制此窗口的设备", spec[0]];
    item.image = [NSImage imageWithSystemSymbolName:spec[1] accessibilityDescription:spec[0]];
    item.tag = [spec[2] integerValue];
    item.target = self;
    item.action = @selector(press:);
    if (item.tag > 0) {
        DMHeldKeyButton *button = [[DMHeldKeyButton alloc] initWithFrame:NSMakeRect(0, 0, 32, 28)];
        button.image = item.image;
        button.bordered = NO;
        button.toolTip = [item.toolTip stringByAppendingString:@"；按住可长按"];
        button.accessibilityLabel = spec[0];
        button.tag = item.tag;
        button.target = self;
        button.action = @selector(keyClicked:);
        __weak DMDeviceToolbar *owner = self;
        NSInteger code = item.tag;
        button.press = ^{ [owner beginKey:(enum android_keycode)code]; };
        button.repeatPress = ^{ [owner repeatKey]; };
        button.releasePress = ^{ [owner releaseKey]; };
        item.view = button;
    }
    if ([identifier isEqualToString:@"send-text"]) {
        item.action = @selector(showTextInput:);
        item.visibilityPriority = NSToolbarItemVisibilityPriorityHigh;
        item.toolTip = @"向此设备当前输入框发送文本，支持中文";
    }
    return item;
}

- (void)sendKey:(enum android_keycode)keycode {
    struct sc_control_msg msg = {0};
    msg.type = SC_CONTROL_MSG_TYPE_INJECT_KEYCODE;
    msg.inject_keycode.keycode = keycode;
    msg.inject_keycode.action = AKEY_EVENT_ACTION_DOWN;
    if (!sc_controller_push_msg(self.controller, &msg)) {
        LOGW("Device Mirror: virtual key DOWN rejected");
        return;
    }
    msg.inject_keycode.action = AKEY_EVENT_ACTION_UP;
    if (!sc_controller_push_msg(self.controller, &msg)) {
        LOGW("Device Mirror: virtual key UP rejected");
    }
}

- (void)beginKey:(enum android_keycode)keycode {
    [self releaseKey];
    struct sc_control_msg msg = {0};
    msg.type = SC_CONTROL_MSG_TYPE_INJECT_KEYCODE;
    msg.inject_keycode.keycode = keycode;
    msg.inject_keycode.action = AKEY_EVENT_ACTION_DOWN;
    if (self.controller && sc_controller_push_msg(self.controller, &msg)) {
        self.heldKey = @(keycode);
        self.keyRepeat = 0;
    }
}

- (void)keyClicked:(DMHeldKeyButton *)button {
    if (!button.trackingKey) { [self sendKey:(enum android_keycode)button.tag]; }
}

- (void)repeatKey {
    if (!self.heldKey || !self.controller) { return; }
    struct sc_control_msg msg = {0};
    msg.type = SC_CONTROL_MSG_TYPE_INJECT_KEYCODE;
    msg.inject_keycode.keycode = self.heldKey.intValue;
    msg.inject_keycode.action = AKEY_EVENT_ACTION_DOWN;
    msg.inject_keycode.repeat = ++self.keyRepeat;
    if (!sc_controller_push_msg(self.controller, &msg)) { [self releaseKey]; }
}

- (void)releaseKey {
    if (!self.heldKey) { return; }
    struct sc_control_msg msg = {0};
    msg.type = SC_CONTROL_MSG_TYPE_INJECT_KEYCODE;
    msg.inject_keycode.keycode = self.heldKey.intValue;
    msg.inject_keycode.action = AKEY_EVENT_ACTION_UP;
    self.heldKey = nil;
    if (self.controller && !sc_controller_push_msg(self.controller, &msg)) {
        LOGW("Device Mirror: held key UP rejected");
    }
}

- (void)press:(NSToolbarItem *)sender {
    if (sender.tag < 0) {
        struct sc_control_msg msg = {0};
        msg.type = sender.tag == -2 ? SC_CONTROL_MSG_TYPE_ROTATE_DEVICE
                                  : SC_CONTROL_MSG_TYPE_EXPAND_NOTIFICATION_PANEL;
        if (!sc_controller_push_msg(self.controller, &msg)) {
            LOGW("Device Mirror: toolbar command rejected");
        }
        return;
    }
    [self sendKey:(enum android_keycode)sender.tag];
}

- (void)inputKey:(NSPopUpButton *)sender {
    NSInteger keycode = sender.selectedItem.tag;
    if (keycode >= 0) {
        [self sendKey:(enum android_keycode)keycode];
    }
    [sender selectItemAtIndex:0];
}

- (void)sendText:(id)sender {
    (void)sender;
    if (sc_device_toolbar_send_text(self.controller, self.input.stringValue.UTF8String)) {
        self.input.stringValue = @"";
    }
}

- (void)showTextInput:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"向此设备发送文本";
    alert.informativeText = @"先点击设备中的输入框，再输入或粘贴要发送的内容。发送时临时启用文本输入组件，完成后恢复原输入法。";
    [alert addButtonWithTitle:@"发送"];
    [alert addButtonWithTitle:@"取消"];
    NSTextField *field = [NSTextField textFieldWithString:self.input.stringValue];
    field.frame = NSMakeRect(0, 0, 360, 24);
    field.placeholderString = @"输入或粘贴文本，支持中文";
    field.accessibilityLabel = @"向此安卓设备发送文本";
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    __weak DMDeviceToolbar *weakSelf = self;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        DMDeviceToolbar *owner = weakSelf;
        if (!owner || !owner.controller) { return; }
        owner.input.stringValue = field.stringValue;
        if (response == NSAlertFirstButtonReturn) { [owner sendText:nil]; }
    }];
}

- (void)installInput {
    self.editMenu = [[NSMenuItem alloc] initWithTitle:@"编辑" action:nil keyEquivalent:@""];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"编辑"];
    NSArray *commands = @[@[@"撤销", @"undo:", @"z"], @[@"剪切", @"cut:", @"x"],
        @[@"复制", @"copy:", @"c"], @[@"粘贴", @"paste:", @"v"], @[@"全选", @"selectAll:", @"a"]];
    for (NSArray *command in commands) {
        [edit addItemWithTitle:command[0] action:NSSelectorFromString(command[1]) keyEquivalent:command[2]];
    }
    self.editMenu.submenu = edit;
    [NSApp.mainMenu insertItem:self.editMenu atIndex:MIN(1, NSApp.mainMenu.numberOfItems)];
    self.input = [NSTextField textFieldWithString:@""];
    self.input.placeholderString = @"先点设备输入框，再在此输入文字";
    self.input.toolTip = @"直接提交到当前输入框，支持中文和表情；保留设备剪贴板";
    self.input.accessibilityLabel = @"向此安卓设备发送内容";
    self.input.target = self;
    self.input.action = @selector(sendText:);
    [self.input setContentHuggingPriority:NSLayoutPriorityDefaultLow
                         forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSButton *send = [NSButton buttonWithTitle:@"发送" target:self action:@selector(sendText:)];
    NSPopUpButton *keys = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    keys.accessibilityLabel = @"向此安卓设备发送按键";
    NSArray *specs = @[@[@"按键", @(-1)], @[@"回车 Enter", @(AKEYCODE_ENTER)],
        @[@"退格 Backspace", @(AKEYCODE_DEL)], @[@"删除 Delete", @(AKEYCODE_FORWARD_DEL)],
        @[@"Tab", @(AKEYCODE_TAB)], @[@"Escape", @(AKEYCODE_ESCAPE)],
        @[@"↑ 上", @(AKEYCODE_DPAD_UP)], @[@"↓ 下", @(AKEYCODE_DPAD_DOWN)],
        @[@"← 左", @(AKEYCODE_DPAD_LEFT)], @[@"→ 右", @(AKEYCODE_DPAD_RIGHT)]];
    for (NSArray *spec in specs) {
        [keys addItemWithTitle:spec[0]];
        keys.lastItem.tag = [spec[1] integerValue];
    }
    keys.target = self;
    keys.action = @selector(inputKey:);
    NSButton *logs = [NSButton buttonWithTitle:@"日志" target:self action:@selector(openLog:)];
    logs.toolTip = @"打开此设备的运行日志；系统日志在设备列表中开启记录";
    NSStackView *row = [NSStackView stackViewWithViews:@[self.input, send, keys, logs]];
    row.spacing = 6;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 440, 42)];
    [container addSubview:row];
    NSLayoutConstraint *height = [container.heightAnchor constraintEqualToConstant:42];
    height.priority = NSLayoutPriorityDefaultHigh;
    height.active = YES;
    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [row.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [row.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [self.input.widthAnchor constraintGreaterThanOrEqualToConstant:80],
        [keys.widthAnchor constraintEqualToConstant:104]
    ]];
    self.inputAccessory = [NSTitlebarAccessoryViewController new];
    self.inputAccessory.view = container;
    self.inputAccessory.layoutAttribute = NSLayoutAttributeBottom;
    [self.window addTitlebarAccessoryViewController:self.inputAccessory];
}

- (void)openLog:(id)sender {
    (void)sender;
    const char *path = getenv("DEVICE_MIRROR_LOG_FILE");
    if (path && *path) {
        [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:@(path)]]];
    }
}
@end

void *
sc_device_toolbar_create(SDL_Window *window, struct sc_controller *controller) {
    if (!controller || !getenv("DEVICE_MIRROR_TOOLBAR")) {
        return NULL;
    }
    NSWindow *native = (__bridge NSWindow *) SDL_GetPointerProperty(
        SDL_GetWindowProperties(window), SDL_PROP_WINDOW_COCOA_WINDOW_POINTER, NULL);
    if (!native) { return NULL; }
    DMDeviceToolbar *owner = [DMDeviceToolbar new];
    owner.controller = controller;
    owner.sdlWindow = window;
    if (!DMOwners) { DMOwners = [NSHashTable weakObjectsHashTable]; }
    [DMOwners addObject:owner];
    owner.window = native;
    owner.toolbar = [[NSToolbar alloc] initWithIdentifier:@"local.devicemirror.keys"];
    owner.toolbar.delegate = owner;
    owner.toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
    owner.toolbar.allowsUserCustomization = NO;
    native.toolbar = owner.toolbar;
    if (@available(macOS 11.0, *)) { native.toolbarStyle = NSWindowToolbarStyleExpanded; }
    [owner installInput];
    DMInstallEventRouting(owner);
    __weak DMDeviceToolbar *weakOwner = owner;
    owner.resignObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResignKeyNotification
        object:native queue:nil usingBlock:^(NSNotification *note) { (void)note; [weakOwner releaseKey]; }];
    return (__bridge_retained void *) owner;
}

void
sc_device_toolbar_destroy(void *toolbar) {
    if (toolbar) {
        DMDeviceToolbar *owner = (__bridge_transfer DMDeviceToolbar *) toolbar;
        [owner releaseKey];
        [NSNotificationCenter.defaultCenter removeObserver:owner.resignObserver];
        objc_setAssociatedObject(owner.window, DMToolbarKey, nil, OBJC_ASSOCIATION_ASSIGN);
        if (--DMWindowCount == 0) { SDL_SetEventFilter(DMPreviousFilter, DMPreviousFilterData); }
        NSUInteger index = [owner.window.titlebarAccessoryViewControllers indexOfObject:owner.inputAccessory];
        if (index != NSNotFound) { [owner.window removeTitlebarAccessoryViewControllerAtIndex:index]; }
        owner.window.toolbar = nil;
        [NSApp.mainMenu removeItem:owner.editMenu];
        owner.toolbar.delegate = nil;
        [DMOwners removeObject:owner];
        owner.controller = NULL;
    }
}

bool
sc_device_toolbar_is_editing(void *toolbar) {
    if (!toolbar) { return false; }
    DMDeviceToolbar *owner = (__bridge DMDeviceToolbar *)toolbar;
    // SDL must not forward draft keystrokes from the text sheet to Android.
    return owner.input.currentEditor != nil || owner.window.attachedSheet != nil;
}

static NSString *DMRunTextHelper(NSString *text) {
    const char *helper = getenv("DEVICE_MIRROR_INPUT_HELPER");
    const char *adb = getenv("ADB");
    const char *serial = getenv("DEVICE_MIRROR_ANDROID_SERIAL");
    const char *apk = getenv("DEVICE_MIRROR_INPUT_APK");
    if (!helper || !adb || !serial || !apk) { return @"文本服务组件缺失，请重新打开完整应用。"; }
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@(helper)];
    task.arguments = @[@(adb), @(serial), @(apk)];
    NSPipe *input = [NSPipe pipe], *errors = [NSPipe pipe];
    task.standardInput = input;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = errors;
    NSError *error;
    if (![task launchAndReturnError:&error]) { return @"无法启动文本输入服务。"; }
    BOOL written = [input.fileHandleForWriting writeData:[text dataUsingEncoding:NSUTF8StringEncoding] error:&error];
    [input.fileHandleForWriting closeFile];
    NSData *message = [errors.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (!written || task.terminationStatus != 0) {
        return [[NSString alloc] initWithData:message encoding:NSUTF8StringEncoding] ?: @"文本发送失败，请检查 USB 连接。";
    }
    return nil;
}

static NSString *(*DMTextRunner)(NSString *) = DMRunTextHelper;

bool
sc_device_toolbar_send_text(struct sc_controller *controller, const char *text) {
    if (!text || !*text) { return false; }
    DMDeviceToolbar *owner = nil;
    for (DMDeviceToolbar *candidate in DMOwners) {
        if (candidate.controller == controller) { owner = candidate; break; }
    }
    if (!owner) { return false; }
    if (strlen(text) > 65536 || owner.pendingTexts >= 32) {
        owner.input.toolTip = @"文字过长或待发内容过多，请分段发送";
        NSBeep();
        return false;
    }
    NSString *payload = [NSString stringWithUTF8String:text];
    if (!payload) { return false; }
    struct sc_control_msg msg = {0};
    msg.type = SC_CONTROL_MSG_TYPE_DM_DIRECT_TEXT;
    msg.dm_direct_text.text = strdup(text);
    if (!msg.dm_direct_text.text) { return false; }
    msg.dm_direct_text.owner = (__bridge_retained void *)owner;
    msg.dm_direct_text.destroy_owner = sc_device_toolbar_finish_text;
    ++owner.pendingTexts;
    if (!sc_controller_push_msg(controller, &msg)) {
        free(msg.dm_direct_text.text);
        sc_device_toolbar_finish_text(msg.dm_direct_text.owner);
        return false;
    }
    return true;
}

void
sc_device_toolbar_process_text(void *opaque, const char *text) {
    @autoreleasepool {
        DMDeviceToolbar *owner = (__bridge DMDeviceToolbar *)opaque;
        NSString *payload = [NSString stringWithUTF8String:text];
        NSString *failure = DMTextRunner(payload);
        if (failure) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!owner.controller) { return; }
                if (!owner.input.stringValue.length) { owner.input.stringValue = payload; }
                NSAlert *alert = [NSAlert new];
                alert.messageText = @"文本发送未完成";
                alert.informativeText = failure;
                [alert addButtonWithTitle:@"好"];
                if (owner.window.visible && !owner.window.attachedSheet) {
                    [alert beginSheetModalForWindow:owner.window completionHandler:nil];
                }
                owner.input.toolTip = failure;
                LOGW("Device Mirror: direct text input failed");
            });
        }
    }
}

void
sc_device_toolbar_finish_text(void *opaque) {
    dispatch_async(dispatch_get_main_queue(), ^{
        DMDeviceToolbar *owner = (__bridge_transfer DMDeviceToolbar *)opaque;
        --owner.pendingTexts;
    });
}
