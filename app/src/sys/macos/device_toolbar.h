/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Keye3Tuido
 */
#ifndef SC_DEVICE_TOOLBAR_H
#define SC_DEVICE_TOOLBAR_H

#include <SDL3/SDL.h>
struct sc_controller;

void *
sc_device_toolbar_create(SDL_Window *window, struct sc_controller *controller);

void
sc_device_toolbar_destroy(void *toolbar);

bool
sc_device_toolbar_is_editing(void *toolbar);

#endif
