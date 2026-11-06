// SPDX-License-Identifier: MIT
// CoreDevice service/media setup adapted from ipb, Copyright (c) 2026
// Borealin and ipbtools contributors. Simulator XPC setup adapted from idb,
// Copyright (c) Meta Platforms, Inc. and affiliates. License/provenance:
// third_party/ios-control. Device Mirror changes Copyright 2026 Keye3Tuido.
#import "HIDWire.h"
#import <objc/runtime.h>
#include <dlfcn.h>
#include <uuid/uuid.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <signal.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdbool.h>

typedef void *Remote;
static Remote (*remoteCreate)(int,dispatch_queue_t,uint64_t,uint64_t);
static void (*remoteHandler)(Remote,xpc_handler_t), (*remoteActivate)(Remote), (*remoteCancel)(Remote);
static void (*remoteSend)(Remote,xpc_object_t);
static void (*remoteReply)(Remote,xpc_object_t,dispatch_queue_t,xpc_handler_t);
static _Atomic bool closing=false, ready=false;
static NSString *deviceID, *coreVersion;
static NSTask *lease;
static int mediaFD=-1;
static dispatch_source_t mediaDrain, safetyTimer;
static NSMutableArray *signalSources;
static void cancelInputs(void);

@interface NSObject (DMPrivateRuntime)
+ (id)sharedServiceContextForDeveloperDir:(NSString *)path error:(NSError **)error;
- (id)defaultDeviceSetWithError:(NSError **)error;
- (NSArray *)availableDevices;
- (NSUUID *)UDID;
- (uint32_t)lookup:(NSString *)service error:(NSError **)error;
- (id)initWithMode:(long)mode options:(NSDictionary *)options error:(NSError **)error;
- (BOOL)createOffer;
- (NSData *)offer;
- (BOOL)setAnswer:(NSData *)answer withError:(NSError **)error;
@end

static void emit(NSDictionary *value) {
    NSData *d=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if(d) { fwrite(d.bytes,1,d.length,stdout); fputc('\n',stdout); fflush(stdout); }
}
static void fail(NSString *message) {
    emit(@{@"error":message ?: @"输入通道失败"});
    fprintf(stderr,"INPUT ERROR: %s\n",message.UTF8String);
    closing=YES;
    if(ready) { cancelInputs(); usleep(100000); }
    if(lease.running) [lease terminate];
    _Exit(1);
}
static NSString *run(NSString *path, NSArray *args) {
    NSTask *t=[NSTask new]; t.executableURL=[NSURL fileURLWithPath:path]; t.arguments=args;
    NSString *file=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [[NSFileManager defaultManager] createFileAtPath:file contents:nil attributes:@{NSFilePosixPermissions:@0600}];
    NSFileHandle *out=[NSFileHandle fileHandleForWritingAtPath:file];
    t.standardInput=NSFileHandle.fileHandleWithNullDevice; t.standardOutput=out; t.standardError=out;
    NSError *error=nil;
    if(![t launchAndReturnError:&error]) { [out closeFile]; [[NSFileManager defaultManager] removeItemAtPath:file error:nil]; fail(error.localizedDescription); }
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:18];
    while(t.running && deadline.timeIntervalSinceNow>0) [NSThread sleepForTimeInterval:.02];
    if(t.running) { [t terminate]; [NSThread sleepForTimeInterval:.1]; if(t.running) kill(t.processIdentifier,SIGKILL); }
    [t waitUntilExit]; [out closeFile];
    NSData *data=[NSData dataWithContentsOfFile:file]; [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
    NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    if(t.terminationStatus) fail([NSString stringWithFormat:@"设备查询失败：%@",text]);
    return text;
}
static NSDictionary *jsonCommand(NSArray *args) {
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    run(@"/usr/bin/xcrun",[args arrayByAddingObjectsFromArray:@[@"--json-output",path,@"--quiet"]]);
    NSData *data=[NSData dataWithContentsOfFile:path]; [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSDictionary *value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if(![value isKindOfClass:NSDictionary.class]) fail(@"无法读取设备系统版本。");
    return value;
}
static void requireVersion(NSString *version) {
    NSArray *parts=[version componentsSeparatedByString:@"."];
    NSCharacterSet *invalid=NSCharacterSet.decimalDigitCharacterSet.invertedSet;
    BOOL valid=version.length>0;
    for(NSString *p in parts) if(!p.length || [p rangeOfCharacterFromSet:invalid].location!=NSNotFound) valid=NO;
    if(!valid || [parts.firstObject integerValue]<27)
        fail([NSString stringWithFormat:@"%@不支持控制；需要 iOS / iPadOS 27 或以上。可使用观看镜像。",valid ? [@"当前系统 " stringByAppendingString:version] : @"无法确认系统版本，"]);
}
static void *symbol(const char *name) {
    void *p=dlsym(RTLD_DEFAULT,name);
    if(!p) fail([NSString stringWithFormat:@"当前 Xcode / macOS 缺少实时输入接口 %s，请安装 Xcode 27 或以上。",name]);
    return p;
}
static xpc_object_t action(const char *name, xpc_object_t input) {
    xpc_object_t m=xpc_dictionary_create_empty(), v=xpc_dictionary_create_empty(), c=xpc_array_create_empty();
    for(NSString *p in [coreVersion componentsSeparatedByString:@"."]) xpc_array_append_value(c,xpc_uint64_create(p.longLongValue));
    xpc_dictionary_set_value(v,"components",c);
    xpc_dictionary_set_int64(v,"originalComponentsCount",xpc_array_get_count(c));
    xpc_dictionary_set_string(v,"stringValue",coreVersion.UTF8String);
    xpc_dictionary_set_value(m,"CoreDevice.coreDeviceVersion",v);
    xpc_dictionary_set_string(m,"CoreDevice.actionIdentifier",name);
    xpc_dictionary_set_string(m,"CoreDevice.deviceIdentifier",deviceID.UTF8String);
    xpc_dictionary_set_string(m,"CoreDevice.invocationIdentifier",NSUUID.UUID.UUIDString.UTF8String);
    xpc_dictionary_set_int64(m,"CoreDevice.CoreDeviceDDIProtocolVersion",1);
    xpc_dictionary_set_value(m,"CoreDevice.input",input);
    return m;
}
static void checkReply(xpc_object_t reply) {
    if(!reply || xpc_get_type(reply)!=XPC_TYPE_DICTIONARY || xpc_dictionary_get_value(reply,"CoreDevice.error")) {
        char *d=reply?xpc_copy_description(reply):NULL;
        NSString *reason=[NSString stringWithFormat:@"设备拒绝实时输入连接：%s",d?:"empty reply"];
        free(d); fail(reason);
    }
}
@interface DMChannel : NSObject
@property Remote remote;
@property xpc_connection_t local;
- (void)send:(xpc_object_t)message;
- (xpc_object_t)request:(xpc_object_t)message;
- (void)cancel;
@end
@implementation DMChannel
- (void)send:(xpc_object_t)m {
    if(self.remote) remoteSend(self.remote,m);
    else {
        // The simulator multiplexes digitizer and button messages on this feature.
        xpc_dictionary_set_string(m,"featureIdentifier","com.apple.coredevice.feature.remote.hid.digitizer");
        xpc_connection_send_message(self.local,m);
    }
}
- (xpc_object_t)request:(xpc_object_t)m {
    dispatch_semaphore_t wait=dispatch_semaphore_create(0);
    __block xpc_object_t reply;
    xpc_handler_t done=^(xpc_object_t r){ reply=r; dispatch_semaphore_signal(wait); };
    dispatch_queue_t q=dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0);
    if(self.remote) remoteReply(self.remote,m,q,done); else xpc_connection_send_message_with_reply(self.local,m,q,done);
    if(dispatch_semaphore_wait(wait,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))) fail(@"实时输入连接未响应，请检查设备解锁和开发者模式后重新连接。");
    checkReply(reply); return reply;
}
- (void)cancel { if(self.remote) remoteCancel(self.remote); if(self.local) xpc_connection_cancel(self.local); }
@end
static void observe(xpc_object_t event) {
    if((xpc_get_type(event)==XPC_TYPE_ERROR || (xpc_get_type(event)==XPC_TYPE_DICTIONARY && (xpc_dictionary_get_value(event,"CoreDevice.error") || xpc_dictionary_get_value(event,"error")))) && !closing) {
        dispatch_async(dispatch_get_main_queue(),^{ if(!closing) fail(@"实时输入通道中断，请重新连接设备。"); });
    }
}
static DMChannel *openRemote(const char *feature) {
    xpc_connection_t service=xpc_connection_create("com.apple.CoreDevice.CoreDeviceService",dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0));
    xpc_connection_set_event_handler(service,^(xpc_object_t event){ (void)event; }); xpc_connection_resume(service);
    xpc_object_t input=xpc_dictionary_create_empty(); xpc_dictionary_set_string(input,"featureIdentifier",feature);
    dispatch_semaphore_t wait=dispatch_semaphore_create(0); __block xpc_object_t reply;
    xpc_connection_send_message_with_reply(service,action("com.apple.coredevice.action.createservicesocket",input),
        dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(xpc_object_t r){reply=r; dispatch_semaphore_signal(wait);});
    if(dispatch_semaphore_wait(wait,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))) fail(@"打开设备服务超时，请重新连接 USB。");
    checkReply(reply); xpc_object_t out=xpc_dictionary_get_value(reply,"CoreDevice.output");
    if(!out || xpc_get_type(out)!=XPC_TYPE_DICTIONARY) fail(@"设备未提供实时输入服务。");
    int fd=xpc_dictionary_dup_fd(out,"fileDescriptor"); if(fd<0) fail(@"设备未提供实时输入连接。");
    DMChannel *channel=[DMChannel new];
    channel.remote=remoteCreate(fd,dispatch_queue_create("DeviceMirror.hid.remote",DISPATCH_QUEUE_SERIAL),xpc_dictionary_get_uint64(out,"remoteXPCVersionFlags"),0);
    if(!channel.remote) { close(fd); fail(@"无法建立 RemoteXPC 连接。"); }
    remoteHandler(channel.remote,^(xpc_object_t event){observe(event);}); remoteActivate(channel.remote);
    xpc_connection_cancel(service); return channel;
}
static DMChannel *openSimulator(id device, NSString *feature) {
    NSError *error=nil; uint32_t port=[device lookup:feature error:&error];
    if(!port) fail([NSString stringWithFormat:@"模拟器实时输入不可用：%@",error.localizedDescription ?: @"设备未启动"]);
    xpc_object_t (*endpoint)(uint32_t,uint64_t,uint64_t)=symbol("xpc_endpoint_create_mach_port_4sim");
    xpc_connection_t (*fromEndpoint)(xpc_object_t)=symbol("xpc_connection_create_from_endpoint");
    void (*enable)(xpc_connection_t)=symbol("xpc_connection_enable_sim2host_4sim");
    xpc_object_t ep=endpoint(port,0,0); DMChannel *c=[DMChannel new];
    c.local=ep?fromEndpoint(ep):nil; if(!c.local) fail(@"无法连接模拟器实时输入服务。");
    enable(c.local); xpc_connection_set_target_queue(c.local,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0));
    xpc_connection_set_event_handler(c.local,^(xpc_object_t event){observe(event);}); xpc_connection_resume(c.local);
    xpc_object_t p=xpc_dictionary_create_empty(); xpc_dictionary_set_uint64(p,"usageCode",0); xpc_dictionary_set_uint64(p,"state",2);
    xpc_object_t m=DMEnvelope("IndigoKeyboardButtonEvent",feature.UTF8String,p); xpc_dictionary_set_bool(m,"isBarrier",true);
    [c request:m]; return c;
}

// The active media session authenticates physical-device touches. Its RTP is
// drained independently; closing this connection releases only this session.
static DMChannel *startMedia(NSDictionary *details) {
    if(!dlopen("/System/Library/PrivateFrameworks/AVConference.framework/AVConference",RTLD_NOW|RTLD_GLOBAL)) fail(@"当前 macOS 未提供屏幕连接接口。");
    Class cls=NSClassFromString(@"AVCMediaStreamNegotiator"); NSError *error=nil;
    if(!cls || ![cls instancesRespondToSelector:@selector(initWithMode:options:error:)]) fail(@"当前 macOS 不支持实时屏幕连接。");
    id negotiator=[[cls alloc] initWithMode:5 options:@{} error:&error];
    if(!negotiator || ![negotiator createOffer]) fail(@"无法协商设备屏幕连接。");
    NSData *offer=[negotiator offer]; if(!offer.length) fail(@"设备屏幕连接参数为空。");
    NSString *peer=details[@"connectionProperties"][@"tunnelIPAddress"] ?: details[@"properties"][@"connection"][@"tunnelIPAddressString"];
    struct in6_addr peerAddr; if(!peer || inet_pton(AF_INET6,peer.UTF8String,&peerAddr)!=1) fail(@"USB 开发者隧道尚未建立，请重新连接设备。");
    struct ifaddrs *interfaces=NULL; NSString *host=nil; unsigned scope=0;
    if(getifaddrs(&interfaces)==0) {
        for(struct ifaddrs *i=interfaces;i;i=i->ifa_next) {
            if(!i->ifa_addr || i->ifa_addr->sa_family!=AF_INET6 || strncmp(i->ifa_name,"utun",4)) continue;
            struct sockaddr_in6 *a=(struct sockaddr_in6 *)i->ifa_addr;
            if(memcmp(&a->sin6_addr,&peerAddr,8)==0 && memcmp(&a->sin6_addr,&peerAddr,16)!=0) {
                char text[INET6_ADDRSTRLEN]; inet_ntop(AF_INET6,&a->sin6_addr,text,sizeof text);
                host=[NSString stringWithUTF8String:text]; scope=if_nametoindex(i->ifa_name); break;
            }
        }
        freeifaddrs(interfaces);
    }
    if(!host || !scope) fail(@"未找到设备对应的 USB 隧道接口。");
    mediaFD=socket(AF_INET6,SOCK_DGRAM,0); if(mediaFD<0) fail(@"无法创建屏幕连接接收器。");
    struct sockaddr_in6 address={0}; address.sin6_len=sizeof address; address.sin6_family=AF_INET6; address.sin6_scope_id=scope;
    inet_pton(AF_INET6,host.UTF8String,&address.sin6_addr);
    if(bind(mediaFD,(struct sockaddr *)&address,sizeof address)) fail(@"无法绑定设备 USB 隧道。");
    socklen_t length=sizeof address; getsockname(mediaFD,(struct sockaddr *)&address,&length);
    DMChannel *media=openRemote("com.apple.coredevice.feature.startmediastream");
    xpc_object_t in=xpc_dictionary_create_empty();
    xpc_dictionary_set_string(in,"receiverIP",host.UTF8String); xpc_dictionary_set_uint64(in,"receiverPort",ntohs(address.sin6_port));
    xpc_dictionary_set_string(in,"senderIP",peer.UTF8String); xpc_dictionary_set_uint64(in,"senderPort",51000);
    xpc_dictionary_set_uint64(in,"timeout",10); xpc_dictionary_set_string(in,"type","video");
    xpc_dictionary_set_string(in,"direction","output"); xpc_dictionary_set_uint64(in,"clientSupportedFeatures",972);
    xpc_dictionary_set_data(in,"negotiatorOffer",offer.bytes,offer.length);
    xpc_object_t options=xpc_dictionary_create_empty(), session=xpc_dictionary_create_empty();
    uuid_t uuid; uuid_generate(uuid); xpc_dictionary_set_uuid(session,"uuid",uuid);
    xpc_dictionary_set_value(options,"avcMediaStreamOptionClientSessionID",session); xpc_dictionary_set_value(in,"options",options);
    xpc_object_t reply=[media request:action("com.apple.coredevice.action.mediastreamstart",in)];
    xpc_object_t out=xpc_dictionary_get_value(reply,"CoreDevice.output");
    size_t n=0; const void *answer=out?xpc_dictionary_get_data(out,"negotiatorAnswer",&n):NULL;
    if(!answer && out) answer=xpc_dictionary_get_data(out,"answer",&n);
    if(!answer || ![negotiator setAnswer:[NSData dataWithBytes:answer length:n] withError:&error]) fail(@"设备未接受实时屏幕连接。");
    struct timeval timeout={8,0}; setsockopt(mediaFD,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);
    uint8_t first[8]; if(recv(mediaFD,first,sizeof first,MSG_PEEK)<=0) fail(@"设备屏幕连接未返回数据，控制未启用。");
    fcntl(mediaFD,F_SETFL,O_NONBLOCK);
    mediaDrain=dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,mediaFD,0,dispatch_get_global_queue(QOS_CLASS_UTILITY,0));
    dispatch_source_set_event_handler(mediaDrain,^{ uint8_t data[65536]; while(recv(mediaFD,data,sizeof data,0)>0){} });
    dispatch_resume(mediaDrain); [NSThread sleepForTimeInterval:.5];
    return media;
}

static DMChannel *touchChannel, *buttonChannel, *mediaChannel;
static BOOL simulator, touching=NO;
static CGPoint point;
static NSInteger orientation=1, touchOrientation=1, edgeQuarter=-1;
static NSMutableDictionary<NSString *,NSArray<NSNumber *> *> *heldKeys;
static double heldSince=0;
static uint64_t homeGeneration=0;
static void touch(NSString *phase, double x, double y, BOOL home) {
    if([phase isEqual:@"down"]) {
        if(touching) return; // One pointer per instance; never replace a held contact.
        touching=YES; heldSince=NSProcessInfo.processInfo.systemUptime; touchOrientation=orientation;
        edgeQuarter=home ? (orientation==3 ? 3 : orientation==4 ? 1 : orientation==2 ? 2 : 0) : -1;
    } else if(!touching) return;
    BOOL up=[phase isEqual:@"up"] || [phase isEqual:@"cancel"];
    point=CGPointMake(x,y); CGPoint native=DMNativePoint(point,touchOrientation);
    if(simulator) {
        // The simulator digitizer consumes normalized native-screen coordinates.
        uint64_t edge=home ? (touchOrientation==3 ? 2 : touchOrientation==4 ? 4 : touchOrientation==2 ? 1 : 3) : 0;
        [touchChannel send:DMDigitizerMessage(native.x,native.y,up?2:([phase isEqual:@"down"]?0:1),edge)];
    } else [touchChannel send:DMReportMessage(DMTouchReport(native.x,native.y,!up,edgeQuarter))];
    if(up) { touching=NO; edgeQuarter=-1; }
}
static void cancelInputs(void) {
    homeGeneration++;
    if(touching) touch(@"cancel",point.x,point.y,edgeQuarter>=0);
    for(NSString *key in heldKeys.allKeys) {
        NSArray *usage=heldKeys[key]; [buttonChannel send:DMButtonMessage([usage[0] unsignedLongLongValue],[usage[1] unsignedLongLongValue],2)];
    }
    [heldKeys removeAllObjects];
}
static void stopSession(void) {
    if(closing) return; closing=YES; cancelInputs();
    // Allow the final releases to reach the guest before dropping the channels.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,200*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        [touchChannel cancel]; if(buttonChannel != touchChannel) [buttonChannel cancel]; [mediaChannel cancel];
        if(mediaDrain) dispatch_source_cancel(mediaDrain);
        if(lease.running) [lease terminate];
        _Exit(0);
    });
}
static void command(NSDictionary *m) {
    if(closing) return;
    NSString *type=m[@"type"], *phase=m[@"phase"];
    if([type isEqual:@"cancel"]) { cancelInputs(); return; }
    if([type isEqual:@"orientation"]) { cancelInputs(); NSInteger v=[m[@"value"] integerValue]; if(v>=1 && v<=4) orientation=v; return; }
    if(![@[@"down",@"move",@"up",@"cancel"] containsObject:phase]) { cancelInputs(); fail(@"无效的输入阶段。"); }
    if([type isEqual:@"touch"]) {
        id x=m[@"x"], y=m[@"y"];
        if(![x isKindOfClass:NSNumber.class] || ![y isKindOfClass:NSNumber.class] || !isfinite([x doubleValue]) || !isfinite([y doubleValue]) || [x doubleValue]<0 || [x doubleValue]>1 || [y doubleValue]<0 || [y doubleValue]>1) { cancelInputs(); fail(@"无效的触摸坐标。"); }
        touch(phase,[x doubleValue],[y doubleValue],NO); return;
    }
    if(![type isEqual:@"key"]) { cancelInputs(); fail(@"无效的输入类型。"); }
    if([phase isEqual:@"cancel"]) { cancelInputs(); return; }
    NSString *key=m[@"key"]; BOOL down=[phase isEqual:@"down"];
    if([key isEqual:@"home"]) {
        if(down) {
            if(touching) return;
            uint64_t generation=++homeGeneration; touch(@"down",.5,1,YES);
            // This explicit Home button starts a bottom-edge gesture immediately.
            // Ordinary canvas drags are never interpreted as navigation commands.
            for(int i=1;i<=6;i++) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,i*30*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                if(generation==homeGeneration && touching) touch(@"move",.5,1-.55*i/6.,YES);
            });
        } else if(edgeQuarter>=0 && touching) {
            // A quick click releases after the short swipe; a held button stays down.
            uint64_t generation=homeGeneration;
            double elapsed=NSProcessInfo.processInfo.systemUptime-heldSince;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(MAX(0,.185-elapsed)*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                if(generation==homeGeneration && touching) { touch(@"up",.5,.45,YES); homeGeneration++; }
            });
        }
        return;
    }
    NSDictionary *usages=@{@"appSwitcher":@[@0xff01,@0x10],@"power":@[@12,@0x30],@"volumeup":@[@12,@0xe9],@"volumedown":@[@12,@0xea]};
    NSArray *usage=usages[key]; if(!usage) { cancelInputs(); fail(@"无效的设备按键。"); }
    if(down) { if(heldKeys[key]) return; heldKeys[key]=usage; heldSince=NSProcessInfo.processInfo.systemUptime; }
    else { if(!heldKeys[key]) return; [heldKeys removeObjectForKey:key]; }
    [buttonChannel send:DMButtonMessage([usage[0] unsignedLongLongValue],[usage[1] unsignedLongLongValue],down?1:2)];
}

int main(int argc, const char **argv) { @autoreleasepool {
    setbuf(stdout,NULL); setbuf(stderr,NULL); signal(SIGPIPE,SIG_IGN);
    if(argc==2 && !strcmp(argv[1],"--version")) { puts("Device Mirror iOS live input 1 (iOS/iPadOS 27+)"); return 0; }
    if(argc!=5 || strcmp(argv[1],"--udid") || strcmp(argv[3],"--kind") || (strcmp(argv[4],"device") && strcmp(argv[4],"simulator"))) { emit(@{@"error":@"参数：--udid ID --kind device|simulator"}); return 2; }
    signalSources=[NSMutableArray array];
    for(NSNumber *number in @[@(SIGINT),@(SIGTERM)]) {
        int value=number.intValue; signal(value,SIG_IGN);
        dispatch_source_t source=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,value,0,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0));
        dispatch_source_set_event_handler(source,^{
            if(lease.running) [lease terminate];
            if(!ready) _Exit(0);
            dispatch_async(dispatch_get_main_queue(),^{stopSession();});
        });
        dispatch_resume(source); [signalSources addObject:source];
    }
    NSString *udid=[NSString stringWithUTF8String:argv[2]]; simulator=!strcmp(argv[4],"simulator");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,75*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ if(!ready) fail(@"实时输入启动超时。"); });
    if(simulator) {
        NSDictionary *list=[NSJSONSerialization JSONObjectWithData:[run(@"/usr/bin/xcrun",@[@"simctl",@"list",@"devices",@"available",@"-j"]) dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
        NSString *version=nil;
        for(NSString *runtime in list[@"devices"]) for(NSDictionary *d in list[@"devices"][runtime]) if([d[@"udid"] isEqual:udid]) version=[[[runtime componentsSeparatedByString:@".iOS-"] lastObject] stringByReplacingOccurrencesOfString:@"-" withString:@"."];
        requireVersion(version?:@"");
        if(!dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator",RTLD_NOW|RTLD_GLOBAL)) fail(@"请安装完整 Xcode 和 iOS 模拟器 Runtime。");
        NSString *developer=[run(@"/usr/bin/xcode-select",@[@"-p"]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        Class cls=NSClassFromString(@"SimServiceContext"); NSError *error=nil;
        id context=[cls sharedServiceContextForDeveloperDir:developer error:&error]; id set=[context defaultDeviceSetWithError:&error]; id device=nil;
        for(id d in [set availableDevices]) if([[[d UDID] UUIDString] caseInsensitiveCompare:udid]==NSOrderedSame) { device=d; break; }
        if(!device) fail(@"未找到目标模拟器。");
        touchChannel=openSimulator(device,@"com.apple.coredevice.feature.remote.hid.digitizer");
        buttonChannel=touchChannel;
    } else {
        NSDictionary *details=jsonCommand(@[@"devicectl",@"device",@"info",@"details",@"--device",udid])[@"result"];
        NSString *version=details[@"deviceProperties"][@"osVersionNumber"] ?: details[@"properties"][@"software"][@"osVersionNumber"][@"stringValue"];
        requireVersion(version?:@""); deviceID=details[@"identifier"];
        if(!deviceID.length) fail(@"设备缺少 CoreDevice 标识。");
        lease=[NSTask new]; lease.executableURL=[NSURL fileURLWithPath:@"/usr/bin/xcrun"];
        lease.arguments=@[@"devicectl",@"device",@"notification",@"observe",@"--device",udid,@"--name",@"com.keye3tuido.devicemirror.lease"];
        lease.standardInput=NSFileHandle.fileHandleWithNullDevice; lease.standardOutput=NSFileHandle.fileHandleWithNullDevice; lease.standardError=NSFileHandle.fileHandleWithStandardError;
        NSError *leaseError=nil; if(![lease launchAndReturnError:&leaseError]) fail(@"无法保持 USB 开发者隧道。");
        NSString *framework=@"/Library/Developer/PrivateFrameworks/CoreDevice.framework";
        if(!dlopen([framework stringByAppendingPathComponent:@"CoreDevice"].UTF8String,RTLD_NOW|RTLD_GLOBAL)) fail(@"请安装 Xcode 27 或以上以使用实时控制。");
        NSBundle *bundle=[NSBundle bundleWithPath:framework]; coreVersion=[bundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"642.16";
        void (*add)(NSBundle *)=symbol("_coredevice_xpc_add_bundle"); void (*initialize)(void)=symbol("_coredevice_xpc_init_services"); add(bundle); initialize();
        remoteCreate=symbol("xpc_remote_connection_create_with_connected_fd"); remoteHandler=symbol("xpc_remote_connection_set_event_handler");
        remoteActivate=symbol("xpc_remote_connection_activate"); remoteCancel=symbol("xpc_remote_connection_cancel");
        remoteSend=symbol("xpc_remote_connection_send_message"); remoteReply=symbol("xpc_remote_connection_send_message_with_reply");
        mediaChannel=startMedia(details);
        touchChannel=openRemote("com.apple.coredevice.feature.remote.universalhidservice");
        buttonChannel=openRemote("com.apple.coredevice.feature.remote.hid.button");
        xpc_object_t p=xpc_dictionary_create_empty(); xpc_dictionary_set_value(p,"connectedServices",xpc_dictionary_create_empty());
        xpc_object_t reply=[touchChannel request:DMEnvelope("Request","com.apple.coredevice.feature.remote.universalhidservice",p)];
        if(!xpc_dictionary_get_value(reply,"connectedServices")) fail(@"设备未确认触摸服务，控制未启用。");
    }
    heldKeys=[NSMutableDictionary dictionary]; ready=YES; emit(@{@"ready":@YES});
    safetyTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(safetyTimer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,0);
    dispatch_source_set_event_handler(safetyTimer,^{
        if(getppid()==1) stopSession();
        if((touching || heldKeys.count) && NSProcessInfo.processInfo.systemUptime-heldSince>=30) { cancelInputs(); emit(@{@"released":@YES}); }
        if(lease && !lease.running && !closing) { cancelInputs(); fail(@"USB 隧道已断开，请重新连接。"); }
    }); dispatch_resume(safetyTimer);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        char line[4096];
        while(fgets(line,sizeof line,stdin)) { @autoreleasepool {
            if(!strchr(line,'\n')) { dispatch_async(dispatch_get_main_queue(),^{cancelInputs(); fail(@"输入消息过长。");}); break; }
            NSData *data=[[NSString stringWithUTF8String:line] dataUsingEncoding:NSUTF8StringEncoding];
            id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
            dispatch_async(dispatch_get_main_queue(),^{ if(![value isKindOfClass:NSDictionary.class]) {cancelInputs(); fail(@"无效的输入消息。");} command(value); });
        } }
        dispatch_async(dispatch_get_main_queue(),^{stopSession();});
    });
    dispatch_main();
} }
