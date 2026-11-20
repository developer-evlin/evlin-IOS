import SwiftUI
import AVFoundation

// Parent side of pairing: the kid's device shows a QR code and a 6-digit
// code; the parent either scans the QR or types the code. Shared by parent
// onboarding and Settings' "Add a child" / "Pair a device" sheet.

/// Pulls the 6-digit code out of a scanned QR payload ("evlin-pair:123456")
/// or a bare 6-digit string. Anything else isn't ours.
enum PairCodeParser {
    static func code(from scanned: String) -> String? {
        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = trimmed.hasPrefix("evlin-pair:") ? String(trimmed.dropFirst("evlin-pair:".count)) : trimmed
        return body.count == 6 && body.allSatisfy(\.isNumber) ? body : nil
    }
}

/// Live camera preview that reports the first QR code it sees.
struct QRScannerView: UIViewRepresentable {
    var onScan: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return view }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return view }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
        output.metadataObjectTypes = [.qr]
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onScan = onScan
    }

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) {
        let session = coordinator.session
        DispatchQueue.global(qos: .userInitiated).async { session?.stopRunning() }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        // The camera delivers frames in the sensor's landscape orientation;
        // the preview has to be turned to match the screen, or it shows on
        // its side (an iPad held sideways, or before the first rotation).
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let connection = previewLayer.connection else { return }
            let angle: CGFloat
            switch window?.windowScene?.interfaceOrientation ?? .portrait {
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            case .portraitUpsideDown: angle = 270
            default: angle = 90
            }
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        }
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        var onScan: (String) -> Void
        var session: AVCaptureSession?
        init(onScan: @escaping (String) -> Void) { self.onScan = onScan }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            if let s = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue { onScan(s) }
        }
    }
}

/// Scanner + manual code field. `claim` does the actual backend call and
/// throws if the code is refused; this view turns that into a message.
struct PairCodeEntry: View {
    var accent: Color = EColor.primary
    var claim: (String) async throws -> Void

    @State private var code = ""
    @State private var busy = false
    @State private var errorText: String?
    @State private var cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var lastRejected: (code: String, at: Date)?
    @State private var showScanner = false
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var cameraAvailable: Bool {
        AVCaptureDevice.default(for: .video) != nil && cameraStatus != .denied && cameraStatus != .restricted
    }

    var body: some View {
        VStack(spacing: 16) {
            scannerArea
            HStack(spacing: 10) {
                Rectangle().fill(EColor.outlineVariant).frame(height: 1)
                Text("or type the code").font(Typography.font(12, weight: .semibold)).foregroundStyle(EColor.onSurfaceVariant)
                Rectangle().fill(EColor.outlineVariant).frame(height: 1)
            }
            TextField("6-digit code", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .multilineTextAlignment(.center)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .tracking(6)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(EColor.surfaceContainerLowest))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(EColor.outlineVariant, lineWidth: 1))
                .onChange(of: code) { _, new in
                    let digits = String(new.filter(\.isNumber).prefix(6))
                    if digits != new { code = digits }
                    errorText = nil
                }
            if let errorText {
                Text(errorText)
                    .font(Typography.font(13, weight: .semibold))
                    .foregroundStyle(EColor.danger)
                    .multilineTextAlignment(.center)
            }
            Button {
                submit(code)
            } label: {
                HStack {
                    if busy { ProgressView().tint(.white) }
                    Text(busy ? "Connecting…" : "Connect").font(OnboardingV2Theme.Typography.cta(hSizeClass == .regular))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, OnboardingV2Theme.Metrics.ctaPaddingHorizontal)
                .background(accent.opacity(code.count == 6 && !busy ? 1 : 0.4))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(height: hSizeClass == .regular ? OnboardingV2Theme.Metrics.ctaHeightRegular : OnboardingV2Theme.Metrics.ctaHeightCompact)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: OnboardingV2Theme.Metrics.ctaMaxWidth)
            .frame(maxWidth: .infinity)
            .disabled(code.count != 6 || busy)
        }
        .task {
            if cameraStatus == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    /// A button that opens the camera full screen. The camera used to sit
    /// in a short, wide box on the page, which read as a sideways sliver of
    /// a camera rather than a scanner.
    @ViewBuilder private var scannerArea: some View {
        if cameraAvailable {
            Button {
                Task {
                    if cameraStatus == .notDetermined {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
                    }
                    if cameraStatus == .authorized { showScanner = true }
                }
            } label: {
                VStack(spacing: 10) {
                    Image(systemName: "qrcode.viewfinder").font(.system(size: 40, weight: .regular))
                    Text("Scan the QR code").font(OnboardingV2Theme.Typography.cta(hSizeClass == .regular))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 28)
                .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(accent))
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .fullScreenCover(isPresented: $showScanner) {
                QRScannerScreen(onClose: { showScanner = false }) { scanned in
                    guard let scannedCode = PairCodeParser.code(from: scanned), !busy else { return }
                    // The camera reports the same frame many times a second;
                    // after a refusal, wait a moment before trying it again.
                    if let last = lastRejected, last.code == scannedCode, Date().timeIntervalSince(last.at) < 3 { return }
                    showScanner = false
                    code = scannedCode
                    submit(scannedCode)
                }
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "qrcode.viewfinder").font(.system(size: 34)).foregroundStyle(EColor.onSurfaceVariant)
                Text(cameraStatus == .denied || cameraStatus == .restricted
                     ? "Camera access is off. Turn it on in Settings to scan, or type the code."
                     : "Scanning isn't available on this device. Type the code shown on your child's screen.")
                    .font(Typography.font(13, weight: .regular))
                    .foregroundStyle(EColor.onSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(EColor.surfaceContainerLowest))
        }
    }

    private func submit(_ value: String) {
        guard value.count == 6, !busy else { return }
        busy = true
        errorText = nil
        Task {
            do {
                try await claim(value)
            } catch let f as APIFailure where f.status == 400 || f.status == 404 {
                errorText = "That code isn't valid or has expired. Check your child's screen."
                lastRejected = (value, Date())
            } catch let f as APIFailure where f.status == 409 {
                errorText = "That code was already used. Ask your child's device for a new one."
                lastRejected = (value, Date())
            } catch {
                errorText = error.apiUserMessage
                lastRejected = (value, Date())
            }
            busy = false
        }
    }
}

/// The camera, full screen, for scanning the code on the kid's device.
struct QRScannerScreen: View {
    var onClose: () -> Void
    var onScan: (String) -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            QRScannerView(onScan: onScan)
                .ignoresSafeArea()

            // Where to hold the code.
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(Color.white, lineWidth: 4)
                .frame(width: 260, height: 260)
                .shadow(color: .black.opacity(0.35), radius: 12)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(Color.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                Text("Point the camera at the QR code on your child's device")
                    .font(Typography.font(16, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .padding(.bottom, 32)
            }
        }
        .statusBarHidden()
    }
}
