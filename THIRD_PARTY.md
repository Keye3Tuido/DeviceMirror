# 版权与分发记录

项目是 scrcpy 的独立衍生版本，主要采用 Apache-2.0；`macos-launcher/NativeIOS/` 按 MIT 许可改写和分发。根目录 LICENSE 保留上游原文，原文件版权头保持原归属。新增与修改范围见 NOTICE 和提交历史。

| 组件 | 固定版本 / 来源 | 许可与处理 |
|---|---|---|
| scrcpy 客户端及 Android 服务 | 5.0.1，Genymobile/scrcpy，a60891aea193d92e7e5c3942700eca63f9d19a5f | Apache-2.0；保留 LICENSE、原源码与原始图标归属；客户端及 Android 服务均从本仓库修改后的源码编译 |
| WebDriverAgent | 16.15.3，appium/WebDriverAgent，02cb92f0e93c8b021443bcbb8eeb80932c113220；Git submodule 固定完整 SHA | BSD，完整许可随源码分发；固定子模块保持原样，打包时向 `FBTouchActionCommands.m` 追加自有扩展的导入，改动处附署名及许可标记。`macos-launcher/WDA/DMControlCommands.m` 为 Apache-2.0 自有代码，源码与许可随包附带 |
| iOS 实时输入原生通道 | ipb `8c227a10710dad479852aa0203de729fed57471b`；facebook/idb `595884395c01fe1e8056a45a481de8310875ce87` | MIT；按原生服务用途改写，来源、改动说明及完整许可位于 `third_party/ios-control/`，随 app 分发；不复制 Apple 框架 |
| adb | nmeum/android-tools 37.0.0p1 及其固定 AOSP 源码 | Apache-2.0 及各源码内许可；从源码编译，保留完整源码归档。调整 BoringSSL 头文件优先级，关闭 mDNS，使用可替换的动态 libusb |
| adb 的静态构建组件 | android-tools 归档内的 BoringSSL、fmt 及 AOSP 库 | 原 Apache、BSD、MIT、OpenSSL/ISC 等许可与版权头随完整源码归档保留 |
| libusb | 1.0.30，libusb 官方源码 | LGPL-2.1-or-later；从固定源码编译为独立 dylib，附完整对应源码、许可与构建脚本，可替换并重新签名 |
| adb 的动态依赖 | protobuf 36.2、Abseil 20260817.0、Brotli 1.2.1、LZ4 1.10.0、Zstd 1.5.7；GoogleTest 1.18.0 头文件 | BSD、Apache-2.0、MIT 等许可；附实际打包版本的许可证、Homebrew 版本与来源记录。protobuf 的 utf8_range 另附原 MIT 许可 |
| FFmpeg | n9.0.2，官方 FFmpeg/FFmpeg 源码 | 此构建为 LGPL-2.1-or-later，禁用 GPL、nonfree、version3 与自动探测；使用独立 dylib，随包附完整对应源码、配置及构建脚本 |
| SDL | 3.4.16，Homebrew 官方 sdl3 配方 | zlib，保留完整 LICENSE；动态链接 |
| 系统框架与 zlib | macOS 提供 | 使用本机安装版本，分发包不复制 Apple 系统框架或开发工具 |

自有 Android 文本输入组件及其 Mac 辅助服务采用 Apache-2.0，源码分别位于 `macos-launcher/AndroidInput/` 与 `macos-launcher/AndroidInputService/`。Android SDK 和 Java 仅用于编译，不随 Mac 应用分发。APK 由本机构建密钥签名，密钥不随应用或仓库分发。

原生 iOS 输入使用本机 CoreDevice / CoreSimulator 与 AVConference 的私有接口；接口兼容性受系统及 Xcode 版本影响。WDA 通过 XCTest 使用本机 Xcode 提供的开发接口，USB 采集使用系统 AVFoundation / CoreMediaIO。开发证书、描述文件和 iOS 签名应用由用户本机 Xcode 生成并存于本地缓存；它们不随通用分发包提供。

## LGPL 对应源码与替换

应用 `Contents/Resources/ThirdParty/Sources/` 内附 FFmpeg 完整源代码压缩包、实际 `config.h` 与构建脚本。使用同一 API/ABI 版本构建的 LGPL 动态库，可以替换 `Contents/Frameworks/` 下的 FFmpeg 库。替换后用本地签名重新签署动态库与主应用即可运行：

```sh
codesign --force --sign - '/path/to/Device Mirror.app/Contents/Frameworks/libavcodec.63.dylib'
codesign --force --sign - '/path/to/Device Mirror.app'
```

替换多个库时，逐个签署所有修改过的动态库，再签署主应用。允许为调试 LGPL 库修改而进行逆向工程；动态库可替换并重新签名。FFmpeg 使用固定上游源码，构建参数位于 `macos-launcher/prepare-deps.sh`，包内脚本为 `ThirdParty/Sources/ffmpeg-build.sh`。SDL 许可位于 `SDL-zlib.txt`，WDA BSD 原文位于 `WebDriverAgent-BSD.txt`。

发布包须保留 NOTICE、所有许可证、对应源代码及构建文件。adb 的源码、构建脚本、依赖许可证及版本记录位于 `ThirdParty/Android-tools/`。第三方商标及其他权利由各权利人保留。

libusb 同样允许为调试库修改而进行逆向工程，替换位置为 `Contents/Frameworks/libusb-1.0.0.dylib`。对应源码为 `ThirdParty/Android-tools/libusb-1.0.30.tar.bz2`，可解压后执行 `./configure --disable-static --enable-shared --prefix=/tmp/libusb-install && make && make install`，再替换动态库、恢复 `@loader_path/libusb-1.0.0.dylib` 安装名并重新签名。完整构建参数见同目录 `adb-build.py`。所有 LGPL 库使用同一 ABI 的替换版本。

## 校验

- scrcpy macOS 包 SHA-256：`33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b`
- FFmpeg 源码包 SHA-256：`6e374ed621e48faa40639307dff48ba6fe574a509977956d2cce9669b7cc27e9`
- android-tools 37.0.0p1 源码包 SHA-256：`2c6de1abe16b211c7d9f59276217e14fd9e0e18b20e331d3c84358f5dffd576e`
- libusb 1.0.30 源码包 SHA-256：`fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf`

构建脚本核对固定校验值、检查 FFmpeg 配置，并拒绝带有未打包外部库链接的引擎。
