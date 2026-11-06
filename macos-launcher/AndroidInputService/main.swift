// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation
import Darwin

private let inputMethod = "com.keye3tuido.devicemirror.input/.TextInputService"
private let actionPrefix = "com.keye3tuido.devicemirror.input."
private func failure(_ message: String) -> NSError {
    NSError(domain: "DeviceMirror.AndroidInput", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

private func send() throws {
    let args = CommandLine.arguments
    guard args.count == 4 else { throw failure("文本服务参数不完整。") }
    let adb = URL(fileURLWithPath: args[1]), serial = args[2], apk = args[3]
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty, data.count <= 65536, String(data: data, encoding: .utf8) != nil else {
        throw failure("请输入不超过 64 KiB 的有效 UTF-8 文本。")
    }
    func run(_ arguments: [String], timeout: Double = 10) throws -> String {
        let result = try CommandRunner.run(adb, ["-s", serial] + arguments, timeout: timeout)
        guard result.status == 0, !result.timedOut else {
            // Broadcast output may echo its extras. Keep input out of logs/errors.
            throw failure(result.timedOut ? "设备文本服务响应超时，请检查连接。" : "设备拒绝文本输入命令，请检查 USB 调试权限。")
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let previous = try run(["shell", "settings", "get", "secure", "default_input_method"])
    guard !previous.isEmpty, previous != "null", previous != inputMethod else {
        throw failure("请先在设备上选择常用输入法，再重试发送。")
    }
    let enabled = try run(["shell", "ime", "list", "-s"]).split(whereSeparator: \.isNewline).contains(Substring(inputMethod))
    if ((try? run(["shell", "pm", "path", "com.keye3tuido.devicemirror.input"])) ?? "").isEmpty {
        let installed: String
        do { installed = try run(["install", "-r", "--no-streaming", apk], timeout: 45) }
        catch { throw failure("无法安装文本输入组件，请在设备上允许 USB 安装。") }
        guard installed.contains("Success") else { throw failure("无法安装 Device Mirror 文本输入组件。") }
    }
    var selected = false
    var restored = false
    func restore() throws {
        // Respect a new input-method choice made on the device while sending.
        let current = try run(["shell", "settings", "get", "secure", "default_input_method"])
        if current == inputMethod { _ = try run(["shell", "ime", "set", previous]) }
        if !enabled { _ = try run(["shell", "ime", "disable", inputMethod]) }
        restored = true
    }
    defer {
        if selected && !restored {
            do { try restore() }
            catch { fputs("发送结束后未能恢复输入法，请在设备上切回常用输入法。\n", stderr) }
        }
    }
    _ = try run(["shell", "ime", "enable", inputMethod])
    selected = true
    _ = try run(["shell", "ime", "set", inputMethod])
    var ready = false
    for _ in 0..<30 {
        let output = try run(["shell", "am", "broadcast", "--user", "current", "-a", actionPrefix + "PING", "-p", "com.keye3tuido.devicemirror.input"])
        if output.contains("result=1") { ready = true; break }
        Thread.sleep(forTimeInterval: 0.1)
    }
    guard ready else { throw failure("未找到可输入的焦点，请先点击设备中的输入框。") }
    let result: String
    do {
        result = try run(["shell", "am", "broadcast", "--user", "current", "-a", actionPrefix + "COMMIT", "-p", "com.keye3tuido.devicemirror.input", "--es", "text", data.base64EncodedString()])
    } catch {
        throw failure("发送结果未确认，文本可能已送达。请先检查设备内容，避免重复发送。")
    }
    // A commit is sent once. An uncertain result must never retry insertion.
    let committed = result.contains("result=1")
    do { try restore() }
    catch { throw failure(committed ? "文本已发送，但恢复输入法失败，请在设备上切回常用输入法。" : "文本未发送，恢复输入法失败，请在设备上切回常用输入法。") }
    guard committed else { throw failure("输入框未接受文本；请确认设备当前焦点后重试。") }
}

do { try send() }
catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
