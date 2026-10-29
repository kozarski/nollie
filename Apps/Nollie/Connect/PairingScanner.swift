#if os(iOS)
@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// The camera opens only after the person chooses to scan. Images stay on the device.
struct PairingScanner: View {
    var onCode: @MainActor @Sendable (String) -> Void
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var authorization = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var issue: String?

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 360)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { authorization = AVCaptureDevice.authorizationStatus(for: .video) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let issue {
            ContentUnavailableView("Camera unavailable", systemImage: "camera", description: Text(issue))
        } else {
            switch authorization {
            case .authorized: liveCamera
            case .notDetermined: explanation
            case .denied, .restricted: blocked
            @unknown default: ProgressView("Opening camera…")
            }
        }
    }

    private var liveCamera: some View {
        PairingCameraPreview(active: scenePhase == .active, onCode: onCode, onFailure: { issue = $0 })
            .overlay {
                RoundedRectangle(cornerRadius: 22)
                    .stroke(.white.opacity(0.85), lineWidth: 3)
                    .frame(width: 230, height: 230)
                    .accessibilityHidden(true)
            }
            .clipShape(.rect(cornerRadius: 24))
            .accessibilityLabel("Point the camera at the pairing code on your Mac")
            .accessibilityIdentifier("pairing.camera")
    }

    /// The reason comes first. The system's question follows once the person agrees.
    private var explanation: some View {
        cameraNotice {
            Text("Nollie uses the camera to read the code on your Mac. Nothing is saved.")
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("pairing.camera.reason")
            Button("Allow camera") { Task { await requestCamera() } }
                .buttonStyle(.nollieGlassProminent)
                .accessibilityIdentifier("pairing.camera.allow")
        }
    }

    private var blocked: some View {
        cameraNotice {
            Text("Allow camera access to scan your Mac's code.")
                .multilineTextAlignment(.center)
            if authorization == .denied {
                Button("Open Settings", action: openAppSettings)
                    .buttonStyle(.nollieGlassProminent)
                    .accessibilityIdentifier("pairing.camera.settings")
            }
        }
    }

    private func cameraNotice<Rows: View>(@ViewBuilder rows: () -> Rows) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            rows()
        }
        .padding(24)
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(url)
    }

    /// Runs from the Allow button only: opening the scanner shows no system prompt by itself.
    private func requestCamera() async {
        guard authorization == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .video)
        guard !Task.isCancelled else { return }
        authorization = AVCaptureDevice.authorizationStatus(for: .video)
    }
}

private struct PairingCameraPreview: UIViewControllerRepresentable {
    var active: Bool
    var onCode: @MainActor @Sendable (String) -> Void
    var onFailure: @MainActor @Sendable (String) -> Void

    func makeUIViewController(context: Context) -> PairingCameraController {
        PairingCameraController(onCode: onCode, onFailure: onFailure)
    }

    func updateUIViewController(_ controller: PairingCameraController, context: Context) {
        controller.setActive(active)
    }

    static func dismantleUIViewController(_ controller: PairingCameraController, coordinator: ()) {
        controller.setActive(false)
    }
}

@MainActor
private final class PairingCameraController: UIViewController {
    private let capture: PairingCaptureSession
    private let preview = AVCaptureVideoPreviewLayer()

    init(onCode: @escaping @MainActor @Sendable (String) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        capture = PairingCaptureSession(onCode: onCode, onFailure: onFailure)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        preview.session = capture.session
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        capture.setActive(false)
    }

    func setActive(_ active: Bool) { capture.setActive(active) }
}

/// AVFoundation's blocking session methods and delegate stay on one serial queue.
/// Only the preview-layer association is made on the main actor; callbacks send strings.
private final class PairingCaptureSession: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.coreykozarski.nollie.pairing-camera")
    private let onCode: @MainActor @Sendable (String) -> Void
    private let onFailure: @MainActor @Sendable (String) -> Void
    private var configured = false
    private var delivered = false

    init(onCode: @escaping @MainActor @Sendable (String) -> Void,
         onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        self.onCode = onCode
        self.onFailure = onFailure
    }

    func setActive(_ active: Bool) {
        queue.async { [self] in
            if active && !delivered {
                guard configured || configure() else { return }
                if !session.isRunning { session.startRunning() }
            } else if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            fail(String(localized: "This device's camera could not open. You can still connect manually."))
            return false
        }
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else {
            fail(String(localized: "This camera cannot scan codes. You can still connect manually."))
            return false
        }
        session.addInput(input)
        session.addOutput(output)
        guard output.availableMetadataObjectTypes.contains(.qr) else {
            fail(String(localized: "This camera cannot scan codes. You can still connect manually."))
            return false
        }
        output.setMetadataObjectsDelegate(self, queue: queue)
        output.metadataObjectTypes = [.qr]
        configured = true
        return true
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard !delivered, let value = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        delivered = true
        session.stopRunning()
        Task { @MainActor [onCode] in onCode(value) }
    }

    private func fail(_ message: String) {
        delivered = true
        Task { @MainActor [onFailure] in onFailure(message) }
    }
}
#endif
