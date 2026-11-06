# iOS 实时输入代码来源

`macos-launcher/NativeIOS/` 的原生通道与报文构造按下列 MIT 项目改写，保留许可并与 Device Mirror 的 Apache-2.0 代码分别署名。

| 来源 | 固定提交 | 采用内容 |
|---|---|---|
| https://github.com/ipbtools/ipb | `8c227a10710dad479852aa0203de729fed57471b` | `Sources/action_sender.m` 的 CoreDevice 服务连接、`Sources/video_stream.m` 的媒体协商、`Sources/universalhid_glue.swift` 的 58 字节触摸报文、`Sources/display_geometry.h` 的坐标旋转；协议说明见该提交 `docs/protocol.md` |
| https://github.com/facebook/idb | `595884395c01fe1e8056a45a481de8310875ce87` | `FBSimulatorControl/XPC/SimulatorXPCConnection.swift` 的模拟器 XPC 连接、`HID/SimulatorDTUHIDConnection.swift` 的存活探测和 `HID/DTUHIDModels.swift` 的有类型报文 |

改动包括：以单设备 JSON 输入服务替代原项目命令行与窗口；统一触摸与按键阶段；媒体连接独立排空；版本检查；退出、失焦、超时释放；仅显式主页按钮附加系统边缘标记。未合入上游的图形界面、Python 工具或 Swift ABI 汇编。

`ipb-MIT.txt` 和 `idb-MIT.txt` 为原始完整许可，随 app 分发。Apple CoreDevice、CoreSimulator、AVConference 均从用户本机安装位置加载；Apple 框架、工具与头文件不复制进应用。私有接口随系统及 Xcode 变化可能失效，连接失败时停止控制并显示原因。
