// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit
import SwiftUI

final class TrackedKeyButton: NSButton {
    var changed: ((String) -> Void)?
    private var held = false
    private var observer: NSObjectProtocol?
    override var isEnabled: Bool { didSet { if !isEnabled { cancelPress() } } }
    override init(frame: NSRect) {
        super.init(frame: frame)
        target = self; action = #selector(activateKey)
        isBordered = false; imagePosition = .imageAbove
        setButtonType(.momentaryPushIn); font = .systemFont(ofSize: 10)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow(); cancelPress()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        guard let window else { observer = nil; return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: window, queue: .main) { [weak self] _ in self?.cancelPress() }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !held else { return }
        held = true; highlight(true); changed?("down")
    }
    override func mouseUp(with event: NSEvent) {
        guard held else { return }
        held = false; highlight(false); changed?("up")
    }
    func cancelPress() {
        guard held else { return }
        held = false; highlight(false); changed?("cancel")
    }
    @objc private func activateKey() {
        guard isEnabled, !held else { return }
        changed?("down"); changed?("up")
    }
}

struct DeviceKeyButton: NSViewRepresentable {
    let title: String
    let symbol: String
    let enabled: Bool
    let action: (String) -> Void
    func makeNSView(context: Context) -> TrackedKeyButton { TrackedKeyButton(frame: .zero) }
    func updateNSView(_ button: TrackedKeyButton, context: Context) {
        button.title = title
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.toolTip = "\(title)；按下立即发送，松开结束"
        button.setAccessibilityLabel(title)
        button.isEnabled = enabled; button.changed = action
    }
    static func dismantleNSView(_ view: TrackedKeyButton, coordinator: ()) { view.cancelPress() }
}
