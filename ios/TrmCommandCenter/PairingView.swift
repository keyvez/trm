import AVFoundation
import SwiftUI

/// Pair with a Mac by scanning the code it shows, or by typing the details in
/// when a camera isn't the easiest path (a Tailnet address, say, which the QR
/// can't know in advance).
struct PairingView: View {
    @EnvironmentObject private var client: CommandCenterClient
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var port = ""
    @State private var token = ""
    @State private var scanError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    QRScannerView { url in
                        guard let pairing = Pairing(url: url) else {
                            scanError = "That code isn't a trm pairing code."
                            return
                        }
                        apply(pairing)
                    }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Scan")
                } footer: {
                    Text(scanError ?? "On your Mac: View → Pair iPhone…")
                        .foregroundStyle(scanError == nil ? Color.secondary : Color.red)
                }

                Section {
                    TextField("Host or Tailnet name", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Port", text: $port)
                        .keyboardType(.numberPad)
                    TextField("Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                    Button("Connect") {
                        guard let portValue = UInt16(port) else { return }
                        apply(Pairing(
                            name: host, host: host, hosts: [host], port: portValue,
                            token: token.trimmingCharacters(in: .whitespaces)))
                    }
                    .disabled(host.isEmpty || UInt16(port) == nil || token.isEmpty)
                } header: {
                    Text("Or enter it")
                } footer: {
                    Text("The scanned code carries the Mac's Bonjour name. If you reach it over "
                         + "Tailscale, put that address here instead — the token is the same.")
                }

                if client.pairing != nil {
                    Section {
                        Button("Forget this Mac", role: .destructive) {
                            client.pairing = nil
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle("Pair with a Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                if let existing = client.pairing {
                    host = existing.host
                    port = String(existing.port)
                    token = existing.token
                }
            }
        }
    }

    private func apply(_ pairing: Pairing) {
        client.pairing = pairing
        dismiss()
    }
}

/// A camera preview that reports the first trm pairing URL it sees.
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (URL) -> Void

    func makeUIViewController(context: Context) -> ScannerController {
        let controller = ScannerController()
        controller.onFound = onFound
        return controller
    }

    func updateUIViewController(_ controller: ScannerController, context: Context) {}

    final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
        var onFound: ((URL) -> Void)?
        private let session = AVCaptureSession()
        private var preview: AVCaptureVideoPreviewLayer?
        /// Codes repeat many times a second; act on the first one only.
        private var handled = false

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .black
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

            let preview = AVCaptureVideoPreviewLayer(session: session)
            preview.videoGravity = .resizeAspectFill
            view.layer.addSublayer(preview)
            self.preview = preview

            // Starting a capture session blocks; keep it off the main thread.
            DispatchQueue.global(qos: .userInitiated).async { [session] in
                session.startRunning()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            preview?.frame = view.bounds
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            session.stopRunning()
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput objects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !handled,
                  let object = objects.first as? AVMetadataMachineReadableCodeObject,
                  let string = object.stringValue,
                  let url = URL(string: string) else { return }
            handled = true
            onFound?(url)
        }
    }
}
