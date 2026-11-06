/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Keye3Tuido
 */
#include "sys/macos/device_toolbar.m"

static struct sc_controller *last_controller;
static char *last_text;
static unsigned commands;

bool
sc_controller_push_msg(struct sc_controller *controller,
                       const struct sc_control_msg *msg) {
    last_controller = controller;
    ++commands;
    assert(msg->type == SC_CONTROL_MSG_TYPE_SET_CLIPBOARD);
    assert(msg->set_clipboard.paste);
    free(last_text);
    last_text = strdup(msg->set_clipboard.text);
    free(msg->set_clipboard.text);
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
        NSString *text = @"中文 English 😀";
        owners[0].input.stringValue = text;
        owners[1].input.stringValue = @"设备二的草稿";
        [owners[0] sendText:nil];
        assert(commands == 1 && last_controller == &controllers[0]);
        assert(strcmp(last_text, text.UTF8String) == 0);
        assert(owners[0].input.stringValue.length == 0);
        assert([owners[1].input.stringValue isEqualToString:@"设备二的草稿"]);
        [owners[0] sendText:nil];
        assert(commands == 1);
        [owners[1] sendText:nil];
        assert(commands == 2 && last_controller == &controllers[1]);
        assert(strcmp(last_text, "设备二的草稿") == 0);
        for (int i = 0; i < 2; ++i) {
            sc_device_toolbar_destroy(handles[i]);
            SDL_DestroyWindow(windows[i]);
        }
        free(last_text);
        assert(NSApp.activationPolicy == NSApplicationActivationPolicyProhibited);
        assert(!NSApp.active);
        SDL_Quit();
        puts("PASS: Android 文本入口/窄窗布局/中文与表情/独立设备发送/无前台窗口");
    }
    return 0;
}
