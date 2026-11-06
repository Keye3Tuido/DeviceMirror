// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation

final class AndroidLogRecorder {
    let process = Process()
    let url: URL
    private let file: FileHandle
    private(set) var stopping = false

    init(adb: URL, serial: String, directory: URL, onExit: @escaping (Int32) -> Void) throws {
        url = directory.appendingPathComponent("logcat-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        file = try FileHandle(forWritingTo: url)
        process.executableURL = adb
        // -T 1 starts at the latest record, preserving the device's log buffers.
        process.arguments = ["-s", serial, "logcat", "-v", "threadtime", "-T", "1"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = file
        process.standardError = file
        let file = self.file
        process.terminationHandler = { finished in
            try? file.close()
            onExit(finished.terminationStatus)
        }
        do { try process.run() }
        catch { try? file.close(); throw error }
    }

    func stop() {
        stopping = true
        guard process.isRunning else { return }
        process.terminate()
        let process = self.process
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }
}
