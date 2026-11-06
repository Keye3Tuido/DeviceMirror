// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit
@main struct KeyButtonTests {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let button = TrackedKeyButton(frame: NSRect(x: 0, y: 0, width: 80, height: 50))
        var phases: [String] = []
        button.changed = { phases.append($0) }
        func event(_ type: NSEvent.EventType) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: CGPoint(x: 30, y: 30), modifierFlags: [], timestamp: 10,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        button.mouseDown(with: event(.leftMouseDown))
        precondition(phases == ["down"], "Held keys must dispatch before mouse-up")
        button.mouseUp(with: event(.leftMouseUp))
        precondition(phases == ["down", "up"])
        button.mouseDown(with: event(.leftMouseDown)); button.cancelPress()
        button.mouseUp(with: event(.leftMouseUp))
        precondition(phases.suffix(2) == ["down", "cancel"])
        button.performClick(nil)
        precondition(phases.suffix(2) == ["down", "up"], "Accessibility activation must dispatch once")
        let count = phases.count
        button.isEnabled = false; button.mouseDown(with: event(.leftMouseDown))
        precondition(phases.count == count && !app.isActive && app.windows.isEmpty)
        print("PASS: live virtual key down/up; cancellation; accessibility; disabled gate; no foreground window")
    }
}
