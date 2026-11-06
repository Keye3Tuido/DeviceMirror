/* SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 Keye3Tuido
 */
#include <assert.h>
#include <stdio.h>
#include "../../app/src/device_mirror_geometry.h"

int main(void) {
    assert(sc_device_mirror_margin(848, 648) == 24);
    assert(sc_device_mirror_margin(40, 100) == 10);
    struct sc_size size = {800, 600};
    struct sc_point points[] = {{-10, -10}, {810, 610}, {400, 300}, {-1, 300}, {400, 600}};
    struct sc_point expected[] = {{0, 0}, {799, 599}, {400, 300}, {0, 300}, {400, 599}};
    for (unsigned i = 0; i < sizeof(points) / sizeof(*points); ++i) {
        struct sc_point result = sc_device_mirror_clamp(points[i], size);
        assert(result.x == expected[i].x && result.y == expected[i].y);
    }
    puts("PASS: Android 留白尺寸/边缘及角落坐标");
    return 0;
}
