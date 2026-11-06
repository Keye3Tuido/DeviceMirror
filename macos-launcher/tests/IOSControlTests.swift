// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import Foundation
@main struct IOSControlTests {
    static func main() {
        for (version, allowed) in [("26.9", false), ("27.0", true), ("27.1", true), ("28.0", true), ("", false), ("unknown", false), ("27x", false)] {
            precondition(IOSControlSupport(version: version).supported == allowed, "Wrong version gate: \(version)")
        }
        let queue = IOSInputBuffer()
        precondition(queue.append(["type": "touch", "phase": "down", "x": 0.1, "y": 0.2]))
        for index in 0..<1000 { precondition(queue.append(["type": "touch", "phase": "move", "x": Double(index) / 1000, "y": 0.2])) }
        precondition(queue.append(["type": "touch", "phase": "up", "x": 0.9, "y": 0.2]))
        let batch = queue.take()
        precondition(batch.count == 3, "Moves must coalesce without losing down/up")
        precondition(batch.map { $0["phase"] as! String } == ["down", "move", "up"])
        precondition(batch[1]["x"] as? Double == 0.999)
        print("PASS: iOS27 version boundary; fail closed on unknown; bounded moves preserve final position and release")
    }
}
