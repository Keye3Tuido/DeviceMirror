// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation
import CoreGraphics

func testMirrorFeatures() throws {
    let bounds = CGRect(x: 0, y: 0, width: 848, height: 648)
    let rect = MirrorGeometry.imageRect(in: bounds, size: CGSize(width: 800, height: 600))
    precondition(rect == CGRect(x: 24, y: 24, width: 800, height: 600))
    let tall = MirrorGeometry.imageRect(in: bounds, size: CGSize(width: 600, height: 800))
    precondition(tall.minX >= 24 && tall.minY >= 24 && tall.maxX <= 824 && tall.maxY <= 624)
    let small = MirrorGeometry.imageRect(in: CGRect(x: 0, y: 0, width: 40, height: 40), size: CGSize(width: 1, height: 1))
    precondition(small == CGRect(x: 10, y: 10, width: 20, height: 20))
    for (point, expected) in [
        (CGPoint(x: -10, y: -10), CGPoint(x: 0, y: 0)),
        (CGPoint(x: 900, y: 700), CGPoint(x: 1, y: 1)),
        (CGPoint(x: 0, y: 324), CGPoint(x: 0, y: 0.5)),
        (CGPoint(x: 848, y: 324), CGPoint(x: 1, y: 0.5)),
        (CGPoint(x: 424, y: 0), CGPoint(x: 0.5, y: 0)),
        (CGPoint(x: 424, y: 648), CGPoint(x: 0.5, y: 1))
    ] { precondition(MirrorGeometry.normalized(point, in: rect) == expected) }
    let native = CGSize(width: 820, height: 1180)
    precondition(MirrorGeometry.orientedSize(native, image: CGSize(width: 1180, height: 820)) == CGSize(width: 1180, height: 820))
    precondition(MirrorGeometry.orientedSize(native, image: native) == native)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceMirror-log-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let adb = directory.appendingPathComponent("fake-adb")
    try Data("#!/bin/sh\nprintf '%s\\n' \"$@\"\nprintf '中文日志\\n'\nexec /bin/sleep 30\n".utf8).write(to: adb)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: adb.path)
    let exitA = DispatchSemaphore(value: 0), exitB = DispatchSemaphore(value: 0)
    let a = try AndroidLogRecorder(adb: adb, serial: "device A;$(exit)", directory: directory) { _ in exitA.signal() }
    let b = try AndroidLogRecorder(adb: adb, serial: "device-B", directory: directory) { _ in exitB.signal() }
    defer { a.stop(); b.stop() }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
        let dataA = (try? String(contentsOf: a.url, encoding: .utf8)) ?? ""
        let dataB = (try? String(contentsOf: b.url, encoding: .utf8)) ?? ""
        if dataA.contains("中文日志") && dataB.contains("中文日志") { break }
        Thread.sleep(forTimeInterval: 0.02)
    }
    let contentA = try String(contentsOf: a.url, encoding: .utf8)
    let contentB = try String(contentsOf: b.url, encoding: .utf8)
    precondition(a.url != b.url && contentA.contains("device A;$(exit)\nlogcat\n-v\nthreadtime\n-T\n1\n中文日志"))
    precondition(contentB.contains("device-B") && !contentB.contains("device A"))
    a.stop()
    precondition(exitA.wait(timeout: .now() + 4) == .success)
    precondition(!a.process.isRunning && b.process.isRunning)
    b.stop()
    precondition(exitB.wait(timeout: .now() + 4) == .success && !b.process.isRunning)
    print("PASS: 留白/四边坐标/旋转/独立日志进程/Unicode日志/停止隔离")
}
