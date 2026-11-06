# Device Mirror

Device Mirror 是适用于 Apple Silicon / macOS 26 的本地设备投屏与控制程序，支持 Android、iPhone、iPad 和 iOS 模拟器。每台设备使用独立窗口，可以同时连接多台设备。

## 开始使用

打开仓库根目录的 `Device Mirror.app`。应用内含 adb、scrcpy、原生控制服务及所需动态库，可移到“应用程序”等目录运行，日常使用不依赖源码目录或 Python。iOS USB 操控和模拟器功能仍需本机安装完整 Xcode；USB 观看真机镜像使用 macOS 系统采集功能。

| 设备与用途 | 连接条件 | 操作入口 |
|---|---|---|
| Android 投屏与操控 | USB 调试及设备授权 | Android → 选中设备 → 开始投屏 |
| iPhone / iPad 观看镜像 | USB 连接、信任电脑、macOS 采集权限 | iOS → USB 真机 → 查看镜像 |
| iPhone / iPad USB 操控 | 完整 Xcode、开发团队、开发者模式及测试认证 | iOS → 配置 Apple 账号 → USB 操控 → 连接 |
| iOS 模拟器投屏与操控 | 完整 Xcode 和 iOS Runtime | iOS → 选择模拟器 → 启动并连接 |

Android 支持点击、滑动、滚轮、键盘、中文文字发送、虚拟设备按键和按设备记录 logcat。画面四周的白色留白可用于从屏幕外划入。

iOS USB 操控与模拟器支持点击、普通滑动、长按、文字输入、返回、主页、多任务及锁屏；真机另有音量键。滑动与长按在松开鼠标后按记录的轨迹和停顿时间重放，单次最长 30 秒。返回优先点击标准导航栏返回按钮，其次识别明确标注“返回／Back”等名称的控件，无可用控件时尝试收起屏幕键盘。iOS 没有全局返回键，未标注的自定义控件需要直接点击；系统弹窗应先处理。iOS 不将边缘滑入识别为导航命令，留白起点和滚轮不发送触摸操作。

iOS 控制使用 XCTest / WebDriverAgent，响应速度受自动化接口及画面回传影响；不传输 iOS 音频。

关闭设备窗口会停止该设备会话；⌘1 打开设备列表，⌘Q 退出全部会话。

## 使用与构建资料

- [连接、操作、日志和构建](macos-launcher/README.md)
- [常见问题与故障处理](FAQ.md)
- [版权、依赖及分发要求](THIRD_PARTY.md) · [NOTICE](NOTICE)
- [scrcpy 上游项目](https://github.com/Genymobile/scrcpy)：Android 镜像与控制核心。

本地应用约 65 MB，使用原生 SwiftUI / AppKit，采用本地签名，尚未进行 Developer ID 公证。Intel 和其他 macOS 版本尚未验证。GitHub Pages 可托管介绍与下载页面；完整投屏和操控需运行本地应用。

## 许可与来源

本项目是 scrcpy 5.0.1 的独立衍生作品，作者为 Keye3Tuido。scrcpy 原作者、历史、Apache-2.0 许可证及修改声明随仓库保留。自有新增代码采用 Apache-2.0，第三方组件保留各自许可。应用图标沿用 scrcpy 原始图标。完整归属与对应源码要求见 [THIRD_PARTY.md](THIRD_PARTY.md)。
