/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Keye3Tuido
 */
#include "controller.h"
#include "util/log.h"
#include <assert.h>
#include <stdatomic.h>
#include <string.h>
#include <SDL3/SDL.h>

static atomic_int phase, releases;
static int owner_token;

void sc_device_toolbar_process_text(void *owner, const char *text) {
    assert(owner == &owner_token && !strcmp(text, "中文😀"));
    assert(atomic_exchange(&phase, 1) == 0);
    SDL_Delay(60); // later keys are already queued while the IME is working
    assert(atomic_exchange(&phase, 2) == 1);
}
static void release_owner(void *owner) {
    assert(owner == &owner_token);
    atomic_fetch_add(&releases, 1);
}
ssize_t net_send_all(sc_socket socket, const void *data, size_t length) {
    (void)socket;
    const unsigned char *message = data;
    assert(message[0] == SC_CONTROL_MSG_TYPE_INJECT_KEYCODE && length == 14);
    assert(atomic_fetch_add(&phase, 1) >= 2);
    return length;
}
bool sc_receiver_init(struct sc_receiver *r, sc_socket s, const struct sc_receiver_callbacks *c, void *u) {
    (void)r; (void)s; (void)c; (void)u; return true;
}
void sc_receiver_destroy(struct sc_receiver *r) { (void)r; }
bool sc_receiver_start(struct sc_receiver *r) { (void)r; return true; }
void sc_receiver_join(struct sc_receiver *r) { (void)r; }
enum sc_log_level sc_get_log_level(void) { return SC_LOG_LEVEL_INFO; }
static void ended(struct sc_controller *controller, bool error, void *data) {
    (void)controller; (void)data; assert(!error);
}
int main(void) {
    assert(SDL_Init(0));
    struct sc_controller controller;
    struct sc_controller_callbacks callbacks = {.on_ended = ended};
    assert(sc_controller_init(&controller, SC_SOCKET_NONE, &callbacks, NULL));
    struct sc_control_msg text = {.type = SC_CONTROL_MSG_TYPE_DM_DIRECT_TEXT,
        .dm_direct_text = {.text = strdup("中文😀"), .owner = &owner_token, .destroy_owner = release_owner}};
    assert(sc_controller_push_msg(&controller, &text));
    struct sc_control_msg key = {.type = SC_CONTROL_MSG_TYPE_INJECT_KEYCODE,
        .inject_keycode = {.action = AKEY_EVENT_ACTION_DOWN, .keycode = AKEYCODE_ENTER}};
    assert(sc_controller_push_msg(&controller, &key));
    key.inject_keycode.action = AKEY_EVENT_ACTION_UP;
    assert(sc_controller_push_msg(&controller, &key));
    assert(sc_controller_start(&controller));
    for (int n = 0; n < 500 && atomic_load(&phase) < 4; ++n) { SDL_Delay(2); }
    assert(atomic_load(&phase) == 4 && atomic_load(&releases) == 1);
    sc_controller_stop(&controller);
    sc_controller_join(&controller);
    sc_controller_destroy(&controller);
    SDL_Quit();
    puts("PASS: Unicode 提交完成后再发送回车 DOWN/UP；本地文字不写入设备协议；队列所有权释放一次");
}
