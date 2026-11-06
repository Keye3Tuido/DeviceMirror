// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation

struct IOSControlSupport {
    let version: String
    var supported: Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let major = Int(parts[0]) else { return false }
        return major >= 27
    }
    var message: String {
        version.isEmpty ? "无法确认系统版本，控制不可用。请刷新设备列表；控制需要 iOS / iPadOS 27 或以上。"
            : "当前系统 \(version) 不支持控制；需要 iOS / iPadOS 27 或以上。可使用观看镜像。"
    }
}

// A move can replace only the immediately preceding move. Down/up/cancel and
// different inputs retain their order, including the last move before release.
final class IOSInputBuffer {
    private let lock = NSLock()
    private var pending: [[String: Any]] = []
    func append(_ event: [String: Any]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if event["type"] as? String == "touch", event["phase"] as? String == "move",
           pending.last?["type"] as? String == "touch", pending.last?["phase"] as? String == "move" {
            pending[pending.count - 1] = event; return true
        }
        guard pending.count < 64 else { return false }
        pending.append(event); return true
    }
    func clear() { lock.lock(); pending.removeAll(); lock.unlock() }
    func take() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending.removeAll(keepingCapacity: true); return result
    }
}

@MainActor final class IOSLiveInput {
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var response = Data()
    private let buffer = IOSInputBuffer()
    private let writer = DispatchQueue(label: "DeviceMirror.ios.input.\(UUID().uuidString)")
    private var timer: Timer?
    private var starting: Timer?
    private var stopped = false
    private var connected = false
    private var writing = false
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    func start(udid: String, kind: String, log: FileHandle?) throws {
        let child = Process(), incoming = Pipe(), outgoing = Pipe()
        child.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ios-input")
        child.arguments = ["--udid", udid, "--kind", kind]
        child.standardInput = incoming; child.standardOutput = outgoing
        child.standardError = log ?? FileHandle.nullDevice
        input = incoming.fileHandleForWriting; output = outgoing.fileHandleForReading
        output?.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in self?.receive(data) }
        }
        child.terminationHandler = { [weak self] child in
            Task { @MainActor in
                guard let self, !self.stopped else { return }
                self.fail("实时输入服务已断开（\(child.terminationStatus)）。请重新连接。")
            }
        }
        try child.run(); process = child
        // One writer, bounded batches and a 120 Hz drain keep pipe I/O off the UI.
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 120, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.drain() }
        }
        starting = Timer.scheduledTimer(withTimeInterval: 80, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fail("实时输入通道启动超时，请检查 Xcode、设备解锁及开发者模式。") }
        }
    }
    private func receive(_ data: Data) {
        guard !stopped, !data.isEmpty else { output?.readabilityHandler = nil; return }
        response.append(data)
        guard response.count <= 65536 else { fail("实时输入服务返回了无效数据。"); return }
        while let end = response.firstIndex(of: 10) {
            let line = response.prefix(upTo: end); response.removeSubrange(...end)
            guard let value = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            if let error = value["error"] as? String { fail(error); return }
            if value["ready"] as? Bool == true, !connected {
                connected = true; starting?.invalidate(); starting = nil; onReady?()
            }
        }
    }
    func send(_ event: [String: Any]) {
        guard connected, !stopped else { return }
        guard buffer.append(event) else { fail("输入积压，已停止控制并释放按键。请重新连接。"); return }
        // Transitions bypass the next timer tick; moves are coalesced at 120 Hz.
        if event["phase"] as? String != "move" { drain() }
    }
    private func drain() {
        guard !writing, !stopped else { return }
        let batch = buffer.take()
        guard !batch.isEmpty, let input else { return }
        writing = true
        writer.async { [weak self] in
            do {
                var data = Data()
                for event in batch { data.append(try JSONSerialization.data(withJSONObject: event)); data.append(10) }
                try input.write(contentsOf: data)
                Task { @MainActor in
                    self?.writing = false
                    self?.drain()
                }
            } catch {
                Task { @MainActor in self?.fail("实时输入发送失败：\(error.localizedDescription)") }
            }
        }
    }
    private func fail(_ message: String) {
        guard !stopped else { return }
        let callback = onFailure; stop(); callback?(message)
    }
    func stop() {
        guard !stopped else { return }
        buffer.clear()
        stopped = true; connected = false
        timer?.invalidate(); starting?.invalidate(); timer = nil; starting = nil
        output?.readabilityHandler = nil; try? output?.close(); output = nil
        if let input { writer.async { try? input.close() } }; input = nil
        if let child = process {
            // EOF lets the helper release inputs and its media lease before exit.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if child.isRunning { child.terminate() }
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if child.isRunning { kill(child.processIdentifier, SIGKILL) }
                }
            }
        }
        process = nil
    }
}
