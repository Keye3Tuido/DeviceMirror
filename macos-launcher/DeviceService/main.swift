// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation
import Darwin

let stop = ServiceStop()
let signals = [SIGTERM, SIGINT].map { value -> DispatchSourceSignal in
    signal(value, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: value, queue: .global())
    source.setEventHandler { stop.stop() }; source.resume(); return source
}
for name in ["CPATH", "C_INCLUDE_PATH", "CPLUS_INCLUDE_PATH", "OBJC_INCLUDE_PATH", "LIBRARY_PATH", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET"] { unsetenv(name) }

func command(_ path: String, _ arguments: [String], timeout: Double = 15) throws -> String {
    let result = try CommandRunner.run(URL(fileURLWithPath: path), arguments, timeout: timeout)
    guard result.status == 0, !result.timedOut else { throw serviceError(result.output.isEmpty ? "执行失败：\(path)" : result.output) }
    return result.output
}
func listDevices() -> [String: Any] {
    var devices: [[String: String]] = []
    if let output = try? command("/usr/bin/xcrun", ["simctl", "list", "devices", "available", "-j"], timeout: 12),
       let value = (try? JSONSerialization.jsonObject(with: Data(output.utf8))) as? [String: Any],
       let runtimes = value["devices"] as? [String: [[String: Any]]] {
        for (runtime, rows) in runtimes.sorted(by: { $0.key < $1.key }) where runtime.contains(".iOS-") {
            for row in rows {
                if let id = row["udid"] as? String, let name = row["name"] as? String, let state = row["state"] as? String {
                    devices.append(["udid": id, "name": name, "kind": "simulator", "state": state])
                }
            }
        }
    }
    for device in (try? USBMux.identities()) ?? [] {
        devices.append(["udid": device.id, "name": device.name, "kind": "device", "state": "USB"])
    }
    return ["devices": devices]
}

func runSession(_ options: [String: String]) throws {
    let fm = FileManager.default
    guard let udid = options["--udid"], let kind = options["--kind"], ["device", "simulator"].contains(kind),
          let sourcePath = options["--source"], let cachePath = options["--cache"], let connectionPath = options["--connection"] else {
        throw serviceError("session requires --udid, --kind, --source, --cache, --connection")
    }
    let simulator = kind == "simulator"
    let source = URL(fileURLWithPath: sourcePath).standardizedFileURL
    let cache = URL(fileURLWithPath: cachePath).appendingPathComponent("build-v3")
    let connection = URL(fileURLWithPath: connectionPath)
    try fm.createDirectory(at: cache, withIntermediateDirectories: true)
    let lockFD = Darwin.open(cache.appendingPathComponent("session.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lockFD >= 0 else { throw POSIXError(.EIO) }
    _ = fcntl(lockFD, F_SETFD, FD_CLOEXEC)
    defer { Darwin.close(lockFD) }
    guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw serviceError("此设备已有控制会话，请先关闭该设备的其他控制窗口。") }
    let xcodebuild = try command("/usr/bin/xcrun", ["--find", "xcodebuild"]).trimmingCharacters(in: .whitespacesAndNewlines)
    var child: ServiceChild?
    var forwarders: [USBForwarder] = []
    var runStarted = false
    defer {
        if let child { child.terminate() }
        forwarders.forEach { $0.stop() }
        if simulator && runStarted {
            _ = try? command("/usr/bin/xcrun", ["simctl", "terminate", udid, "com.facebook.WebDriverAgentRunner.xctrunner"], timeout: 10)
        }
        try? fm.removeItem(at: connection)
    }
    func execute(_ executable: String, _ arguments: [String]) throws {
        if stop.stopped { throw CancellationError() }
        let launched = try ServiceChild(executable, arguments); child = launched
        while true {
            if stop.stopped { throw CancellationError() }
            if let result = launched.poll() {
                child = nil
                guard result == 0 else { throw serviceError("命令退出（\(result)），请查看构建日志：\(executable)") }
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    var team = ""
    if simulator {
        _ = try? command("/usr/bin/xcrun", ["simctl", "boot", udid], timeout: 30)
        try execute("/usr/bin/xcrun", ["simctl", "bootstatus", udid, "-b"])
    } else {
        team = try ServiceSigning.choose(options["--team"] ?? "", teams: ServiceSigning.info()["teams"] as? [[String: String]] ?? [])
        servicePrint("SIGNING_TEAM " + team)
    }
    let products = cache.appendingPathComponent("Build/Products")
    let sdk = simulator ? "iphonesimulator" : "iphoneos"
    let metadata = cache.appendingPathComponent("device-mirror-build.json")
    let version = try String(contentsOf: source.appendingPathComponent("DEVICE_MIRROR_VERSION"), encoding: .utf8)
    let fingerprint = try serviceJSON(["team": team, "source": source.path, "version": version, "xcode": try command(xcodebuild, ["-version"])])
    func builtProducts() -> [URL] {
        ((try? fm.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "xctestrun" && $0.lastPathComponent.contains(sdk) }.sorted { $0.path < $1.path }
    }
    if builtProducts().isEmpty || (try? Data(contentsOf: metadata)) != fingerprint || (!simulator && !ServiceSigning.usableProfiles(in: products, team: team)) {
        servicePrint("Preparing WebDriverAgent…")
        var args = ["-project", source.appendingPathComponent("WebDriverAgent.xcodeproj").path, "-scheme", "WebDriverAgentRunner", "-configuration", "Debug", "-destination", "id=" + udid, "-derivedDataPath", cache.path, "CPATH=", "LIBRARY_PATH=", "build-for-testing"]
        args += simulator ? ["CODE_SIGNING_ALLOWED=NO"] : ["-allowProvisioningUpdates", "-allowProvisioningDeviceRegistration", "CODE_SIGN_STYLE=Automatic", "CODE_SIGN_IDENTITY=Apple Development", "DEVELOPMENT_TEAM=" + team, "PRODUCT_BUNDLE_IDENTIFIER=com.keye3tuido.DeviceMirror.WDARunner." + team.lowercased()]
        try execute(xcodebuild, args)
        try fingerprint.write(to: metadata, options: .atomic)
    }
    guard let built = builtProducts().first else { throw serviceError("Xcode 未生成控制组件。") }
    let httpPort: UInt16, mjpegPort: UInt16
    if simulator {
        httpPort = try USBForwarder.availablePort()
        mjpegPort = try USBForwarder.availablePort()
        guard httpPort != mjpegPort else { throw serviceError("端口分配冲突，请重新连接。") }
    } else {
        forwarders = try [USBForwarder(udid: udid, remotePort: 8100), USBForwarder(udid: udid, remotePort: 9100)]
        httpPort = forwarders[0].port; mjpegPort = forwarders[1].port
    }
    guard var config = try PropertyListSerialization.propertyList(from: Data(contentsOf: built), format: nil) as? [String: Any] else { throw serviceError("无效的测试配置。") }
    let token = UUID().uuidString
    for key in Array(config.keys) where !key.hasPrefix("__") {
        guard var entry = config[key] as? [String: Any] else { continue }
        var env = entry["EnvironmentVariables"] as? [String: String] ?? [:]
        env.merge(["USE_PORT": String(simulator ? httpPort : 8100), "MJPEG_SERVER_PORT": String(simulator ? mjpegPort : 9100), "USE_IP": "127.0.0.1", "DEVICE_MIRROR_SESSION_TOKEN": token]) { _, new in new }
        entry["EnvironmentVariables"] = env; config[key] = entry
    }
    let sessionConfig = products.appendingPathComponent("DeviceMirror-session.xctestrun")
    try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0).write(to: sessionConfig, options: .atomic)
    servicePrint("Starting WebDriverAgent…")
    let runner = try ServiceChild(xcodebuild, ["test-without-building", "-xctestrun", sessionConfig.path, "-destination", "id=" + udid, "-parallel-testing-enabled", "NO", "-resultBundlePath", cache.appendingPathComponent("Run-\(UUID().uuidString).xcresult").path])
    child = runner; runStarted = true
    let settings = URLSessionConfiguration.ephemeral
    settings.connectionProxyDictionary = [:]; settings.timeoutIntervalForRequest = 2
    let http = URLSession(configuration: settings)
    defer { http.invalidateAndCancel() }
    let base = "http://127.0.0.1:\(httpPort)"
    let deadline = Date().addingTimeInterval(180)
    var ready = false
    while !stop.stopped && Date() < deadline {
        if runner.poll() != nil { child = nil; throw serviceError("WebDriverAgent 启动失败，请检查签名、设备信任和测试认证。") }
        let completion = DispatchSemaphore(value: 0)
        let result = ServiceStop()
        let request = http.dataTask(with: URL(string: base + "/wda/devicemirror/info")!) { data, response, _ in
            if let data, (response as? HTTPURLResponse)?.statusCode == 200,
               let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let value = reply["value"] as? [String: Any], value["token"] as? String == token { result.stop() }
            completion.signal()
        }
        request.resume(); _ = completion.wait(timeout: .now() + 3); request.cancel()
        if result.stopped { ready = true; break }
        Thread.sleep(forTimeInterval: 0.3)
    }
    if stop.stopped { return }
    guard ready else { throw serviceError("等待控制服务超时，请检查设备解锁、信任和开发者模式。") }
    try serviceJSON(["httpPort": Int(httpPort), "mjpegPort": Int(mjpegPort)]).write(to: connection, options: .atomic)
    servicePrint("READY " + base)
    while !stop.stopped {
        if runner.poll() != nil { child = nil; throw serviceError("WebDriverAgent 已断开。") }
        Thread.sleep(forTimeInterval: 0.1)
    }
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--list"] { FileHandle.standardOutput.write(try serviceJSON(listDevices()) + Data([10])) }
    else if args == ["--signing-info"] { FileHandle.standardOutput.write(try serviceJSON(ServiceSigning.info()) + Data([10])) }
    else {
        guard args.count % 2 == 0 else { throw serviceError("参数需要键和值。") }
        var options: [String: String] = [:]
        for index in stride(from: 0, to: args.count, by: 2) { options[args[index]] = args[index + 1] }
        try runSession(options)
    }
} catch is CancellationError { }
catch { FileHandle.standardError.write(Data(("ERROR: " + error.localizedDescription + "\n").utf8)); exit(1) }
withExtendedLifetime(signals) { }
