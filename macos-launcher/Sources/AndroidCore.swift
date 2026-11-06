// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation

struct AndroidDevice: Identifiable, Equatable {
    let serial: String
    let state: String
    let model: String
    var id: String { serial }
    var isReady: Bool { state == "device" }
    var stateLabel: String {
        switch state {
        case "device": return "已连接"
        case "unauthorized": return "请在设备上允许 USB 调试"
        case "offline": return "设备离线，请重新连接"
        default: return state
        }
    }

    static func parse(_ output: String) -> [AndroidDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"),
                  !line.hasPrefix("*"), !line.hasPrefix("adb:") else { return nil }
            let knownStates = ["device", "unauthorized", "offline", "recovery", "sideload", "bootloader", "no"]
            guard knownStates.contains(fields[1]) else { return nil }
            let model = fields.first(where: { $0.hasPrefix("model:") })
                .map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
            return AndroidDevice(serial: fields[0], state: fields[1], model: model ?? fields[0])
        }
    }
}

struct MirrorOptions {
    var maxSize = 1920
    var fps = 60
    var audio = false
    var stayAwake = true
    var recordLogs = false

    func arguments(for device: AndroidDevice) -> [String] {
        var args = ["--serial", device.serial, "--window-title", "Device Mirror · \(device.model) · \(device.serial.suffix(6))",
                    "--max-fps", String(fps), "--video-bit-rate", "8M",
                    "--window-height", "720", "--prefer-text", "--no-clipboard-autosync", "--legacy-paste"]
        if maxSize > 0 { args += ["--max-size", String(maxSize)] }
        if !audio { args.append("--no-audio") }
        if stayAwake { args.append("--stay-awake") }
        return args
    }
}

struct CommandResult {
    let status: Int32
    let output: String
    let timedOut: Bool
}

enum CommandRunner {
    // File-backed output avoids pipe backpressure when adb emits diagnostics.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 8, input: Data? = nil) throws -> CommandResult {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("android-mirror-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: outputURL) }
        // A private file also avoids stdin pipe backpressure and keeps text out of argv.
        let inputURL = FileManager.default.temporaryDirectory.appendingPathComponent("device-mirror-\(UUID().uuidString).input")
        var inputHandle: FileHandle?
        defer { try? inputHandle?.close(); try? FileManager.default.removeItem(at: inputURL) }
        if let input {
            guard FileManager.default.createFile(atPath: inputURL.path, contents: input,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            inputHandle = try FileHandle(forReadingFrom: inputURL)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = handle
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        let timedOut = completed.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return CommandResult(status: process.terminationStatus, output: output, timedOut: timedOut)
    }
}
