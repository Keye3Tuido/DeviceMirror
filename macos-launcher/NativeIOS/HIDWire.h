// SPDX-License-Identifier: MIT
// Adapted from ipb (Copyright 2026 Borealin and ipbtools contributors) and
// idb (Copyright Meta Platforms, Inc. and affiliates.). See third_party/ios-control.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <xpc/xpc.h>
#import <mach/mach_time.h>
#include <math.h>

static inline CGPoint DMNativePoint(CGPoint p, NSInteger orientation) {
    switch (orientation) {
        case 2: return CGPointMake(1-p.x, 1-p.y);
        case 3: return CGPointMake(p.y, 1-p.x);
        case 4: return CGPointMake(1-p.y, p.x);
        default: return p;
    }
}
static inline NSData *DMTouchReport(double x, double y, BOOL down, NSInteger edgeQuarter) {
    uint8_t b[58] = {9,1,1,0};
    b[3] = down ? 0xc0 : 0;
    uint16_t px = (uint16_t)(fmin(1, fmax(0,x))*65535), py = (uint16_t)(fmin(1, fmax(0,y))*65535);
    b[4]=px&255; b[5]=px>>8; b[6]=py&255; b[7]=py>>8;
    if (edgeQuarter >= 0 && edgeQuarter < 4) {
        b[2]=5; b[3]|=2; b[40]=2;
        uint64_t time = mach_absolute_time();
        for (int i=0; i<6; i++) b[45+i]=(time>>(8*i))&255;
        const int directions[4]={434,444,439,449};
        b[429/8] |= 1<<(429%8); int bit=directions[edgeQuarter]; b[bit/8] |= 1<<(bit%8);
    }
    return [NSData dataWithBytes:b length:sizeof b];
}
static inline xpc_object_t DMEnvelope(const char *type, const char *feature, xpc_object_t payload) {
    xpc_object_t m=xpc_dictionary_create_empty();
    xpc_dictionary_set_string(m,"messageType",type);
    xpc_dictionary_set_bool(m,"isBarrier",false);
    xpc_dictionary_set_string(m,"featureIdentifier",feature);
    xpc_dictionary_set_value(m,"payload",payload);
    return m;
}
static inline xpc_object_t DMDigitizerMessage(double x, double y, uint64_t phase, uint64_t edge) {
    xpc_object_t p=xpc_dictionary_create_empty(), point=xpc_dictionary_create_empty();
    xpc_dictionary_set_double(point,"x",x); xpc_dictionary_set_double(point,"y",y);
    xpc_dictionary_set_value(p,"pointOne",point); xpc_dictionary_set_uint64(p,"eventType",phase);
    xpc_dictionary_set_uint64(p,"edge",edge); xpc_dictionary_set_uint64(p,"target",0);
    return DMEnvelope("IndigoDigitizerEvent","com.apple.coredevice.feature.remote.hid.digitizer",p);
}
static inline xpc_object_t DMButtonMessage(uint64_t page, uint64_t usage, uint64_t state) {
    xpc_object_t p=xpc_dictionary_create_empty();
    xpc_dictionary_set_uint64(p,"usagePage",page); xpc_dictionary_set_uint64(p,"usageCode",usage);
    xpc_dictionary_set_uint64(p,"state",state);
    return DMEnvelope("IndigoButtonEvent","com.apple.coredevice.feature.remote.hid.button",p);
}
static inline xpc_object_t DMReportMessage(NSData *data) {
    xpc_object_t send=xpc_dictionary_create_empty(), p=xpc_dictionary_create_empty();
    xpc_dictionary_set_data(send,"_0",data.bytes,data.length); xpc_dictionary_set_uint64(send,"_1",0x101);
    xpc_dictionary_set_value(p,"send",send);
    return DMEnvelope("Request","com.apple.coredevice.feature.remote.universalhidservice",p);
}
