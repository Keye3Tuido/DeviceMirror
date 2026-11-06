// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit

struct IOSTouchSample {
    let point: CGPoint
    let time: TimeInterval
    var payload: [String: Double] { ["x": point.x, "y": point.y, "time": time] }
}

class IOSCanvasView: NSView {
    var image: NSImage?
    var displayedSize: CGSize?
    var tap: ((CGPoint) -> Void)?
    var type: ((String) -> Void)?
    var gesture: (([IOSTouchSample]) -> Void)?
    private var samples: [IOSTouchSample] = []
    private var touchRect = CGRect.zero
    private var startedAt: TimeInterval = 0
    private var dragged = false
    private var focusObserver: NSObjectProtocol?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var imageRect: CGRect {
        guard let size = displayedSize ?? image?.size else { return .zero }
        return MirrorGeometry.imageRect(in: bounds, size: size)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
        cancelTouch()
        guard let window else { focusObserver = nil; return }
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in self?.cancelTouch() }
    }
    deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func mouseDown(with event: NSEvent) {
        cancelTouch()
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point) else { return }
        touchRect = imageRect
        startedAt = event.timestamp
        samples = [IOSTouchSample(point: MirrorGeometry.normalized(point, in: touchRect), time: 0)]
        window?.makeFirstResponder(self)
    }
    private func append(_ event: NSEvent) {
        guard !samples.isEmpty else { return }
        // Resizing or rotating during a drag invalidates its coordinate space.
        guard touchRect == imageRect else { cancelTouch(); return }
        let point = MirrorGeometry.normalized(convert(event.locationInWindow, from: nil), in: touchRect)
        let first = samples[0].point
        if hypot((point.x - first.x) * touchRect.width, (point.y - first.y) * touchRect.height) > 5 { dragged = true }
        let time = max(samples.last!.time + 0.001, event.timestamp - startedAt)
        // Keep the trajectory bounded without changing its timing or endpoints.
        if samples.count >= 512 {
            samples = samples.enumerated().filter { $0.offset % 2 == 0 || $0.offset == 511 }.map { $0.element }
        }
        samples.append(IOSTouchSample(point: point, time: time))
    }
    override func mouseDragged(with event: NSEvent) { append(event) }
    override func mouseUp(with event: NSEvent) {
        append(event)
        defer { cancelTouch() }
        guard let last = samples.last else { return }
        if dragged || last.time >= 0.5 {
            // Replay the recorded touch, including pauses, after mouse release.
            // No direction or edge is interpreted as a navigation command.
            gesture?(samples)
        } else if touchRect.contains(convert(event.locationInWindow, from: nil)) {
            tap?(last.point)
        }
    }
    override func scrollWheel(with event: NSEvent) { }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelTouch(); return }
        if let text = event.characters, !event.modifierFlags.contains(.command) { type?(text) }
    }
    @objc func paste(_ sender: Any?) {
        if let text = NSPasteboard.general.string(forType: .string) { type?(text) }
    }
    func cancelTouch() { samples = []; dragged = false }
}
