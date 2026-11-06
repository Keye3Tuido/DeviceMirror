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

@interface DMDeviceToolbar : NSObject <NSToolbarDelegate>
@property(nonatomic, assign) struct sc_controller *controller;
@property(nonatomic, weak) NSWindow *window;
@property(nonatomic, strong) NSToolbar *toolbar;
@property(nonatomic, strong) NSTitlebarAccessoryViewController *inputAccessory;
@property(nonatomic, strong) NSTextField *input;
@property(nonatomic, strong) NSMenuItem *editMenu;
@end

@implementation DMDeviceToolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    (void) toolbar;
    return @[@"back", @"home", @"recents", NSToolbarFlexibleSpaceItemIdentifier,
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

- (void)press:(NSToolbarItem *)sender {
    if (sender.tag < 0) {
        struct sc_control_msg msg = {0};
        msg.type = SC_CONTROL_MSG_TYPE_EXPAND_NOTIFICATION_PANEL;
        if (!sc_controller_push_msg(self.controller, &msg)) {
            LOGW("Device Mirror: notification command rejected");
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
    const char *text = self.input.stringValue.UTF8String;
    if (!text || !*text) { return; }
    if (strlen(text) > SC_CONTROL_MSG_CLIPBOARD_TEXT_MAX_LENGTH) {
        NSBeep();
        self.input.toolTip = @"文字过长，请分段发送";
        return;
    }
    struct sc_control_msg msg = {0};
    msg.type = SC_CONTROL_MSG_TYPE_SET_CLIPBOARD;
    msg.set_clipboard.sequence = SC_SEQUENCE_INVALID;
    msg.set_clipboard.text = strdup(text);
    msg.set_clipboard.paste = true;
    if (!msg.set_clipboard.text) { return; }
    if (!sc_controller_push_msg(self.controller, &msg)) {
        free(msg.set_clipboard.text);
        NSBeep();
        LOGW("Device Mirror: text command rejected");
        return;
    }
    self.input.stringValue = @"";
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
    self.input.toolTip = @"支持中文；发送将更新此设备剪贴板并粘贴到当前输入框";
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
    owner.window = native;
    owner.toolbar = [[NSToolbar alloc] initWithIdentifier:@"local.devicemirror.keys"];
    owner.toolbar.delegate = owner;
    owner.toolbar.displayMode = NSToolbarDisplayModeIconAndLabel;
    owner.toolbar.allowsUserCustomization = NO;
    native.toolbar = owner.toolbar;
    if (@available(macOS 11.0, *)) { native.toolbarStyle = NSWindowToolbarStyleExpanded; }
    [owner installInput];
    return (__bridge_retained void *) owner;
}

void
sc_device_toolbar_destroy(void *toolbar) {
    if (toolbar) {
        DMDeviceToolbar *owner = (__bridge_transfer DMDeviceToolbar *) toolbar;
        NSUInteger index = [owner.window.titlebarAccessoryViewControllers indexOfObject:owner.inputAccessory];
        if (index != NSNotFound) { [owner.window removeTitlebarAccessoryViewControllerAtIndex:index]; }
        owner.window.toolbar = nil;
        [NSApp.mainMenu removeItem:owner.editMenu];
        owner.toolbar.delegate = nil;
        owner.controller = NULL;
    }
}

bool
sc_device_toolbar_is_editing(void *toolbar) {
    if (!toolbar) { return false; }
    DMDeviceToolbar *owner = (__bridge DMDeviceToolbar *)toolbar;
    return owner.input.currentEditor != nil;
}
