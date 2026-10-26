import AVFoundation
import SwiftUI
import UIKit

/// Camera-based QR scan for desktop pairing payloads (`uxmusic://…` or `http://…`).
struct PairingQRScannerView: UIViewControllerRepresentable {
    var onDecoded: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerUIViewController {
        let vc = QRScannerUIViewController()
        vc.onDecoded = onDecoded
        return vc
    }

    func updateUIViewController(_ uiViewController: QRScannerUIViewController, context: Context) {}

    static var isCameraAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil
    }
}

final class QRScannerUIViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onDecoded: ((String) -> Void)?

    private let session = AVCaptureSession()
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: session)
    private var hasEmitted = false
    /// Serial queue owning all session configuration and start/stop calls.
    private let sessionQueue = DispatchQueue(label: "jp.ux-labs.UXMusicMobile.qr-scanner-session")
    /// Only touched on `sessionQueue`.
    private var isConfigured = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Attach the preview layer synchronously so it is visible as soon as the session runs,
        // without waiting behind the sheet-presentation main-thread stall.
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = view.bounds
        view.layer.insertSublayer(previewLayer, at: 0)
        configureSessionIfAllowed()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSession()
    }

    private func configureSessionIfAllowed() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            setUpCaptureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard granted else { return }
                    self?.setUpCaptureSession()
                }
            }
        default:
            break
        }
    }

    /// Configures the session on `sessionQueue` (Apple's recommended pattern) so device lookup and
    /// `commitConfiguration` never block the main thread.
    private func setUpCaptureSession() {
        sessionQueue.async { [weak self] in
            guard let self, !self.isConfigured else { return }
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device)
            else { return }

            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            if self.session.canAddInput(input) { self.session.addInput(input) }

            let output = AVCaptureMetadataOutput()
            guard self.session.canAddOutput(output) else {
                self.session.commitConfiguration()
                return
            }
            self.session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            output.metadataObjectTypes = [.qr]
            self.session.commitConfiguration()
            self.isConfigured = true

            self.session.startRunning()
        }
    }

    private func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !hasEmitted else { return }
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let value = obj.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return }
        hasEmitted = true
        stopSession()
        onDecoded?(value)
    }
}
