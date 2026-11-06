// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation

@main
struct CoreTests {
    static func main() throws {
        try testMirrorFeatures()
        let devices = AndroidDevice.parse("""
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        R9PW10F5J5N device usb:2-1.1 product:gta8wifizc model:SM_X200 device:gta8wifi transport_id:1
        unknown unauthorized usb:2-2 transport_id:2
        192.168.1.2:5555 offline transport_id:3

        """)
        precondition(devices.count == 3)
        precondition(devices[0].isReady && devices[0].model == "SM X200")
        precondition(!devices[1].isReady && devices[1].stateLabel.contains("允许"))
        precondition(devices[2].serial == "192.168.1.2:5555" && !devices[2].isReady)
        precondition(AndroidDevice.parse("List of devices attached\n\n").isEmpty)
        precondition(AndroidDevice.parse("adb: error: device not found\n").isEmpty)
        let unusual = AndroidDevice(serial: "serial with spaces;$(exit)", state: "device", model: "test")
        let args = MirrorOptions().arguments(for: unusual)
        precondition(args.contains("--prefer-text") && args.contains("--no-clipboard-autosync") && args.contains("--legacy-paste"))
        precondition(args[1] == unusual.serial) // one argv element, never a shell command
        precondition(args.contains("--no-audio") && args.contains("--stay-awake"))
        var options = MirrorOptions()
        options.maxSize = 0; options.audio = true; options.stayAwake = false
        let full = options.arguments(for: devices[0])
        precondition(!full.contains("--max-size") && !full.contains("--no-audio") && !full.contains("--stay-awake"))
        let success = try CommandRunner.run(URL(fileURLWithPath: "/usr/bin/printf"), ["%s", unusual.serial])
        precondition(success.status == 0 && success.output == unusual.serial && !success.timedOut)
        let failure = try CommandRunner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo failure >&2; exit 7"])
        precondition(failure.status == 7 && failure.output.contains("failure"))
        let payload = "中文 \"'$(exit)\nsecond line 🐱"
        let stdin = try CommandRunner.run(URL(fileURLWithPath: "/bin/cat"), [], input: Data(payload.utf8))
        precondition(stdin.status == 0 && stdin.output == payload)
        let start = Date()
        let timeout = try CommandRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], timeout: 0.1)
        precondition(timeout.timedOut && Date().timeIntervalSince(start) < 3)
        do {
            _ = try CommandRunner.run(URL(fileURLWithPath: "/missing/android-mirror-adb"), [])
            preconditionFailure("missing executable must throw")
        } catch { /* expected */ }
        var parser = MJPEGParser()
        let frame1 = Data([0xFF, 0xD8, 1, 0xFF, 0xD9])
        let frame2 = Data([0xFF, 0xD8, 2, 0xFF, 0xD9])
        func chunk(_ data: Data) -> Data {
            Data("--BoundaryString\r\nContent-type: image/jpeg\r\nContent-Length: \(data.count)\r\n\r\n".utf8) + data + Data("\r\n\r\n".utf8)
        }
        let wire = chunk(frame1) + chunk(frame2)
        var received: [Data] = []
        for byte in wire { received += parser.append(Data([byte])) }
        precondition(received == [frame1, frame2])
        precondition(parser.append(chunk(frame1) + chunk(frame2)) == [frame1, frame2])
        precondition(parser.append(Data("--bad\r\nContent-Length:\r\n\r\n".utf8)).isEmpty)
        precondition(parser.append(chunk(frame1)) == [frame1])
        precondition(parser.beginPart(length: Int64(frame1.count)))
        precondition(parser.append(Data(frame1.prefix(2))).isEmpty)
        precondition(parser.append(Data(frame1.dropFirst(2))) == [frame1])
        precondition(parser.beginPart(length: Int64(frame2.count)))
        precondition(parser.append(frame2) == [frame2])
        precondition(!parser.beginPart(length: -1))
        precondition(!parser.beginPart(length: 17 * 1024 * 1024))
        print("PASS: 设备状态/参数隔离/画质/命令/Unicode stdin/超时清理/MJPEG 分包/连续帧/错误头恢复")
    }
}
