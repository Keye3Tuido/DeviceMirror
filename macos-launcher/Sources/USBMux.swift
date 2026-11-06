// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Darwin
import Foundation

struct USBIdentity: Identifiable, Equatable {
    let id: String
    let name: String
    var osVersion: String = ""
}

// Resolve device identities through the usbmuxd service provided by macOS.
enum USBMux {
    static func identities() throws -> [USBIdentity] {
        let mux = try MuxSocket()
        let reply = try mux.request(["MessageType": "ListDevices"])
        let rows = reply["DeviceList"] as? [[String: Any]] ?? []
        return rows.compactMap { row in
            guard let props = row["Properties"] as? [String: Any], props["ConnectionType"] as? String == "USB",
                  let udid = props["SerialNumber"] as? String, let deviceID = row["DeviceID"] as? Int else { return nil }
            let values = (try? deviceValues(deviceID)) ?? [:]
            return USBIdentity(id: udid, name: values["DeviceName"] as? String ?? "iOS USB",
                osVersion: values["ProductVersion"] as? String ?? "")
        }
    }

    private static func deviceValues(_ deviceID: Int) throws -> [String: Any] {
        let connection = try MuxSocket()
        let reply = try connection.request(["MessageType": "Connect", "DeviceID": deviceID,
                                            "PortNumber": UInt16(62078).bigEndian])
        guard reply["Number"] as? Int == 0 else { throw CocoaError(.fileReadUnknown) }
        let payload = try PropertyListSerialization.data(fromPropertyList:
            ["Request": "GetValue", "Label": "DeviceMirror"], format: .xml, options: 0)
        var size = UInt32(payload.count).bigEndian
        try connection.write(withUnsafeBytes(of: &size) { Data($0) } + payload)
        let header = try connection.read(4)
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length < 4 * 1024 * 1024 else { throw CocoaError(.fileReadCorruptFile) }
        let value = try PropertyListSerialization.propertyList(from: connection.read(Int(length)), format: nil) as? [String: Any]
        guard let values = value?["Value"] as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return values
    }
}

final class MuxSocket {
    let fd: Int32
    init(adopting descriptor: Int32) { fd = descriptor; _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    init() throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout.size(ofValue: yes)))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array("/var/run/usbmuxd".utf8CString)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        address.sun_len = UInt8(MemoryLayout.size(ofValue: address))
        let addressLength = socklen_t(address.sun_len)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, addressLength) }
        }
        if result != 0 { Darwin.close(fd); throw POSIXError(.ECONNREFUSED) }
    }
    deinit { Darwin.close(fd) }

    func write(_ data: Data) throws {
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.send(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }
    func read(_ length: Int) throws -> Data {
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { raw in
            var offset = 0
            while offset < length {
                let count = Darwin.recv(fd, raw.baseAddress!.advanced(by: offset), length - offset, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        return data
    }
    func request(_ fields: [String: Any]) throws -> [String: Any] {
        var request = fields
        request.merge(["BundleID": "com.keye3tuido.devicemirror", "ClientVersionString": "DeviceMirror-1.0",
                       "ProgName": "DeviceMirror", "kLibUSBMuxVersion": 3]) { current, _ in current }
        let body = try PropertyListSerialization.data(fromPropertyList: request, format: .xml, options: 0)
        let header: [UInt32] = [UInt32(body.count + 16).littleEndian, 1, 8, 1]
        try write(header.withUnsafeBytes { Data($0) } + body)
        let response = [UInt8](try read(16))
        func word(_ index: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | (UInt32(response[index * 4 + $1]) << ($1 * 8)) }
        }
        let length = word(0)
        guard word(1) == 1, word(2) == 8, length >= 16, length <= 4 * 1024 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let result = try PropertyListSerialization.propertyList(from: read(Int(length) - 16), format: nil) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return result
    }
}
