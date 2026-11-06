// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit

@main struct CanvasTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let canvas = IOSCanvasView(frame: CGRect(x: 0, y: 0, width: 460, height: 700))
        canvas.displayedSize = CGSize(width: 820, height: 1180)
        var events: [(String, CGPoint)] = [], text: [String] = []
        canvas.touch = { events.append(($0, $1)) }; canvas.type = { text.append($0) }
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            let rect = canvas.imageRect
            let p = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(p, to: nil), modifierFlags: [],
                timestamp: 10, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let center = CGPoint(x: 0.5, y: 0.5), end = CGPoint(x: 0.2, y: 0.3)
        canvas.mouseDown(with: event(.leftMouseDown, center))
        precondition(events.map(\.0) == ["down"], "Down must reach the transport before release")
        canvas.mouseDragged(with: event(.leftMouseDragged, end))
        precondition(events.map(\.0) == ["down", "move"], "Movement must stream while held")
        canvas.mouseUp(with: event(.leftMouseUp, end))
        precondition(events.map(\.0) == ["down", "move", "up"])
        precondition(hypot(events[1].1.x - 0.2, events[1].1.y - 0.3) < 0.00001)
        canvas.mouseDown(with: event(.leftMouseDown, center))
        canvas.cancelTouch(); canvas.mouseUp(with: event(.leftMouseUp, center))
        precondition(events.map(\.0).suffix(2) == ["down", "cancel"], "Cancel must release once without replay")
        canvas.mouseDown(with: event(.leftMouseDown, center))
        canvas.displayedSize = CGSize(width: 1180, height: 820)
        canvas.mouseDragged(with: event(.leftMouseDragged, end))
        precondition(events.last?.0 == "cancel", "Rotation must release the old coordinate space")
        let count = events.count
        canvas.mouseDown(with: event(.leftMouseDown, CGPoint(x: -0.05, y: 0.5)))
        canvas.mouseUp(with: event(.leftMouseUp, center))
        precondition(events.count == count, "A gesture cannot start outside the screen")
        canvas.inputEnabled = false
        canvas.mouseDown(with: event(.leftMouseDown, center))
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 10,
            windowNumber: 0, context: nil, characters: "中", charactersIgnoringModifiers: "中", isARepeat: false, keyCode: 0)!)
        precondition(events.count == count && text.isEmpty, "Unsupported devices must receive no input")
        precondition(!app.isActive && app.windows.isEmpty)
        print("PASS: live touch phases; coordinate mapping; cancel/rotation; unsupported input gate; no foreground window")
    }
}
