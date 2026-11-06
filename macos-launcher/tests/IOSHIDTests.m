// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
#import <Foundation/Foundation.h>
#import "../NativeIOS/HIDWire.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    NSData *down = DMTouchReport(.5, .25, YES, -1);
    const uint8_t *b = down.bytes;
    assert(down.length == 58 && b[0] == 9 && b[1] == 1 && b[2] == 1 && b[3] == 0xc0);
    assert(b[4] == 0xff && b[5] == 0x7f && b[6] == 0xff && b[7] == 0x3f);
    b = DMTouchReport(.5, .25, NO, -1).bytes; assert(b[1] == 1 && b[3] == 0);
    NSData *edge = DMTouchReport(.5, 1, YES, 0); b = edge.bytes;
    assert(b[2] == 5 && b[3] == 0xc2 && b[40] == 2 && (b[53] & 0x20) && (b[54] & 0x04));
    CGPoint p = DMNativePoint(CGPointMake(.2, .3), 3); assert(fabs(p.x - .3) < 1e-6 && fabs(p.y - .8) < 1e-6);
    xpc_object_t m = DMDigitizerMessage(.2, .3, 1, 0);
    assert(xpc_get_type(xpc_dictionary_get_value(m,"isBarrier")) == XPC_TYPE_BOOL && !xpc_dictionary_get_bool(m,"isBarrier"));
    xpc_object_t payload = xpc_dictionary_get_value(m, "payload");
    assert(xpc_get_type(xpc_dictionary_get_value(payload,"eventType")) == XPC_TYPE_UINT64);
    assert(xpc_dictionary_get_uint64(payload,"eventType") == 1);
    assert(xpc_dictionary_get_double(xpc_dictionary_get_value(payload,"pointOne"),"x") == .2);
    xpc_object_t key = DMButtonMessage(12, 0x40, 2);
    payload = xpc_dictionary_get_value(key,"payload");
    assert(xpc_dictionary_get_uint64(payload,"state") == 2 && xpc_dictionary_get_uint64(payload,"usageCode") == 64);
    puts("PASS: HID report shape; release contact count; Home edge bits; orientation; typed XPC payloads");
} }
