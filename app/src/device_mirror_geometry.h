/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Keye3Tuido
 */
#ifndef SC_DEVICE_MIRROR_GEOMETRY_H
#define SC_DEVICE_MIRROR_GEOMETRY_H

#include "coords.h"

static inline struct sc_point
sc_device_mirror_clamp(struct sc_point point, struct sc_size size) {
    if (point.x < 0) { point.x = 0; }
    if (point.y < 0) { point.y = 0; }
    if (point.x >= size.width) { point.x = size.width - 1; }
    if (point.y >= size.height) { point.y = size.height - 1; }
    return point;
}

#endif
