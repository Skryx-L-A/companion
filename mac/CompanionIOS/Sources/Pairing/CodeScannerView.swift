// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import AVFoundation
import SwiftUI
import UIKit

/// The camera, reading QR codes and nothing else.
///
/// It runs only while this view is on screen: `DESIGN.md` section Mobil puts the camera in the
/// pairing step, and a camera that kept running afterwards would be a second thing the app
/// does that nobody asked for.
struct CodeScannerView: UIViewControllerRepresentable {
    /// Called once, with what the first readable code said.
    let onCode: (String) -> Void
    /// Called when there is no camera to read with — a simulator, or a device without one.
    /// Without this the view would be a black rectangle and nothing would ever happen.
    let onUnavailable: () -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {
        controller.onCode = onCode
        controller.onUnavailable = onUnavailable
    }
}

// The delegate is given `.main` as its queue below, so every callback really does arrive on
// the main actor; `@preconcurrency` is what says so to a compiler that cannot see the queue.
final class ScannerController: UIViewController, @preconcurrency AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onUnavailable: (() -> Void)?

    private var isUsable = false
    private let camera = Camera()
    private var preview: AVCaptureVideoPreviewLayer?
    private var hasReported = false

    private var session: AVCaptureSession { camera.session }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        guard let device = AVCaptureDevice.default(for: .video),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        isUsable = true
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasReported = false
        guard isUsable else {
            // Said once, and to whoever is above: a view that shows a black rectangle and
            // waits forever tells a person nothing about why.
            onUnavailable?()
            return
        }
        guard !session.isRunning else { return }
        camera.startInBackground()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        camera.stopInBackground()
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput objects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasReported,
            let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first,
            let text = code.stringValue
        else { return }
        hasReported = true
        camera.stopInBackground()
        onCode?(text)
    }
}

/// The capture session, and the two calls that are made off the main thread.
///
/// `startRunning` blocks for a moment, so Apple's own guidance is not to make it on the main
/// thread; the session itself is not `Sendable`. What crosses the queue boundary here is only
/// starting and stopping, which AVFoundation documents as safe from any thread — everything
/// else about the session stays on the main actor with the view controller.
private final class Camera: @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "companion.ios.camera")

    func startInBackground() {
        queue.async { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stopInBackground() {
        queue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }
}
