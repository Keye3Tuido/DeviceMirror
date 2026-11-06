// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Keye3Tuido
import AppKit
import AVFoundation
import CoreMediaIO
import SwiftUI

enum IOSUSBDevices {
    private static let discovery: AVCaptureDevice.DiscoverySession = {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var enabled: UInt32 = 1
        CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil,
                                  UInt32(MemoryLayout.size(ofValue: enabled)), &enabled)
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14, *) { types = [.external] }
        else { types = [.externalUnknown] }
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: nil, position: .unspecified)
    }()

    static var devices: [AVCaptureDevice] {
        discovery.devices.filter { $0.modelID == "iOS Device" && $0.hasMediaType(.muxed) }
    }
}

// Capture work stays off the main thread. Each window owns its session and input.
final class IOSUSBCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onFrame: ((CGSize) -> Void)?
    var onError: ((String) -> Void)?
    private let queue = DispatchQueue(label: "DeviceMirror.usb.capture.\(UUID().uuidString)")
    private var firstFrame = true
    private var frameSize = CGSize.zero
    private var stopping = false
    private var observers: [NSObjectProtocol] = []

    func start(deviceID: String) {
        queue.async { [self] in
            guard !stopping else { return }
            do {
                guard let device = IOSUSBDevices.devices.first(where: { $0.uniqueID == deviceID }) else {
                    throw NSError(domain: "DeviceMirror", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "未找到 USB 镜像设备。请解锁 iPhone/iPad，检查数据线并在设备上允许信任此电脑。"])
                }
                let input = try AVCaptureDeviceInput(device: device)
                // This capture session contains only the device video input.
                for port in input.ports where port.mediaType == .audio { port.isEnabled = false }
                let output = AVCaptureVideoDataOutput()
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: queue)
                session.beginConfiguration()
                guard session.canAddInput(input), session.canAddOutput(output) else {
                    session.commitConfiguration()
                    throw NSError(domain: "DeviceMirror", code: 2,
                                  userInfo: [NSLocalizedDescriptionKey: "此设备暂时无法启动 USB 屏幕采集。"])
                }
                session.addInput(input)
                session.addOutput(output)
                session.commitConfiguration()
                observers.append(NotificationCenter.default.addObserver(
                    forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] note in
                        let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
                        self?.onError?(error?.localizedDescription ?? "USB 镜像中断，请重新连接。")
                    })
                observers.append(NotificationCenter.default.addObserver(
                    forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil) { [weak self] _ in
                        self?.onError?("设备已断开。重新连接 USB 后可重试。")
                    })
                session.startRunning()
                queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                    guard let self, !self.stopping, self.firstFrame else { return }
                    self.onError?("尚未收到画面。请解锁设备并确认信任提示，再重新连接。")
                }
            } catch { onError?(error.localizedDescription) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !stopping, let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard firstFrame || size != frameSize else { return }
        firstFrame = false
        frameSize = size
        onFrame?(size)
    }

    func stop(completion: (() -> Void)? = nil) {
        queue.async { [self] in
            stopping = true
            session.stopRunning()
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            completion?()
        }
    }
}

@MainActor
final class IOSUSBMirrorSession: NSObject, ObservableObject, NSWindowDelegate {
    let device: IOSDevice
    @Published var capture: IOSUSBCapture?
    @Published var status = "正在连接 USB 镜像…"
    @Published var ready = false
    @Published var preparing = true
    @Published var permissionDenied = false
    @Published var frameSize = CGSize(width: 1, height: 1)
    var onClose: (() -> Void)?
    private var window: NSWindow?
    private var closed = false

    init(device: IOSDevice) { self.device = device }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "\(device.name) · USB 镜像"
            let content = NSHostingView(rootView: IOSUSBMirrorView(model: self))
            content.sizingOptions = []
            window.contentView = content
            window.setContentSize(NSSize(width: 700, height: 650))
            window.minSize = NSSize(width: 560, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func start() {
        guard !closed else { return }
        preparing = true
        permissionDenied = false
        status = "正在连接 USB 镜像…"
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: beginCapture()
        case .notDetermined:
            status = "请允许屏幕采集权限，以显示 USB 设备画面。"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                Task { @MainActor in
                    guard let self, !self.closed else { return }
                    if allowed { self.beginCapture() } else { self.denyPermission() }
                }
            }
        default: denyPermission()
        }
    }

    private func denyPermission() {
        preparing = false
        permissionDenied = true
        status = "请在系统设置 → 隐私与安全性 → 相机中允许 Device Mirror 采集 USB 设备画面。"
    }

    private func beginCapture() {
        let capture = IOSUSBCapture()
        capture.onFrame = { [weak self, weak capture] size in
            Task { @MainActor in
                guard let self, !self.closed, self.capture === capture else { return }
                self.preparing = false
                self.ready = true
                self.frameSize = size
                self.status = "已连接 · USB 镜像"
            }
        }
        capture.onError = { [weak self, weak capture] message in
            Task { @MainActor in
                guard let self, !self.closed, self.capture === capture else { return }
                self.preparing = false
                self.ready = false
                self.status = message
                capture?.stop()
            }
        }
        self.capture = capture
        capture.start(deviceID: device.udid)
    }

    func retry() {
        guard !closed, !preparing else { return }
        let previous = capture
        ready = false
        preparing = true
        if let previous {
            previous.stop { [weak self] in
                Task { @MainActor in
                    guard let self, !self.closed else { return }
                    self.capture = nil
                    self.start()
                }
            }
        } else { start() }
    }

    func openPermissions() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
    }

    func windowWillClose(_ notification: Notification) { stop() }
    func close() { window?.close(); stop() }
    private func stop() {
        guard !closed else { return }
        closed = true
        capture?.stop()
        capture = nil
        onClose?()
        window?.delegate = nil
        window?.contentView = nil
        window = nil
    }
}

struct USBMirrorPreview: NSViewRepresentable {
    let session: AVCaptureSession
    let size: CGSize
    func makeNSView(context: Context) -> IOSCanvasView {
        let view = USBMirrorInputView()
        view.preview.session = session
        return view
    }
    func updateNSView(_ view: IOSCanvasView, context: Context) {
        (view as? USBMirrorInputView)?.preview.session = session
        view.displayedSize = size
        view.needsLayout = true
    }
}

private final class USBMirrorInputView: IOSCanvasView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = imageRect
        CATransaction.commit()
    }
    override func draw(_ dirtyRect: NSRect) { }
}

private struct IOSUSBMirrorView: View {
    @ObservedObject var model: IOSUSBMirrorSession
    var body: some View {
        VStack(spacing: 0) {
            Text("USB 观看镜像 · 电脑操控请从设备列表连接 USB 操控").font(.caption).padding(10)
            ZStack {
                Color.black
                if let capture = model.capture {
                    GeometryReader { geometry in
                        USBMirrorPreview(session: capture.session, size: model.frameSize)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
                if !model.ready {
                    VStack(spacing: 14) {
                        if model.preparing { ProgressView().controlSize(.large) }
                        else { Image(systemName: "cable.connector.slash").font(.largeTitle) }
                        Text(model.preparing ? "正在接收 USB 画面…" : "镜像已停止")
                        if !model.preparing { Button("重新连接") { model.retry() } }
                        if model.permissionDenied { Button("打开权限设置") { model.openPermissions() } }
                    }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(alignment: .top) {
                Text(model.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer()
                Text("USB 观看镜像").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
        }
    }
}
