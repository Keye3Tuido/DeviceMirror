// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit
import SwiftUI

struct IOSDevice: Identifiable, Decodable {
    let udid: String
    let name: String
    let kind: String
    let state: String
    var id: String { udid }
    var isSimulator: Bool { kind == "simulator" }
    var isUSBMirror: Bool { kind == "capture" }
    var subtitle: String {
        if isUSBMirror { return "USB 真机 · 观看画面" }
        if !isSimulator { return state == "USB" ? "USB 操控" : "USB 操控 · \(state)" }
        let label: String
        switch state {
        case "Booted": label = "运行中"
        case "Shutdown": label = "未启动"
        case "Booting": label = "启动中"
        case "Shutting Down": label = "关闭中"
        default: label = state
        }
        return "模拟器 · \(label)"
    }
}

private struct IOSDeviceList: Decodable { let devices: [IOSDevice] }
private struct SigningTeam: Identifiable, Decodable { let id: String; let name: String }
private struct SigningInfo: Decodable { let teams: [SigningTeam]; let hasAccounts: Bool; let source: String }

@MainActor
final class IOSManager: ObservableObject {
    @Published var devices: [IOSDevice] = []
    @Published var active: Set<String> = []
    @Published var refreshing = false
    @Published var error: String?
    @Published var showDeviceControl = true
    @Published fileprivate var signingTeams: [SigningTeam] = []
    @Published var detectingSigning = false
    @Published var signingStatus = "请在 Xcode 中登录 Apple 账号，然后检测开发团队。"
    @Published var selectedSigningTeam = UserDefaults.standard.string(forKey: "selectedSigningTeam") ?? "" {
        didSet { UserDefaults.standard.set(selectedSigningTeam, forKey: "selectedSigningTeam") }
    }
    @Published var team = UserDefaults.standard.string(forKey: "developmentTeam") ?? "" {
        didSet { UserDefaults.standard.set(team, forKey: "developmentTeam") }
    }
    private var sessions: [String: IOSSession] = [:]
    private var mirrors: [String: IOSUSBMirrorSession] = [:]
    private var timer: Timer?

    func openXcode() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode") else {
            signingStatus = "请先安装完整 Xcode。"; return
        }
        NSWorkspace.shared.open(url)
    }

    func detectSigning() {
        guard !detectingSigning else { return }
        detectingSigning = true
        let service = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/device-service")
        Task {
            defer { detectingSigning = false }
            let result = await Task.detached(priority: .utility) {
                Result {
                    let tools = try CommandRunner.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], timeout: 3)
                    guard tools.status == 0 else {
                        throw NSError(domain: "DeviceMirror", code: 1, userInfo: [NSLocalizedDescriptionKey: "请先安装完整 Xcode 并选择开发者目录。"])
                    }
                    let command = try CommandRunner.run(service, ["--signing-info"], timeout: 25)
                    guard command.status == 0 && !command.timedOut else { throw URLError(.cannotParseResponse) }
                    return try JSONDecoder().decode(SigningInfo.self, from: Data(command.output.utf8))
                }
            }.value
            do {
                let info = try result.get()
                signingTeams = info.teams
                if !signingTeams.contains(where: { $0.id == selectedSigningTeam }) { selectedSigningTeam = "" }
                if !info.hasAccounts {
                    signingStatus = "请在 Xcode → Settings → Apple Accounts 登录 Apple 账号，再点“重新检测”。"
                } else if info.source != "xcode" {
                    signingStatus = "已检测到 Xcode 账号，团队列表暂不可用。下列候选来自本机证书，请在 Xcode 的 Apple Accounts 中确认后选择。"
                } else if info.teams.isEmpty {
                    signingStatus = "请在 Xcode → Apple Accounts 中确认团队和开发证书，再重新检测；也可手动输入 Team ID。"
                } else {
                    signingStatus = info.teams.count == 1 ? "已识别开发团队，连接时自动签名。" : "检测到多个团队，请选择用于此设备的团队。"
                }
            } catch { signingStatus = error.localizedDescription }
        }
    }

    func begin() {
        guard timer == nil else { return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        let mirrorDevices = IOSUSBDevices.devices.map {
            IOSDevice(udid: $0.uniqueID, name: $0.localizedName, kind: "capture", state: "观看画面")
        }
        devices = mirrorDevices + devices.filter { !$0.isUSBMirror }
        let service = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/device-service")
        Task {
            let result = await Task.detached(priority: .utility) {
                Result {
                    // Probe for developer tools before listing control targets; USB capture
                    // remains available through the system frameworks.
                    let tools = try CommandRunner.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), ["-p"], timeout: 3)
                    guard tools.status == 0 else { return "{\"devices\":[]}" }
                    let command = try CommandRunner.run(service, ["--list"], timeout: 18)
                    guard command.status == 0 && !command.timedOut else {
                        throw NSError(domain: "DeviceMirror", code: 1, userInfo: [NSLocalizedDescriptionKey: command.output])
                    }
                    return command.output
                }
            }.value
            refreshing = false
            do {
                let output = try result.get()
                let listed = try JSONDecoder().decode(IOSDeviceList.self, from: Data(output.utf8)).devices
                devices = mirrorDevices + listed.filter { !$0.isSimulator } + listed.filter { $0.isSimulator }
                error = nil
            } catch { self.error = "读取模拟器及控制设备失败：\(error.localizedDescription)" }
        }
    }

    func open(_ device: IOSDevice) {
        if device.isUSBMirror {
            if let existing = mirrors[device.id] { existing.show(); return }
            let mirror = IOSUSBMirrorSession(device: device)
            mirror.onClose = { [weak self] in
                self?.mirrors.removeValue(forKey: device.id)
                self?.active.remove(device.id)
            }
            mirrors[device.id] = mirror
            active.insert(device.id)
            mirror.show()
            mirror.start()
            return
        }
        if let existing = sessions[device.id] { existing.show(); return }
        if !device.isSimulator && selectedSigningTeam.isEmpty && signingTeams.count > 1 {
            error = "请在 USB 操控设置中选择用于设备签名的开发团队。"
            return
        }
        let selectedTeam = signingTeams.count == 1 ? signingTeams[0].id : selectedSigningTeam
        let session = IOSSession(device: device, team: signingTeams.isEmpty ? team.trimmingCharacters(in: .whitespaces) : selectedTeam)
        session.onClose = { [weak self] in
            self?.sessions.removeValue(forKey: device.id)
            self?.active.remove(device.id)
        }
        sessions[device.id] = session
        active.insert(device.id)
        session.show()
        session.start()
    }

    func stop(_ device: IOSDevice) { sessions[device.id]?.close(); mirrors[device.id]?.close() }

    func shutdown(completion: @escaping () -> Void) {
        timer?.invalidate()
        let processes = sessions.values.compactMap(\.process)
        for session in Array(sessions.values) { session.close() }
        for mirror in Array(mirrors.values) { mirror.close() }
        DispatchQueue.global().async {
            for process in processes { process.waitUntilExit() }
            DispatchQueue.main.async { completion() }
        }
    }
}

private final class MJPEGReader: NSObject, URLSessionDataDelegate {
    var onFrame: ((Data) -> Void)?
    var onError: ((String) -> Void)?
    private var parser = MJPEGParser()
    private var client: URLSession?
    private var task: URLSessionDataTask?
    private let frameLock = NSLock()
    private var latest: Data?
    private var deliveryPending = false
    func start(_ url: URL) {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 24 * 60 * 60
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        client = session
        task = session.dataTask(with: url)
        task?.resume()
    }
    func stop() { task?.cancel(); client?.invalidateAndCancel(); client = nil }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if response.mimeType == "image/jpeg", !parser.beginPart(length: response.expectedContentLength) {
            onError?("iOS 画面帧长度无效，请重新连接。")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let frame = parser.append(data).last else { return }
        frameLock.lock()
        latest = frame
        let schedule = !deliveryPending
        deliveryPending = true
        frameLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.frameLock.lock()
            let frame = self.latest
            self.latest = nil; self.deliveryPending = false
            self.frameLock.unlock()
            if let frame { self.onFrame?(frame) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            onError?("iOS 画面流中断：\(error.localizedDescription)")
        }
    }
}

@MainActor
final class IOSSession: NSObject, ObservableObject, NSWindowDelegate {
    let device: IOSDevice
    let team: String
    @Published var image: NSImage?
    @Published var status = "正在准备控制服务，首次连接需要编译…"
    @Published var ready = false
    @Published var preparing = true
    @Published var commandBusy = false
    @Published var text = ""
    var process: Process?
    var onClose: (() -> Void)?
    private var window: NSWindow?
    private var log: FileHandle?
    private var logURL: URL?
    private var queuedTyping = ""
    private var connection: URL?
    private var startup: Task<Void, Never>?
    private var stream: MJPEGReader?
    private var base: URL?
    private var sessionID: String?
    private var closed = false
    private var commandTask: Task<Void, Never>?
    private let http: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.timeoutIntervalForRequest = 12
        return URLSession(configuration: config)
    }()

    init(device: IOSDevice, team: String) { self.device = device; self.team = team }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 840),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "\(device.name) · \(device.udid.suffix(6))"
            window.contentView = NSHostingView(rootView: IOSSessionView(session: self))
            window.minSize = NSSize(width: 380, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func start() {
        guard !closed else { return }
        preparing = true
        status = "正在准备控制服务，首次连接需要编译…"
        do {
            let fm = FileManager.default
            let resources = Bundle.main.resourceURL!
            let cache = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/DeviceMirror/WDA/\(device.udid)")
            let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DeviceMirror")
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            try fm.createDirectory(at: logs, withIntermediateDirectories: true)
            let connection = cache.appendingPathComponent("connection-\(UUID().uuidString).json")
            self.connection = connection
            let logURL = logs.appendingPathComponent("ios-\(UUID().uuidString).log")
            self.logURL = logURL
            fm.createFile(atPath: logURL.path, contents: nil)
            let log = try FileHandle(forWritingTo: logURL)
            self.log = log
            let process = Process()
            process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/device-service")
            process.arguments = [
                                 "--udid", device.udid, "--kind", device.kind, "--team", team,
                                 "--source", resources.appendingPathComponent("WebDriverAgent").path,
                                 "--cache", cache.path, "--connection", connection.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log
            process.standardError = log
            process.terminationHandler = { [weak self] finished in
                Task { @MainActor in
                    guard let self, !self.closed, self.process === finished else { return }
                    let wasConnecting = self.preparing || self.ready
                    self.ready = false
                    self.preparing = false
                    self.startup?.cancel()
                    self.stream?.stop()
                    let details = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                    if wasConnecting {
                        let lines = details.split(separator: "\n")
                        let cause = lines.first { $0.contains("error:") || $0.hasPrefix("ERROR:") }
                        if details.contains("Developer App Certificate is not trusted") {
                            self.status = "iOS 尚未通过开发者应用验证。请先检查设备日期和时间，再到设置 → 通用 → VPN 与设备管理中信任开发者应用。验证需要设备联网。完成后点‘重新连接’。"
                        } else if details.contains("Error Domain=com.apple.LocalAuthentication Code=-2") {
                            self.status = "设备的测试认证未完成。请重新连接，并在 iPhone/iPad 上通过 Touch ID、Face ID 或设备密码完成系统认证。"
                        } else {
                            self.status = "iOS 连接失败（\(finished.terminationStatus)）。\n" + (cause.map(String.init) ?? lines.suffix(5).joined(separator: "\n"))
                        }
                    }
                    try? self.log?.close()
                    self.log = nil
                }
            }
            try process.run()
            self.process = process
            startup = Task { [weak self] in
                guard let self else { return }
                do {
                    for _ in 0..<600 {
                        try Task.checkCancellation()
                        if let data = try? Data(contentsOf: connection),
                           let ports = try JSONSerialization.jsonObject(with: data) as? [String: Int],
                           let httpPort = ports["httpPort"], let videoPort = ports["mjpegPort"] {
                            self.base = URL(string: "http://127.0.0.1:\(httpPort)")!
                            try await self.connect(videoPort: videoPort)
                            return
                        }
                        if let log = try? String(contentsOf: logURL, encoding: .utf8), log.contains("Starting WebDriverAgent…") {
                            self.status = "正在启动 iOS 控制服务…"
                        }
                        try await Task.sleep(nanoseconds: 500_000_000)
                    }
                    throw NSError(domain: "DeviceMirror", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "控制服务启动超时，请打开日志查看原因。"])
                } catch is CancellationError { }
                catch {
                    self.preparing = false
                    self.status = error.localizedDescription
                    if self.process?.isRunning == true { self.process?.terminate() }
                }
            }
        } catch { preparing = false; status = "启动失败：\(error.localizedDescription)"; try? log?.close(); log = nil }
    }

    func retry() {
        guard !closed, !preparing else { return }
        preparing = true
        ready = false
        image = nil
        status = "正在重新连接…"
        startup?.cancel()
        commandTask?.cancel()
        stream?.stop()
        stream = nil
        base = nil
        sessionID = nil
        queuedTyping = ""
        let previous = process
        process = nil
        if previous?.isRunning == true { previous?.terminate() }
        let previousLog = log
        log = nil
        startup = Task {
            await Task.detached {
                previous?.waitUntilExit()
                try? previousLog?.close()
            }.value
            guard !closed, !Task.isCancelled else { return }
            start()
        }
    }

    private func request(_ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 12) async throws -> [String: Any] {
        guard let base else { throw URLError(.notConnectedToInternet) }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = timeout
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let (data, reply) = try await http.data(for: request)
        let milliseconds = Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
        let action = path.hasSuffix("/navigation") ? " action=\(body?["action"] as? String ?? "unknown")" : ""
        let entry = "CONTROL \(path.split(separator: "/").last ?? "request")\(action) \(milliseconds)ms HTTP \((reply as? HTTPURLResponse)?.statusCode ?? 0)\n"
        try? log?.write(contentsOf: Data(entry.utf8))
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let value = response["value"] as? [String: Any]
        if (reply as? HTTPURLResponse)?.statusCode != 200 || value?["error"] != nil {
            let message = value?["message"] as? String ?? String(decoding: data, as: UTF8.self)
            try? log?.write(contentsOf: Data("CONTROL ERROR\(action) \(message)\n".utf8))
            throw NSError(domain: "WebDriverAgent", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return response
    }

    private func connect(videoPort: Int) async throws {
        status = "正在连接画面和控制通道…"
        let reply = try await request("session", body: ["capabilities": ["alwaysMatch": ["shouldWaitForQuiescence": false]]])
        let value = reply["value"] as? [String: Any]
        guard let id = (reply["sessionId"] ?? value?["sessionId"]) as? String else {
            throw NSError(domain: "WebDriverAgent", code: 2, userInfo: [NSLocalizedDescriptionKey: "WDA 未返回会话 ID"])
        }
        sessionID = id
        _ = try await request("session/\(id)/appium/settings", body: ["settings": ["mjpegServerFramerate": 20,
                "mjpegScalingFactor": 50, "mjpegServerScreenshotQuality": 55, "waitForIdleTimeout": 0,
                "animationCoolOffTimeout": 0]])
        let stream = MJPEGReader()
        stream.onFrame = { [weak self] data in
            MainActor.assumeIsolated {
                guard let self, !self.closed, self.ready, let image = NSImage(data: data) else { return }
                self.image = image
            }
        }
        stream.onError = { [weak self] message in
            Task { @MainActor in self?.status = message; self?.ready = false; self?.stream?.stop() }
        }
        self.stream = stream
        stream.start(URL(string: "http://127.0.0.1:\(videoPort)")!)
        preparing = false
        ready = true
        status = "已连接 · 支持点击、滑动、文字和虚拟按键"
    }

    private func perform(success: String = "已连接 · 支持点击、滑动、文字和虚拟按键", _ action: @escaping (String) async throws -> Void) {
        guard ready, let id = sessionID else { return }
        guard !commandBusy else { status = "正在执行上一操作，请稍候。"; return }
        commandBusy = true
        commandTask = Task {
            defer {
                commandBusy = false
                if !Task.isCancelled { flushTyping() }
            }
            do {
                try await action(id)
                if !closed, !Task.isCancelled { status = success }
            } catch is CancellationError { }
            catch { if !closed { status = "操作失败：\(error.localizedDescription)" } }
        }
    }

    func navigation(_ action: String) {
        let label = ["back": "返回", "home": "主页", "appSwitcher": "多任务"][action] ?? action
        perform(success: "\(label)操作已发送") { id in
            let reply = try await self.request("session/\(id)/wda/devicemirror/navigation", body: ["action": action])
            if let method = (reply["value"] as? [String: Any])?["method"] as? String {
                try? self.log?.write(contentsOf: Data("CONTROL RESULT action=\(action) method=\(method)\n".utf8))
            }
        }
    }
    func button(_ name: String) {
        perform { id in _ = try await self.request("session/\(id)/wda/pressButton", body: ["name": name]) }
    }
    func lock(_ lock: Bool) {
        perform { _ in _ = try await self.request(lock ? "wda/lock" : "wda/unlock", body: [:]) }
    }
    // Preserve keyboard characters while a request is running, combining them
    // into the next text request. Pointer and navigation commands never queue.
    func typeText(_ value: String) {
        guard ready, !closed else { return }
        queuedTyping += value
        flushTyping()
    }
    private func flushTyping() {
        guard ready, !closed, !commandBusy, !queuedTyping.isEmpty else { return }
        let value = queuedTyping
        queuedTyping = ""
        perform { id in
            _ = try await self.request("session/\(id)/wda/keys", body: ["value": [value]])
        }
    }
    func sendText(_ value: String) {
        guard !value.isEmpty else { return }
        perform { id in
            _ = try await self.request("session/\(id)/wda/keys", body: ["value": [value]])
            if self.text == value { self.text = "" }
        }
    }
    func tap(_ point: CGPoint) {
        perform { id in
            _ = try await self.request("session/\(id)/wda/devicemirror/tap", body: ["x": point.x, "y": point.y])
        }
    }

    func gesture(_ samples: [IOSTouchSample]) {
        guard samples.count >= 2 else { return }
        perform { id in
            _ = try await self.request("session/\(id)/wda/devicemirror/gesture",
                body: ["points": samples.map { $0.payload }], timeout: max(12, (samples.last?.time ?? 0) + 12))
        }
    }

    func openLog() { if let logURL { NSWorkspace.shared.open(logURL) } }
    func windowWillClose(_ notification: Notification) { stop() }
    func close() { window?.close(); stop() }
    private func stop() {
        guard !closed else { return }
        closed = true
        queuedTyping = ""
        preparing = false
        ready = false
        startup?.cancel()
        commandTask?.cancel()
        stream?.stop()
        http.invalidateAndCancel()
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        if let process {
            let handle = log
            DispatchQueue.global().async { process.waitUntilExit(); try? handle?.close() }
        } else { try? log?.close() }
        onClose?()
        window?.delegate = nil
        window?.contentView = nil
        window = nil
    }
}

struct IOSSessionView: View {
    @ObservedObject var session: IOSSession
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                key("返回", "chevron.left") { session.navigation("back") }
                key("主页", "house") { session.navigation("home") }
                key("多任务", "square.on.square") { session.navigation("appSwitcher") }
                key("锁屏", "lock") { session.lock(true) }
                key("唤醒", "lock.open") { session.lock(false) }
                if !session.device.isSimulator {
                    key("音量减", "speaker.minus") { session.button("volumedown") }
                    key("音量加", "speaker.plus") { session.button("volumeup") }
                }
                Spacer(minLength: 0)
            }.padding(12).disabled(!session.ready || session.commandBusy)
            Divider()
            if let image = session.image {
                IOSCanvas(image: image, tap: session.tap, type: session.typeText, gesture: session.gesture)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 14) {
                    if session.preparing || session.ready {
                        ProgressView()
                        Text(session.ready ? "正在接收画面…" : "正在连接 iOS…").foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.orange)
                        Text("连接未完成").foregroundStyle(.secondary)
                        Button("重新连接") { session.retry() }
                    }
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                TextField("向设备当前输入框发送文字", text: $session.text)
                    .textFieldStyle(.roundedBorder).onSubmit { session.sendText(session.text) }
                Button("发送") { session.sendText(session.text) }
            }.padding(10).disabled(!session.ready || session.commandBusy)
            HStack(alignment: .top) {
                Text(session.status).font(.caption).foregroundStyle(.secondary).lineLimit(5).textSelection(.enabled)
                Spacer()
                if !session.preparing && !session.ready {
                    Button("重试") { session.retry() }.font(.caption)
                }
                Button("日志") { session.openLog() }.font(.caption)
            }.padding(.horizontal, 10).padding(.bottom, 10)
        }
    }
    private func key(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(spacing: 4) { Image(systemName: symbol); Text(title).font(.caption2) } }
            .buttonStyle(.plain).help(title)
    }
}

struct IOSCanvas: NSViewRepresentable {
    let image: NSImage
    let tap: (CGPoint) -> Void
    let type: (String) -> Void
    let gesture: ([IOSTouchSample]) -> Void
    func makeNSView(context: Context) -> IOSCanvasView { IOSCanvasView() }
    func updateNSView(_ view: IOSCanvasView, context: Context) {
        view.image = image; view.tap = tap; view.type = type; view.gesture = gesture; view.needsDisplay = true
    }
    static func dismantleNSView(_ view: IOSCanvasView, coordinator: ()) { view.cancelTouch() }
}


struct IOSLauncherView: View {
    @ObservedObject var model: IOSManager
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("iPhone / iPad").font(.title2.bold())
                    Text("USB 真机与模拟器 · 每台设备独立连接").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.refreshing { ProgressView().controlSize(.small) }
                Button("刷新") { model.refresh() }.disabled(model.refreshing)
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(model.devices.filter { $0.isSimulator || $0.isUSBMirror || model.showDeviceControl }) { device in
                        HStack(spacing: 12) {
                            Image(systemName: device.isSimulator ? "iphone.gen3" : "cable.connector")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(device.name).font(.system(size: 13, weight: .semibold))
                                Text(device.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.active.contains(device.id) {
                                Button("显示") { model.open(device) }
                                Button("停止") { model.stop(device) }
                            } else {
                                Button(device.isUSBMirror ? "查看镜像" : device.isSimulator && device.state != "Booted" ? "启动并连接" : "连接") { model.open(device) }
                            }
                        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                    }
                    if !model.devices.contains(where: { $0.isSimulator || $0.isUSBMirror || model.showDeviceControl }) {
                        Text("请用 USB 连接并解锁 iPhone/iPad，在设备上允许信任此电脑。模拟器需要安装 Xcode 和 iOS Runtime。")
                        .foregroundStyle(.secondary).padding(30) }
                }
            }.frame(height: 300)
            Divider()
            Text("观看真机画面请选择“查看镜像”；从电脑操控请选择“USB 操控”。首次观看需允许采集权限，USB 操控需先配置下方 Apple 账号。")
                .font(.caption).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("USB 操控：配置 Apple 账号", isExpanded: $model.showDeviceControl) {
                IOSSigningView(model: model).padding(.top, 8)
            }.onChange(of: model.showDeviceControl) { _, expanded in if expanded { model.detectSigning() } }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
        }.padding(26).frame(width: 560).onAppear {
            model.begin()
            if model.showDeviceControl { model.detectSigning() }
        }
    }
}

private struct IOSSigningView: View {
    @ObservedObject var model: IOSManager
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("首次在 Xcode → Settings → Apple Accounts 登录，再点“重新检测”。连接设备时会自动签名、安装并启动 USB 控制组件。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("打开 Xcode 登录…") { model.openXcode() }
                Button(model.detectingSigning ? "检测中…" : "重新检测") { model.detectSigning() }.disabled(model.detectingSigning)
            }
            if model.signingTeams.count == 1, let team = model.signingTeams.first {
                Text("开发团队：\(team.name)（自动使用）").font(.callout)
            } else if model.signingTeams.count > 1 {
                Picker("开发团队", selection: $model.selectedSigningTeam) {
                    Text("请选择团队").tag("")
                    ForEach(model.signingTeams) { team in Text("\(team.name) · \(team.id)").tag(team.id) }
                }
            } else {
                TextField("未识别到团队时，可手动输入 Team ID", text: $model.team).textFieldStyle(.roundedBorder)
            }
            Text(model.signingStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("首次连接需解锁设备、信任电脑并开启开发者模式；按设备提示完成开发者应用信任及测试认证。签名有效期受 Apple 账号权限限制，到期需联网续签。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
