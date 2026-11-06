// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation
import Darwin

@main
struct ServiceTests {
    static func main() throws {
        let old: [String: Any] = ["IDEProvisioningTeamByIdentifier": ["ABCDEFGHIJ": ["teamName": "Personal"]]]
        precondition(ServiceSigning.teams(old) == [["id": "ABCDEFGHIJ", "name": "Personal"]])
        let modern: [String: Any] = ["IDEProvisioningTeamByIdentifier": ["account-uuid": [["teamID": "123456ABCD", "name": "Company"]]],
                                    "DVTDeveloperAccountManagerAppleIDLists": ["uuid": [["identifier": "XXXXXXXXXX", "teams": ["ABCDEFGHIJ": "Personal"]]]]]
        let teams = ServiceSigning.teams(modern)
        precondition(teams.count == 2 && !teams.contains { $0["id"] == "XXXXXXXXXX" })
        let chosen = try ServiceSigning.choose("", teams: ServiceSigning.teams(old))
        precondition(chosen == "ABCDEFGHIJ")
        for (explicit, candidates) in [("", teams), ("", []), ("not a team", [])] {
            do { _ = try ServiceSigning.choose(explicit, teams: candidates); preconditionFailure("Ambiguous/invalid signing must fail") }
            catch { }
        }
        let now = Date()
        precondition(ServiceSigning.usableProfile(["TeamIdentifier": ["ABCDEFGHIJ"], "ExpirationDate": now.addingTimeInterval(3600)], team: "ABCDEFGHIJ", now: now))
        precondition(!ServiceSigning.usableProfile(["TeamIdentifier": ["ABCDEFGHIJ"], "ExpirationDate": now.addingTimeInterval(299)], team: "ABCDEFGHIJ", now: now))
        precondition(!ServiceSigning.usableProfile(["TeamIdentifier": ["other"], "ExpirationDate": now.addingTimeInterval(3600)], team: "ABCDEFGHIJ", now: now))
        let first = try ServiceChild("/bin/sh", ["-c", "sleep 30 & wait"])
        let second = try ServiceChild("/bin/sh", ["-c", "sleep 30 & wait"])
        first.terminate()
        precondition(second.poll() == nil, "Closing one child group must preserve other instances")
        second.terminate()
        func echo(_ prefix: String) -> () throws -> MuxSocket {
            return {
                var pair: [Int32] = [0, 0]
                guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else { throw POSIXError(.EIO) }
                let peer = pair[1]
                DispatchQueue.global().async {
                    defer { Darwin.close(peer) }
                    let text = Data(prefix.utf8)
                    _ = text.withUnsafeBytes { send(peer, $0.baseAddress, $0.count, 0) }
                }
                return MuxSocket(adopting: pair[0])
            }
        }
        let a = try USBForwarder(udid: "a", remotePort: 8100, connector: echo("device-a"))
        let b = try USBForwarder(udid: "b", remotePort: 8100, connector: echo("device-b"))
        defer { a.stop(); b.stop() }
        func receive(_ port: UInt16) throws -> String {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            defer { Darwin.close(fd) }
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = port.bigEndian
            let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard connected == 0 else { throw POSIXError(.ECONNREFUSED) }
            var bytes = [UInt8](repeating: 0, count: 100)
            let count = recv(fd, &bytes, bytes.count, 0)
            guard count > 0 else { throw POSIXError(.EIO) }
            return String(decoding: bytes.prefix(count), as: UTF8.self)
        }
        func tryReceive(_ port: UInt16) -> String { (try? receive(port)) ?? "ERROR" }
        precondition(a.port != b.port)
        let responseA = try receive(a.port)
        precondition(responseA == "device-a")
        precondition(tryReceive(b.port) == "device-b")
        a.stop()
        precondition(tryReceive(b.port) == "device-b")
        print("PASS: 团队解析/账号排除/签名消歧/描述文件有效期/子进程组隔离/原生USB转发隔离")
    }
}
