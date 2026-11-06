# Android 控制组件来源

adb 从 nmeum/android-tools 37.0.0p1 的固定源码归档编译。自有构建脚本调整 BoringSSL 头文件优先级，关闭 mDNS，并动态链接 libusb。源码校验值与构建参数见 `macos-launcher/prepare-adb.py`。

应用 `Contents/Resources/ThirdParty/Android-tools/` 包含完整 android-tools 源码、libusb 对应源码、构建脚本、第三方依赖许可证和实际版本记录。LGPL libusb 可替换并重新签名，操作说明见根目录 `THIRD_PARTY.md`。

`utf8_range-LICENSE` 是 protobuf v36.2 的 `third_party/utf8_range/LICENSE` 原文；来源为 https://github.com/protocolbuffers/protobuf/blob/v36.2/third_party/utf8_range/LICENSE 。原版权归 Yibo Cai 和 Google LLC，SHA-256 为 `02de69b64fc36d9e938f418e52723e42f0b2b226d58a9cb3c8dcbdf7059f5074`。
