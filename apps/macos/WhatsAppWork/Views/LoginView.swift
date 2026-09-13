// Login (QR linked-device) screen.
import SwiftUI
import CoreImage.CIFilterBuiltins

struct LoginView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 44))
                .foregroundStyle(.green)

            Text("WhatsApp Work")
                .font(.title.bold())

            if let qr = state.qrCode {
                QRView(string: qr)
                    .id(qr) // codes rotate; force a fresh view per code so it re-renders
                    .frame(width: 240, height: 240)
                    .padding(16)
                    .background(Color.white)
                    .cornerRadius(8)
                Text("WhatsApp → Settings → Linked Devices → Scan")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text(state.connectionState == "linking" ? "Requesting QR…" : "Connecting…")
                    .font(.callout).foregroundStyle(.secondary)
                if state.connectionState == "logged_out" {
                    Button("Link with QR") { Task { await state.startLogin() } }
                        .buttonStyle(.borderedProminent)
                }
                if state.connectionState != "linking" {
                    // Escape hatch for a poisoned device row (outdated
                    // client, temporary ban): logging out wipes it. Showing
                    // it only while "connected" hid it exactly when a dead
                    // device class needs it most.
                    Button("Log Out") { Task { await state.logout() } }
                        .buttonStyle(.bordered)
                        .help("Unlink this device and wipe local data")
                }
            }

            if let p = state.syncProgress {
                ProgressView(value: p) { Text("Syncing history… \(Int(p))%") }
                    .frame(width: 240)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if state.qrCode == nil && state.connectionState == "logged_out" {
                await state.startLogin()
            }
        }
    }
}

struct QRView: View {
    let string: String
    @State private var image = NSImage()

    var body: some View {
        Image(nsImage: image)
            .interpolation(.none) // crisp module edges — scanners hate blur
            .resizable()
            .scaledToFit()
            .onAppear { render() }
            .onChange(of: string) { _, _ in render() }
    }

    private func render() {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return }
        let ns = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        image = ns
    }
}
