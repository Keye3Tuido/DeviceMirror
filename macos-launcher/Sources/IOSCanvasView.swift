// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit

class IOSCanvasView: NSView {
    var image: NSImage?
    var displayedSize: CGSize?
    var inputEnabled = true { didSet { if !inputEnabled { cancelTouch() } } }
    var touch: ((String, CGPoint) -> Void)?
    var type: ((String) -> Void)?
    private var lastPoint: CGPoint?
    private var touchRect = CGRect.zero
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
        focusObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in self?.cancelTouch() }
    }
    deinit { if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) } }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        image?.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
    override func mouseDown(with event: NSEvent) {
        cancelTouch()
        let point = convert(event.locationInWindow, from: nil)
        guard inputEnabled, imageRect.contains(point) else { return }
        touchRect = imageRect
        let normalized = MirrorGeometry.normalized(point, in: touchRect)
        lastPoint = normalized
        touch?("down", normalized)
        window?.makeFirstResponder(self)
    }
    private func send(_ phase: String, event: NSEvent) {
        guard lastPoint != nil else { return }
        guard inputEnabled, touchRect == imageRect else { cancelTouch(); return }
        let point = MirrorGeometry.normalized(convert(event.locationInWindow, from: nil), in: touchRect)
        lastPoint = phase == "up" ? nil : point
        touch?(phase, point)
    }
    override func mouseDragged(with event: NSEvent) { send("move", event: event) }
    override func mouseUp(with event: NSEvent) { send("up", event: event) }
    override func scrollWheel(with event: NSEvent) { }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { cancelTouch(); return }
        if inputEnabled, let text = event.characters, !event.modifierFlags.contains(.command) { type?(text) }
    }
    @objc func paste(_ sender: Any?) {
        if inputEnabled, let text = NSPasteboard.general.string(forType: .string) { type?(text) }
    }
    func cancelTouch() {
        guard let point = lastPoint else { return }
        lastPoint = nil
        touch?("cancel", point)
    }
}
