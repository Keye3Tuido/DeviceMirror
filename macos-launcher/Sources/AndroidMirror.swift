// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit
import SwiftUI

private final class MirrorSession {
    let process: Process
    let log: FileHandle
    let logURL: URL
    var recorder: AndroidLogRecorder?
    var stopping = false
    init(process: Process, log: FileHandle, logURL: URL) {
        self.process = process; self.log = log; self.logURL = logURL
    }
}

@MainActor
final class MirrorModel: ObservableObject {
    @Published var devices: [AndroidDevice] = []
    @Published var selectedSerial: String?
    @Published var active: Set<String> = []
    @Published var logging: Set<String> = []
    @Published private var deviceOptions: [String: MirrorOptions] = [:]
    var options: MirrorOptions {
        get { deviceOptions[selectedSerial ?? ""] ?? MirrorOptions() }
        set { deviceOptions[selectedSerial ?? ""] = newValue }
    }
    @Published var refreshing = false
    @Published var error: String?
    @Published var showHelp = false
    private var sessions: [String: MirrorSession] = [:]
    private var lastLogDirectories: [String: URL] = [:]
    private var timer: Timer?
    private var shuttingDown = false

    let resources = Bundle.main.resourceURL!
    var adb: URL? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/adb")
        return FileManager.default.isExecutableFile(atPath: bundled.path) ? bundled : nil
    }
    var scrcpy: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/scrcpy") }
    var selected: AndroidDevice? { devices.first { $0.serial == selectedSerial } }
    var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DeviceMirror", isDirectory: true)
    }

    func begin() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing, !shuttingDown else { return }
        guard let executable = adb else {
            devices = []
            error = "应用内 adb 缺失，请重新下载完整的 Device Mirror.app。"
            return
        }
        refreshing = true
        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try CommandRunner.run(executable, ["devices", "-l"]) }
            }.value
            refreshing = false
            switch result {
            case .success(let command) where command.status == 0 && !command.timedOut:
                devices = AndroidDevice.parse(command.output)
                if !devices.contains(where: { $0.serial == selectedSerial }) {
                    selectedSerial = devices.first(where: \.isReady)?.serial ?? devices.first?.serial
                }
            case .success(let command):
                error = command.timedOut ? "ADB 响应超时，请检查 USB 连接后刷新。" : "读取设备失败：\(command.output)"
            case .failure(let failure):
                error = "无法启动 ADB：\(failure.localizedDescription)"
            }
        }
    }

    func start() {
        guard let device = selected, let adb, device.isReady, sessions[device.serial] == nil else { return }
        error = nil
        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
            let safeSerial = String(device.serial.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
            let directory = logDirectory.appendingPathComponent("android-\(safeSerial)-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let logURL = directory.appendingPathComponent("mirror.log")
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
            let log = try FileHandle(forWritingTo: logURL)
            try log.write(contentsOf: Data("Device Mirror · \(device.serial) · \(ISO8601DateFormatter().string(from: Date()))\n".utf8))
            let process = Process()
            process.executableURL = scrcpy
            process.arguments = options.arguments(for: device)
            var environment = ProcessInfo.processInfo.environment
            environment["ADB"] = adb.path
            environment["DEVICE_MIRROR_TOOLBAR"] = "1"
            environment["DEVICE_MIRROR_LOG_FILE"] = logURL.path
            environment["SCRCPY_ICON_DIR"] = resources.appendingPathComponent("scrcpy").path
            environment["SCRCPY_SERVER_PATH"] = resources.appendingPathComponent("scrcpy/scrcpy-server").path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log
            process.standardError = log
            let session = MirrorSession(process: process, log: log, logURL: logURL)
            process.terminationHandler = { [weak self] finished in
                Task { @MainActor in self?.finished(serial: device.serial, process: finished) }
            }
            sessions[device.serial] = session
            do { try process.run() }
            catch {
                sessions.removeValue(forKey: device.serial)
                try? log.close()
                throw error
            }
            active.insert(device.serial)
            lastLogDirectories[device.serial] = directory
            if options.recordLogs { startRecording(device.serial) }
        } catch {
            self.error = "启动投屏失败：\(error.localizedDescription)"
        }
    }

    private func finished(serial: String, process: Process) {
        guard let session = sessions[serial], session.process === process else { return }
        try? session.log.close()
        session.recorder?.stop()
        logging.remove(serial)
        sessions.removeValue(forKey: serial)
        active.remove(serial)
        if process.terminationStatus != 0 && !session.stopping && !shuttingDown {
            let log = (try? String(contentsOf: session.logURL, encoding: .utf8)) ?? ""
            let details = log.split(separator: "\n").suffix(12).joined(separator: "\n")
            error = "投屏已断开，请检查设备连接。\n\n\(details)"
        }
        refresh()
    }

    func stop(_ serial: String) {
        guard let session = sessions[serial] else { return }
        session.stopping = true
        session.recorder?.stop()
        guard session.process.isRunning else { return }
        session.process.terminate()
        let process = session.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    func shutdown(completion: @escaping () -> Void) {
        shuttingDown = true
        timer?.invalidate()
        let processes = sessions.values.flatMap { session in
            [session.process] + (session.recorder.map { [$0.process] } ?? [])
        }
        for serial in Array(sessions.keys) { stop(serial) }
        DispatchQueue.global().async {
            for process in processes { process.waitUntilExit() }
            DispatchQueue.main.async { completion() }
        }
    }

    func startRecording(_ serial: String) {
        guard let session = sessions[serial], let adb, session.recorder == nil else { return }
        do {
            let recorder = try AndroidLogRecorder(adb: adb, serial: serial, directory: session.logURL.deletingLastPathComponent()) { [weak self, weak session] status in
                Task { @MainActor in
                    guard let self, let session, self.sessions[serial] === session else { return }
                    let stopped = session.recorder?.stopping == true
                    session.recorder = nil
                    self.logging.remove(serial)
                    if status != 0 && !stopped { self.error = "\(serial) 的系统日志记录已中断，请打开此设备日志查看原因。" }
                }
            }
            session.recorder = recorder
            logging.insert(serial)
        } catch { self.error = "无法记录系统日志：\(error.localizedDescription)" }
    }

    func stopRecording(_ serial: String) { sessions[serial]?.recorder?.stop() }

    func openLogs(_ serial: String? = nil) {
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let serial = serial ?? selectedSerial ?? ""
        NSWorkspace.shared.open(sessions[serial]?.logURL.deletingLastPathComponent() ?? lastLogDirectories[serial] ?? logDirectory)
    }
}

struct ContentView: View {
    @ObservedObject var model: MirrorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 32)).foregroundStyle(.teal)
                    .frame(width: 54, height: 54)
                    .background(.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Device Mirror").font(.system(size: 25, weight: .semibold))
                    Text("Android · 每台设备独立投屏与操控").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button { model.showHelp = true } label: {
                    Image(systemName: "questionmark.circle").font(.title3)
                }.buttonStyle(.plain).help("操作说明")
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("设备").font(.headline)
                    Text("\(model.devices.count)").foregroundStyle(.secondary)
                    Spacer()
                    if model.refreshing { ProgressView().controlSize(.small) }
                    Button { model.refresh() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                        .disabled(model.refreshing).controlSize(.small)
                }
                if model.devices.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "cable.connector").font(.system(size: 30)).foregroundStyle(.secondary)
                        Text("等待 Android 设备").font(.headline)
                        Text("用 USB 数据线连接，并在设备上开启「USB 调试」。\n首次连接请在设备上点击「允许」。")
                            .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(model.devices) { device in
                                deviceRow(device)
                            }
                        }
                    }.frame(height: min(CGFloat(model.devices.count) * 78, 230))
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("画质").foregroundStyle(.secondary)
                    Picker("画质", selection: $model.options.maxSize) {
                        Text("轻量 1280").tag(1280)
                        Text("清晰 1920").tag(1920)
                        Text("原始尺寸").tag(0)
                    }.labelsHidden().pickerStyle(.segmented)
                }
                HStack {
                    Text("帧率").foregroundStyle(.secondary)
                    Picker("帧率", selection: $model.options.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 180)
                    Spacer()
                    Toggle("传输声音", isOn: $model.options.audio)
                }
                Toggle("投屏时保持设备唤醒", isOn: $model.options.stayAwake)
                    .font(.callout)
                if let serial = model.selectedSerial, model.active.contains(serial) {
                    HStack {
                        if model.logging.contains(serial) {
                            Label("正在记录系统日志", systemImage: "record.circle").font(.caption).foregroundStyle(.red)
                            Button("停止记录") { model.stopRecording(serial) }
                        } else {
                            Button("记录系统日志") { model.startRecording(serial) }
                        }
                        Spacer()
                        Button("此设备日志") { model.openLogs(serial) }
                    }.controlSize(.small)
                } else {
                    Toggle("投屏时记录系统日志（logcat）", isOn: $model.options.recordLogs).font(.callout)
                }
                Text("运行日志自动保存。系统日志按设备启停，关闭投屏时停止记录。")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.active.isEmpty {
                    Text("画质、帧率、音频和保持唤醒设置在下次启动此设备时生效。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))

            if let error = model.error {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Label("连接提示", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        Spacer()
                        Button("关闭") { model.error = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(error).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 110)
                }.padding(12).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("点击 · 拖动 · 滚轮 · 键盘输入").font(.callout)
                    Text("右键返回 · ⌘H 主屏幕 · ⌘F 全屏").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let serial = model.selectedSerial, model.active.contains(serial) {
                    Button("停止投屏") { model.stop(serial) }.controlSize(.large)
                } else {
                    Button { model.start() } label: { Label("开始投屏", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(.teal).controlSize(.large)
                        .disabled(model.selected?.isReady != true)
                        .keyboardShortcut(.return, modifiers: [])
                }
            }
            HStack {
                Text("基于 scrcpy · 支持多设备同时投屏").font(.caption).foregroundStyle(.tertiary)
                Spacer()
                Button("日志") { model.openLogs() }.buttonStyle(.link).font(.caption)
            }
        }
        .padding(26).frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { model.begin() }
        .sheet(isPresented: $model.showHelp) { HelpView() }
    }

    private func deviceRow(_ device: AndroidDevice) -> some View {
        Button { model.selectedSerial = device.serial } label: {
            HStack(spacing: 12) {
                Image(systemName: "ipad.landscape").font(.title2).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(device.model).font(.system(size: 14, weight: .semibold)).foregroundStyle(.primary)
                    Text(device.serial).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(device.isReady ? Color.green : Color.orange).frame(width: 6, height: 6)
                Text(model.active.contains(device.serial) ? "投屏中" : device.stateLabel)
                    .font(.caption).foregroundStyle(.secondary)
                Image(systemName: device.serial == model.selectedSerial ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(device.serial == model.selectedSerial ? Color.teal : Color.secondary)
            }
            .padding(14)
            .background(device.serial == model.selectedSerial ? Color.teal.opacity(0.08) : Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11)
                .stroke(device.serial == model.selectedSerial ? Color.teal.opacity(0.5) : Color.clear, lineWidth: 1))
        }.buttonStyle(.plain).accessibilityLabel("\(device.model)，\(device.stateLabel)")
    }
}

struct HelpView: View {
    @Environment(\.dismiss) private var dismiss
    let shortcuts = [
        ("点击 / 拖动 / 滚轮", "点按、滑动和滚动"),
        ("鼠标右键", "返回（休眠时唤醒）"),
        ("⌘ H / 鼠标中键", "主屏幕"),
        ("⌘ S", "最近任务"),
        ("⌘ F", "切换全屏"),
        ("⌘ V", "粘贴电脑剪贴板（支持中文）"),
        ("⌘ ↑ / ⌘ ↓", "调节音量"),
        ("⌘ P", "电源键"),
        ("Control + 拖动", "双指缩放")
    ]
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Android 操作说明").font(.title2.bold())
            Text("投屏窗口顶部提供返回、主页、最近任务、音量、电源和通知按键。先在设备列表选中设备，再设置画质与帧率并开始投屏。")
                .font(.callout).foregroundStyle(.secondary)
            Text("先点击设备输入框，再点投屏窗口顶部“发送文本”，输入内容后发送；也可使用文字栏，支持中文。发送会更新设备剪贴板并粘贴；用“按键”菜单发送回车、退格、Tab 和方向键。")
                .font(.callout).foregroundStyle(.secondary)
            Text("从画面四周的白色留白按住鼠标拖入，可模拟屏幕边缘手势。设备列表中的“记录系统日志”按设备启停录制，窗口“日志”打开运行日志。")
                .font(.callout).foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 11) {
                ForEach(shortcuts, id: \.0) { key, description in
                    GridRow {
                        Text(key).font(.system(.callout, design: .monospaced))
                        Text(description).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text("没有设备：检查数据线、开发者选项和 USB 调试。\n未授权：解锁设备并接受 RSA 授权提示。\n部分小米 / OPPO 设备还需开启「USB 调试（安全设置）」才能操控。\n关闭投屏窗口即停止该设备投屏；⌘Q 退出并关闭所有投屏。")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(5)
            HStack {
                Button("开源许可") {
                    NSWorkspace.shared.open(Bundle.main.resourceURL!.appendingPathComponent("ThirdParty"))
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 480)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MirrorModel()
    let ios = IOSManager()
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        ios.shutdown { self.model.shutdown { sender.reply(toApplicationShouldTerminate: true) } }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct DeviceMirrorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @State private var platform = 0
    var body: some Scene {
        Window("Device Mirror", id: "main") {
            VStack(spacing: 0) {
                Picker("平台", selection: $platform) {
                    Text("Android").tag(0)
                    Text("iOS 真机 / 模拟器").tag(1)
                }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 26).padding(.top, 20)
                if platform == 0 { ContentView(model: delegate.model) }
                else { IOSLauncherView(model: delegate.ios) }
            }.frame(width: 560)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("设备列表") { openWindow(id: "main") }.keyboardShortcut("1", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Device Mirror · Android 操作说明") { platform = 0; delegate.model.showHelp = true }
            }
        }
    }
}
