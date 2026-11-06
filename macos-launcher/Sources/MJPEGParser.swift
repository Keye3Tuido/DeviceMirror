// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation

struct MJPEGParser {
    private var buffer = Data()
    private var expected: Int?
    // CFNetwork unwraps multipart responses and reports each JPEG separately.
    // Other transports can still feed the complete multipart envelope to append.
    mutating func beginPart(length: Int64) -> Bool {
        buffer.removeAll(keepingCapacity: true)
        guard length > 0, length <= 16 * 1024 * 1024 else { expected = nil; return false }
        expected = Int(length)
        return true
    }
    mutating func append(_ data: Data) -> [Data] {
        buffer.append(data)
        if buffer.count > 16 * 1024 * 1024 { buffer.removeAll(); expected = nil; return [] }
        var frames: [Data] = []
        while true {
            if expected == nil {
                guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { break }
                let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                buffer = Data(buffer[end.upperBound...])
                guard let line = header.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
                      let length = Int(line.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespaces)),
                      length > 0, length <= 16 * 1024 * 1024 else { continue }
                expected = length
            }
            guard let length = expected, buffer.count >= length else { break }
            frames.append(Data(buffer.prefix(length)))
            buffer = Data(buffer.dropFirst(length))
            expected = nil
        }
        return frames
    }
}
