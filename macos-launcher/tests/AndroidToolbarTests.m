/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Keye3Tuido
 */
#include "sys/macos/device_toolbar.m"

static struct sc_controller *last_controller;
static NSMutableArray<NSString *> *sentTexts;
static unsigned commands;
static NSMutableArray<NSDictionary *> *keyEvents;
static IMP realApplicationSendEvent;

static NSString *captureText(NSString *text) {
    @synchronized(sentTexts) { [sentTexts addObject:text]; }
    return nil;
}

static void waitForText(DMDeviceToolbar *owner) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:5];
    while (owner.pendingTexts && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    assert(!owner.pendingTexts);
}

// Hidden windows do not receive NSApplication's final native dispatch. Complete
// that last step explicitly, keeping SDL's real application hook in the path.
static void hiddenDispatch(id app, SEL selector, NSEvent *event) {
    ((void (*)(id, SEL, NSEvent *))realApplicationSendEvent)(app, selector, event);
    [event.window sendEvent:event];
}

static NSEvent *keyEvent(NSWindow *window, NSEventType type, NSString *text, unsigned short code) {
    return [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
        context:nil characters:text charactersIgnoringModifiers:text isARepeat:NO keyCode:code];
}

static void holdButton(DMHeldKeyButton *button, double duration, BOOL cancel, BOOL dragIntoMenu) {
    NSWindow *host = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 200, 40)
        styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    host.contentView = button;
    NSPoint point = [button convertPoint:NSMakePoint(NSMidX(button.bounds), NSMidY(button.bounds)) toView:nil];
    double start = NSProcessInfo.processInfo.systemUptime;
    NSEvent *down = [NSEvent mouseEventWithType:(dragIntoMenu ? NSEventTypeLeftMouseDragged : NSEventTypeLeftMouseDown) location:point modifierFlags:0
        timestamp:start windowNumber:host.windowNumber context:nil eventNumber:100 clickCount:1 pressure:1];
    NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp location:point modifierFlags:0
        timestamp:start+duration windowNumber:host.windowNumber context:nil eventNumber:101 clickCount:1 pressure:0];
    dispatch_group_t posted = dispatch_group_create();
    dispatch_group_async(posted, dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
        [NSThread sleepForTimeInterval:duration];
        [NSApp postEvent:up atStart:YES];
    });
    NSTimer *check = [NSTimer timerWithTimeInterval:0.02 repeats:NO block:^(NSTimer *timer) {
        (void)timer;
        assert(keyEvents.count == 1); // DOWN is sent while the mouse is still held.
        assert([keyEvents.lastObject[@"action"] intValue] == AKEY_EVENT_ACTION_DOWN);
    }];
    [NSRunLoop.mainRunLoop addTimer:check forMode:NSEventTrackingRunLoopMode];
    NSTimer *detach = nil;
    if (cancel) {
        detach = [NSTimer timerWithTimeInterval:0.2 repeats:NO block:^(NSTimer *timer) {
            (void)timer;
            [button removeFromSuperview]; // Closing a menu removes its view.
        }];
        [NSRunLoop.mainRunLoop addTimer:detach forMode:NSEventTrackingRunLoopMode];
    }
    if (dragIntoMenu) { [button mouseDragged:down]; }
    else { [button mouseDown:down]; }
    [check invalidate]; [detach invalidate];
    double elapsed = NSProcessInfo.processInfo.systemUptime-start;
    dispatch_group_wait(posted, DISPATCH_TIME_FOREVER);
    assert(elapsed >= (cancel ? 0.18 : duration-0.02));
    assert(keyEvents.count >= (!cancel && duration > 0.5 ? 3 : 2));
    if (cancel) { assert(keyEvents.count == 2); }
    assert([keyEvents[0][@"action"] intValue] == AKEY_EVENT_ACTION_DOWN);
    assert([keyEvents.lastObject[@"action"] intValue] == AKEY_EVENT_ACTION_UP);
    for (NSUInteger n = 1; n+1 < keyEvents.count; ++n) {
        assert([keyEvents[n][@"action"] intValue] == AKEY_EVENT_ACTION_DOWN);
        assert([keyEvents[n][@"repeat"] unsignedIntegerValue] == n);
    }
    [keyEvents removeAllObjects]; commands = 0;
    while ([NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp untilDate:NSDate.date
        inMode:NSEventTrackingRunLoopMode dequeue:YES]) {}
    assert(!host.visible && !button.trackingKey);
}

bool
sc_controller_push_msg(struct sc_controller *controller, const struct sc_control_msg *msg) {
    last_controller = controller;
    if (msg->type == SC_CONTROL_MSG_TYPE_DM_DIRECT_TEXT) {
        sc_device_toolbar_process_text(msg->dm_direct_text.owner, msg->dm_direct_text.text);
        free(msg->dm_direct_text.text);
        sc_device_toolbar_finish_text(msg->dm_direct_text.owner);
        return true;
    }
    ++commands;
    if (msg->type == SC_CONTROL_MSG_TYPE_ROTATE_DEVICE) { return true; }
    assert(msg->type == SC_CONTROL_MSG_TYPE_INJECT_KEYCODE);
    [keyEvents addObject:@{@"action": @(msg->inject_keycode.action), @"code": @(msg->inject_keycode.keycode),
                          @"repeat": @(msg->inject_keycode.repeat)}];
    return true;
}

int main(void) {
    @autoreleasepool {
        setenv("DEVICE_MIRROR_TOOLBAR", "1", 1);
        SDL_SetHint(SDL_HINT_MAC_BACKGROUND_APP, "1");
        assert(SDL_Init(SDL_INIT_VIDEO));
        [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
        struct sc_controller controllers[2] = {0};
        SDL_Window *windows[2];
        void *handles[2];
        DMDeviceToolbar *owners[2];
        for (int i = 0; i < 2; ++i) {
            windows[i] = SDL_CreateWindow("Toolbar test", 420, 700,
                                         SDL_WINDOW_HIDDEN | SDL_WINDOW_RESIZABLE);
            assert(windows[i]);
            handles[i] = sc_device_toolbar_create(windows[i], &controllers[i]);
            assert(handles[i]);
            owners[i] = (__bridge DMDeviceToolbar *) handles[i];
            assert([[owners[i] toolbarDefaultItemIdentifiers:owners[i].toolbar]
                    containsObject:@"send-text"]);
            NSToolbarItem *item = [owners[i] toolbar:owners[i].toolbar
                itemForItemIdentifier:@"send-text" willBeInsertedIntoToolbar:YES];
            assert([item.label isEqualToString:@"发送文本"]);
            assert(item.action == @selector(showTextInput:));
            assert(item.target == owners[i]);
            assert(item.visibilityPriority == NSToolbarItemVisibilityPriorityHigh);
            for (int width = 350; width <= 700; width += 350) {
                SDL_SetWindowSize(windows[i], width, 600);
                SDL_PumpEvents();
                [owners[i].window.contentView.superview layoutSubtreeIfNeeded];
                NSView *bar = owners[i].inputAccessory.view;
                assert(bar.fittingSize.height >= 42);
                assert(owners[i].input.frame.size.width >= 80);
                NSRect field = [owners[i].input convertRect:owners[i].input.bounds toView:bar];
                assert(NSContainsRect(bar.bounds, field));
                assert(!owners[i].input.hiddenOrHasHiddenAncestor);
                assert(!owners[i].window.visible);
            }
        }
        sentTexts = [NSMutableArray new];
        DMTextRunner = captureText;
        NSString *text = @"中文 English 😀";
        owners[0].input.stringValue = text;
        owners[1].input.stringValue = @"设备二的草稿";
        [owners[0] sendText:nil];
        waitForText(owners[0]);
        assert(sentTexts.count == 1 && [sentTexts[0] isEqualToString:text]);
        assert(commands == 0);
        assert(owners[0].input.stringValue.length == 0);
        assert([owners[1].input.stringValue isEqualToString:@"设备二的草稿"]);
        [owners[0] sendText:nil];
        assert(sentTexts.count == 1);
        [owners[1] sendText:nil];
        waitForText(owners[1]);
        assert(sentTexts.count == 2 && [sentTexts[1] isEqualToString:@"设备二的草稿"]);
        assert(commands == 0);

        // A button event must use its own position, not SDL's cached last motion.
        for (int i = 0; i < 2; ++i) {
            NSWindow *window = owners[i].window;
            for (int width = 350; width <= 700; width += 350) {
                SDL_SetWindowSize(windows[i], width, 600);
                SDL_PumpEvents();
                for (int n = 0; n < 3; ++n) {
                    NSPoint expected = NSMakePoint(width * (n + 1) / 4.0, 150 * (n + 1));
                    NSPoint nativePoint = [window.contentView convertPoint:NSMakePoint(expected.x, 600 - expected.y) toView:nil];
                    DMNativeEvent = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:nativePoint
                        modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber
                        context:nil eventNumber:1 clickCount:1 pressure:1];
                    SDL_Event click = {0};
                    click.type = SDL_EVENT_MOUSE_BUTTON_DOWN;
                    click.button.windowID = SDL_GetWindowID(windows[i]);
                    click.button.x = -999; click.button.y = -999;
                    assert(DMFilterEvent(NULL, &click));
                    assert(fabs(click.button.x - expected.x) < 0.01);
                    assert(fabs(click.button.y - expected.y) < 0.01);
                    DMNativeEvent = nil;
                }
            }
        }

        NSWindow *window = owners[0].window;
        [window.delegate windowDidBecomeKey:[NSNotification notificationWithName:NSWindowDidBecomeKeyNotification object:window]];
        assert(SDL_GetKeyboardFocus() == windows[0]);
        assert(SDL_StartTextInput(windows[0]));
        assert([window makeFirstResponder:owners[0].input]);
        SDL_FlushEvents(SDL_EVENT_KEY_DOWN, SDL_EVENT_TEXT_EDITING_CANDIDATES);
        realApplicationSendEvent = DMApplicationSendEvent;
        DMApplicationSendEvent = (IMP)hiddenDispatch;
        [NSApp sendEvent:keyEvent(window, NSEventTypeKeyDown, @"a", 0)];
        [NSApp sendEvent:keyEvent(window, NSEventTypeKeyUp, @"a", 0)];
        assert([owners[0].input.stringValue isEqualToString:@"a"]);
        assert(!SDL_TextInputActive(windows[0]));
        SDL_Event event;
        while (SDL_PollEvent(&event)) { assert(!DMKeyboardEvent(event.type)); }
        [window endEditingFor:nil];
        assert(SDL_StartTextInput(windows[0]));
        [NSApp sendEvent:keyEvent(window, NSEventTypeKeyDown, @"b", 11)];
        [NSApp sendEvent:keyEvent(window, NSEventTypeKeyUp, @"b", 11)];
        unsigned commits = 0, downs = 0, ups = 0;
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_EVENT_TEXT_INPUT) {
                assert(strcmp(event.text.text, "b") == 0); ++commits;
            } else if (event.type == SDL_EVENT_KEY_DOWN) { ++downs; }
            else if (event.type == SDL_EVENT_KEY_UP) { ++ups; }
        }
        assert(commits == 1 && downs == 1 && ups == 1);
        DMApplicationSendEvent = realApplicationSendEvent;
        [owners[1] sendKey:AKEYCODE_HOME];
        assert(commands == 2 && last_controller == &controllers[1]);
        keyEvents = [NSMutableArray new];
        commands = 0;
        // AppKit forwards overflow menu selections with NSMenuItem as sender.
        // Exercise its real dispatch, including keys hidden by a narrow window.
        for (int i = 0; i < 2; ++i) {
            SDL_SetWindowSize(windows[i], 350, 600);
            SDL_PumpEvents();
            for (NSToolbarItem *item in owners[i].toolbar.items) {
                if (item.tag <= 0) { continue; }
                NSMenuItem *menu = item.menuFormRepresentation;
                assert(menu);
                assert(menu.image && menu.image == item.image);
                assert([menu.view isKindOfClass:DMHeldKeyButton.class]);
                DMHeldKeyButton *menuButton = (DMHeldKeyButton *)menu.view;
                assert(menuButton.image && [menuButton.title isEqualToString:item.label]);
                assert(menuButton.press && menuButton.repeatPress && menuButton.releasePress);
                NSMenuItem *copiedMenu = [menu copy];
                DMHeldKeyButton *copiedButton = (DMHeldKeyButton *)copiedMenu.view;
                assert([copiedButton isKindOfClass:DMHeldKeyButton.class]);
                assert(copiedButton.press && copiedButton.repeatPress && copiedButton.releasePress);
                menuButton.press(); menuButton.repeatPress(); menuButton.releasePress();
                assert(keyEvents.count == 3);
                assert([keyEvents[0][@"code"] integerValue] == item.tag);
                assert([keyEvents[1][@"repeat"] intValue] == 1);
                assert([keyEvents[2][@"action"] intValue] == AKEY_EVENT_ACTION_UP);
                assert(last_controller == &controllers[i]);
                [keyEvents removeAllObjects]; commands = 0;
                assert([NSApp sendAction:menu.action to:menu.target from:menu]);
                assert(keyEvents.count == 2);
                assert([keyEvents[0][@"code"] integerValue] == item.tag);
                assert([keyEvents[0][@"action"] intValue] == AKEY_EVENT_ACTION_DOWN);
                assert([keyEvents[1][@"code"] integerValue] == item.tag);
                assert([keyEvents[1][@"action"] intValue] == AKEY_EVENT_ACTION_UP);
                assert(last_controller == &controllers[i]);
                [keyEvents removeAllObjects]; commands = 0;
                [(NSButton *)item.view performClick:nil];
                assert(keyEvents.count == 2);
                assert([keyEvents[0][@"code"] integerValue] == item.tag);
                [keyEvents removeAllObjects]; commands = 0;
                if ([item.itemIdentifier isEqualToString:@"volume-up"]) {
                    holdButton(menuButton, 0.7, NO, NO);
                    holdButton((DMHeldKeyButton *)item.view, 0.7, NO, NO);
                    holdButton(menuButton, 0.03, NO, NO);
                    holdButton(copiedButton, 0.7, NO, NO);
                    holdButton(menuButton, 0.7, YES, NO);
                    holdButton(copiedButton, 0.7, NO, YES);
                }
            }
            assert(!owners[i].window.visible);
        }
        for (int i = 0; i < 2; ++i) {
            NSToolbarItem *rotate = [owners[i] toolbar:owners[i].toolbar
                itemForItemIdentifier:@"rotate" willBeInsertedIntoToolbar:YES];
            assert([rotate.label isEqualToString:@"旋转"]);
            [owners[i] press:rotate];
            assert(last_controller == &controllers[i]);
        }
        assert(commands == 2);
        [owners[0] beginKey:AKEYCODE_VOLUME_UP];
        [owners[0] repeatKey]; [owners[0] repeatKey]; [owners[0] releaseKey];
        [owners[0] releaseKey]; // Cancellation and mouse release must not send duplicate UPs.
        assert(keyEvents.count == 4);
        assert([keyEvents[0][@"action"] intValue] == AKEY_EVENT_ACTION_DOWN);
        assert([keyEvents[1][@"repeat"] intValue] == 1 && [keyEvents[2][@"repeat"] intValue] == 2);
        assert([keyEvents[3][@"action"] intValue] == AKEY_EVENT_ACTION_UP);
        assert(last_controller == &controllers[0]);
        [owners[1] beginKey:AKEYCODE_BACK];
        [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResignKeyNotification object:owners[1].window];
        assert(owners[1].heldKey == nil && [keyEvents.lastObject[@"action"] intValue] == AKEY_EVENT_ACTION_UP);
        [owners[0] beginKey:AKEYCODE_HOME];
        for (int i = 0; i < 2; ++i) {
            sc_device_toolbar_destroy(handles[i]);
            SDL_DestroyWindow(windows[i]);
        }
        assert([keyEvents.lastObject[@"action"] intValue] == AKEY_EVENT_ACTION_UP);
        assert(NSApp.activationPolicy == NSApplicationActivationPolicyProhibited);
        assert(!NSApp.active);
        SDL_Quit();
        puts("PASS: Android 菜单图标/菜单复制/鼠标长按与取消/原生点击坐标/输入隔离/独立设备/无前台窗口");
    }
    return 0;
}
