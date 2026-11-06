/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Keye3Tuido
 */
#ifndef SC_DEVICE_TOOLBAR_H
#define SC_DEVICE_TOOLBAR_H

#include <SDL3/SDL.h>
struct sc_controller;

typedef void (*sc_device_toolbar_frame_handler)(void *context, const SDL_Event *event);

// Refresh only video-frame events on the UI thread during AppKit tracking.
void
sc_device_toolbar_set_frame_handler(void *toolbar,
    sc_device_toolbar_frame_handler handler, void *context);

void *
sc_device_toolbar_create(SDL_Window *window, struct sc_controller *controller);

void
sc_device_toolbar_destroy(void *toolbar);

bool
sc_device_toolbar_send_text(struct sc_controller *controller, const char *text);

void
sc_device_toolbar_process_text(void *owner, const char *text);

void
sc_device_toolbar_finish_text(void *owner);

bool
sc_device_toolbar_is_editing(void *toolbar);

#endif
