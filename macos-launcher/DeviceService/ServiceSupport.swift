// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation
import Darwin
import CryptoKit

func serviceError(_ message: String) -> NSError {
    NSError(domain: "DeviceMirror.Service", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
func serviceJSON(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
func servicePrint(_ message: String) { print(message); fflush(stdout) }

struct ServiceChild {
    let pid: pid_t
    init(_ executable: String, _ arguments: [String]) throws {
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attr, 0)
        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for value in argv + envp { free(value) } }
        var child: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&child, executable, nil, &attr, args.baseAddress!, env.baseAddress!)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
        pid = child
    }
    func poll() -> Int32? {
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == 0 { return nil }
        return result < 0 ? -1 : (status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }
    func terminate() {
        kill(-pid, SIGTERM)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if poll() != nil { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        waitpid(pid, &status, 0)
    }
}

final class ServiceStop {
    private let lock = NSLock()
    private var value = false
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func stop() { lock.lock(); value = true; lock.unlock() }
}

enum ServiceSigning {
    static func validID(_ value: String) -> Bool { value.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil }
    static func teams(_ preferences: [String: Any]) -> [[String: String]] {
        var result: [String: String] = [:]
        func add(_ id: String, _ value: Any) {
            guard validID(id) else { return }
            let dict = value as? [String: Any] ?? [:]
            result[id] = dict["name"] as? String ?? dict["teamName"] as? String ?? dict["teamDisplayName"] as? String ?? (value as? String) ?? id
        }
        func visit(_ value: Any) {
            if let dict = value as? [String: Any] {
                if let id = (dict["teamID"] ?? dict["teamIdentifier"]) as? String { add(id, dict) }
                for (key, child) in dict {
                    if ["teams", "provisioningteams"].contains(key.lowercased()), let catalog = child as? [String: Any] {
                        for (id, team) in catalog { add(id, team) }
                    }
                    visit(child)
                }
            } else if let rows = value as? [Any] { rows.forEach(visit) }
        }
        let catalog = preferences["IDEProvisioningTeamByIdentifier"] as? [String: Any] ?? [:]
        for (id, value) in catalog { add(id, value) }
        visit(catalog); visit(preferences["DVTDeveloperAccountManagerAppleIDLists"] ?? [:])
        return result.map { ["id": $0.key, "name": $0.value] }.sorted { ($0["name"]!, $0["id"]!) < ($1["name"]!, $1["id"]!) }
    }
    static func info() -> [String: Any] {
        var preferences: [String: Any] = [:]
        if let output = try? CommandRunner.run(URL(fileURLWithPath: "/usr/bin/defaults"), ["export", "com.apple.dt.Xcode", "-"], timeout: 5), output.status == 0 {
            preferences = (try? PropertyListSerialization.propertyList(from: Data(output.output.utf8), format: nil)) as? [String: Any] ?? [:]
        }
        var found = teams(preferences)
        let source = found.isEmpty ? "certificates" : "xcode"
        if found.isEmpty { found = certificateTeams() }
        let accounts = preferences["DVTDeveloperAccountManagerAppleIDLists"] as? [String: Any] ?? [:]
        return ["teams": found, "hasAccounts": accounts.values.contains { ($0 as? [Any])?.isEmpty == false }, "source": source]
    }
    private static func certificateTeams() -> [[String: String]] {
        guard let identities = try? CommandRunner.run(URL(fileURLWithPath: "/usr/bin/security"), ["find-identity", "-v", "-p", "codesigning"], timeout: 5),
              let certificates = try? CommandRunner.run(URL(fileURLWithPath: "/usr/bin/security"), ["find-certificate", "-a", "-p"], timeout: 5) else { return [] }
        // Match certificates to valid development identities before exposing their OU as a team.
        let lines = identities.output.split(separator: "\n").filter { $0.contains("Apple Development:") || $0.contains("iPhone Developer:") }
        let words = lines.flatMap { $0.split(separator: " ") }
        let hashes = words.filter { $0.count == 40 }.map { String($0) }
        var result = Set<String>()
        for block in certificates.output.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst() {
            guard let body = block.components(separatedBy: "-----END CERTIFICATE-----").first,
                  let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters),
                  hashes.contains(where: { Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined() == $0.uppercased() }),
                  let subject = try? CommandRunner.run(URL(fileURLWithPath: "/usr/bin/openssl"), ["x509", "-inform", "DER", "-noout", "-subject", "-nameopt", "RFC2253"], timeout: 3, input: der) else { continue }
            let regex = try! NSRegularExpression(pattern: "(?:^|,)OU=([A-Z0-9]{10})(?:,|$)")
            let text = subject.output as NSString
            if let match = regex.firstMatch(in: subject.output, range: NSRange(location: 0, length: text.length)) { result.insert(text.substring(with: match.range(at: 1))) }
        }
        return result.sorted().map { ["id": $0, "name": $0 + "（本机开发证书）"] }
    }
    static func choose(_ explicit: String, teams: [[String: String]]) throws -> String {
        if !explicit.isEmpty {
            guard validID(explicit) else { throw serviceError("开发团队 ID 格式无效，请重新选择团队。") }
            return explicit
        }
        guard teams.count == 1, let id = teams[0]["id"] else {
            throw serviceError(teams.isEmpty ? "请在 Xcode → Settings → Apple Accounts 登录 Apple 账号，再检测开发团队。" : "检测到多个开发团队，请选择用于设备签名的团队。")
        }
        return id
    }
    static func usableProfile(_ value: [String: Any], team: String, now: Date = Date()) -> Bool {
        (value["TeamIdentifier"] as? [String])?.contains(team) == true && (value["ExpirationDate"] as? Date ?? .distantPast) > now.addingTimeInterval(300)
    }
    static func usableProfiles(in products: URL, team: String) -> Bool {
        let fm = FileManager.default
        for directory in (try? fm.contentsOfDirectory(at: products, includingPropertiesForKeys: nil)) ?? [] where directory.lastPathComponent.contains("iphoneos") {
            for app in (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] where app.pathExtension == "app" {
                let profile = app.appendingPathComponent("embedded.mobileprovision")
                guard let output = try? CommandRunner.run(URL(fileURLWithPath: "/usr/bin/security"), ["cms", "-D", "-i", profile.path], timeout: 5), output.status == 0,
                      let value = (try? PropertyListSerialization.propertyList(from: Data(output.output.utf8), format: nil)) as? [String: Any] else { continue }
                if usableProfile(value, team: team) { return true }
            }
        }
        return false
    }
}
