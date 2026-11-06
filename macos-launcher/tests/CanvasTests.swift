// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit

@main
struct CanvasTests {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let canvas = IOSCanvasView(frame: CGRect(x: 0, y: 0, width: 460, height: 700))
        canvas.displayedSize = CGSize(width: 820, height: 1180)
        var taps: [CGPoint] = [], text: [String] = [], gestures: [[IOSTouchSample]] = []
        canvas.tap = { taps.append($0) }; canvas.type = { text.append($0) }; canvas.gesture = { gestures.append($0) }
        let rect = canvas.imageRect
        func event(_ type: NSEvent.EventType, _ point: CGPoint, _ time: TimeInterval = 10) -> NSEvent {
            let position = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(position, to: nil),
                modifierFlags: [], timestamp: time, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        let center = CGPoint(x: 0.5, y: 0.5), side = CGPoint(x: -0.05, y: 0.5), bottom = CGPoint(x: 0.5, y: 1.02)
        canvas.mouseDown(with: event(.leftMouseDown, center))
        precondition(taps.isEmpty)
        canvas.mouseUp(with: event(.leftMouseUp, center))
        precondition(taps == [center])
        let end = CGPoint(x: 0.2, y: 0.2)
        canvas.mouseDown(with: event(.leftMouseDown, center))
        canvas.mouseDragged(with: event(.leftMouseDragged, end, 10.3))
        canvas.mouseUp(with: event(.leftMouseUp, end, 11.1))
        precondition(gestures.count == 1 && gestures[0].count == 3)
        precondition(gestures[0][0].point == center && hypot(gestures[0][1].point.x - end.x, gestures[0][1].point.y - end.y) < 0.00001)
        precondition(abs(gestures[0].last!.time - 1.1) < 0.001, "Release must preserve the pause after movement")
        precondition(gestures[0][1].point == gestures[0][2].point)
        // A path returning to its origin remains a gesture, never a click.
        canvas.mouseDown(with: event(.leftMouseDown, center))
        canvas.mouseDragged(with: event(.leftMouseDragged, end, 10.2))
        canvas.mouseUp(with: event(.leftMouseUp, center, 10.4))
        precondition(gestures.count == 2 && taps == [center])
        canvas.mouseDown(with: event(.leftMouseDown, center))
        canvas.mouseUp(with: event(.leftMouseUp, center, 10.8))
        precondition(gestures.count == 3 && abs(gestures.last!.last!.time - 0.8) < 0.001, "Long press must retain duration")
        for start in [side, bottom] {
            canvas.mouseDown(with: event(.leftMouseDown, start))
            canvas.mouseDragged(with: event(.leftMouseDragged, end, 10.2))
            canvas.mouseUp(with: event(.leftMouseUp, center, 10.5))
        }
        canvas.mouseDown(with: event(.leftMouseDown, side))
        canvas.mouseUp(with: event(.leftMouseUp, side))
        canvas.mouseDown(with: event(.leftMouseDown, center))
        canvas.cancelTouch()
        canvas.mouseUp(with: event(.leftMouseUp, center))
        canvas.mouseDown(with: event(.leftMouseDown, center))
        canvas.displayedSize = CGSize(width: 1180, height: 820)
        canvas.mouseUp(with: event(.leftMouseUp, end, 10.5))
        precondition(gestures.count == 3 && taps == [center], "Margin input, cancellation and rotation must not submit touches")
        canvas.displayedSize = CGSize(width: 820, height: 1180)
        canvas.mouseDown(with: event(.leftMouseDown, center))
        for index in 1...1200 {
            canvas.mouseDragged(with: event(.leftMouseDragged, index % 2 == 0 ? end : center, 10 + Double(index) / 120))
        }
        canvas.mouseUp(with: event(.leftMouseUp, CGPoint(x: 1.2, y: 1.1), 20.1))
        precondition(gestures.last!.count <= 512 && gestures.last!.first!.time == 0)
        precondition(gestures.last!.last!.point == CGPoint(x: 1, y: 1))
        precondition(abs(gestures.last!.last!.time - 10.1) < 0.001)
        precondition(zip(gestures.last!, gestures.last!.dropFirst()).allSatisfy { $0.time < $1.time })
        canvas.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 10, windowNumber: 0, context: nil, characters: "中文", charactersIgnoringModifiers: "中文", isARepeat: false, keyCode: 0)!)
        precondition(text == ["中文"])
        precondition(app.activationPolicy() == .prohibited && app.windows.isEmpty)
        print("PASS: iOS 点击/滑动轨迹与停顿/长按/取消与旋转/留白隔离/键盘文字/无前台窗口")
    }
}
