// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit
import SwiftUI

// Native button tracking preserves cancellation and delivers one action on
// release. XCTest replays a held key for the measured duration after release.
final class TrackedKeyButton: NSButton {
    var pressed: ((TimeInterval) -> Void)?
    private var started: TimeInterval?
    private var cancelled = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self
        action = #selector(activateKey)
        isBordered = false
        imagePosition = .imageAbove
        setButtonType(.momentaryPushIn)
        font = .systemFont(ofSize: 10)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        started = event.timestamp
        cancelled = false
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in self?.cancelled = true }
        defer { started = nil; cancelled = false; NotificationCenter.default.removeObserver(observer) }
        super.mouseDown(with: event)
    }
    @objc private func activateKey() {
        submit(release: NSApp.currentEvent, started: started)
    }
    func submit(release: NSEvent?, started: TimeInterval?) {
        guard isEnabled, !cancelled else { return }
        if started != nil {
            guard let event = release, event.type == .leftMouseUp,
                  bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        }
        let elapsed = started.map { max(0, (release?.timestamp ?? $0) - $0) } ?? 0
        pressed?(elapsed >= 0.5 ? min(30, elapsed) : 0)
    }
}

struct DeviceKeyButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: (TimeInterval) -> Void

    func makeNSView(context: Context) -> TrackedKeyButton { TrackedKeyButton(frame: .zero) }
    func updateNSView(_ button: TrackedKeyButton, context: Context) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.toolTip = "\(title)；按住至少半秒，松开后发送长按"
        button.setAccessibilityLabel(title)
        button.isEnabled = enabled
        button.pressed = action
    }
}
