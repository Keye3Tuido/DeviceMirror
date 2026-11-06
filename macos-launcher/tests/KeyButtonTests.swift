// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit

@main
struct KeyButtonTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let button = TrackedKeyButton(frame: NSRect(x: 10, y: 10, width: 80, height: 50))
        window.contentView!.addSubview(button)
        var durations: [TimeInterval] = []
        button.pressed = { durations.append($0) }
        button.performClick(nil)
        precondition(durations == [0], "Keyboard/accessibility activation must send one short press")
        func event(_ type: NSEvent.EventType, _ timestamp: Double, _ inside: Bool = true) -> NSEvent {
            let point = inside ? NSPoint(x: 30, y: 30) : NSPoint(x: 115, y: 75)
            return NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: timestamp, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        for duration in [0.1, 0.8, 1.2] {
            button.submit(release: event(.leftMouseUp, 10 + duration), started: 10)
            precondition(durations.count == (duration == 0.1 ? 2 : duration == 0.8 ? 3 : 4), "A held key must submit once")
            precondition(abs(durations.last! - (duration < 0.5 ? 0 : duration)) < 0.001)
        }
        let count = durations.count
        button.submit(release: event(.leftMouseUp, 11, false), started: 10)
        precondition(durations.count == count, "Releasing outside the button must cancel its action")
        button.isEnabled = false
        button.mouseDown(with: event(.leftMouseDown, 10))
        precondition(durations.count == count)
        precondition(!window.isVisible && !app.isActive && app.activationPolicy() == .prohibited)
        print("PASS: virtual key short/long press duration; one submission; cancellation; no foreground window")
    }
}
