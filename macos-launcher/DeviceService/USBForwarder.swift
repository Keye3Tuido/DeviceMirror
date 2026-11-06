// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation
import Darwin

final class USBForwarder {
    let port: UInt16
    private let listener: Int32
    private let stopping = ServiceStop()
    private let listenerLock = NSLock()
    private var listenerOpen = true
    private let connect: () throws -> MuxSocket

    init(udid: String, remotePort: UInt16, connector: (() throws -> MuxSocket)? = nil) throws {
        connect = connector ?? {
            let mux = try MuxSocket()
            let rows = try mux.request(["MessageType": "ListDevices"])["DeviceList"] as? [[String: Any]] ?? []
            guard let device = rows.first(where: {
                let props = $0["Properties"] as? [String: Any]
                return props?["ConnectionType"] as? String == "USB" && props?["SerialNumber"] as? String == udid
            }), let id = device["DeviceID"] as? Int else { throw serviceError("USB 设备已断开：\(udid)") }
            let tunnel = try MuxSocket()
            let reply = try tunnel.request(["MessageType": "Connect", "DeviceID": id, "PortNumber": remotePort.bigEndian])
            guard reply["Number"] as? Int == 0 else { throw serviceError("USB 控制端口尚未就绪。") }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(tunnel.fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            setsockopt(tunnel.fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            return tunnel
        }
        listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw POSIXError(.EIO) }
        _ = fcntl(listener, F_SETFD, FD_CLOEXEC)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET); address.sin_len = UInt8(MemoryLayout.size(ofValue: address))
        address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = 0
        let descriptor = listener
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard result == 0, listen(listener, 16) == 0 else { Darwin.close(listener); throw POSIXError(.EADDRINUSE) }
        var length = socklen_t(MemoryLayout.size(ofValue: address))
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .userInteractive).async { [self] in
            defer { listenerLock.lock(); listenerOpen = false; Darwin.close(listener); listenerLock.unlock() }
            while !stopping.stopped {
                let local = accept(listener, nil, nil)
                if local < 0 { if errno == EINTR { continue }; break }
                _ = fcntl(local, F_SETFD, FD_CLOEXEC)
                DispatchQueue.global(qos: .userInteractive).async { [self] in
                    defer { Darwin.close(local) }
                    var yes: Int32 = 1
                    setsockopt(local, SOL_SOCKET, SO_NOSIGPIPE, &yes, 4)
                    setsockopt(local, IPPROTO_TCP, TCP_NODELAY, &yes, 4)
                    var timeout = timeval(tv_sec: 2, tv_usec: 0)
                    setsockopt(local, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
                    do { try pump(local, connect()) } catch { /* WDA can refuse a tunnel while starting. */ }
                }
            }
        }
    }
    func stop() {
        listenerLock.lock(); defer { listenerLock.unlock() }
        guard !stopping.stopped else { return }
        stopping.stop()
        if listenerOpen { shutdown(listener, SHUT_RDWR) }
    }
    private func pump(_ local: Int32, _ remote: MuxSocket) throws {
        var watched = [pollfd(fd: local, events: Int16(POLLIN), revents: 0), pollfd(fd: remote.fd, events: Int16(POLLIN), revents: 0)]
        var bytes = [UInt8](repeating: 0, count: 65536)
        while !stopping.stopped {
            let result = Darwin.poll(&watched, 2, 500)
            if result < 0 { if errno == EINTR { continue }; return }
            for index in 0..<2 where watched[index].revents != 0 {
                let count = recv(watched[index].fd, &bytes, bytes.count, 0)
                guard count > 0 else { return }
                let target = watched[1 - index].fd
                var offset = 0
                while offset < count {
                    let sent = bytes.withUnsafeBytes { send(target, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
                    if sent < 0 && errno == EINTR { continue }
                    guard sent > 0 else { return }
                    offset += sent
                }
            }
        }
    }
    static func availablePort() throws -> UInt16 {
        let forwarder = try USBForwarder(udid: "", remotePort: 1)
        defer { forwarder.stop() }
        return forwarder.port
    }
}
