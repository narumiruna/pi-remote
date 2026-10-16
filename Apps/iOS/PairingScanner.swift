import AVFoundation
import SwiftUI
import VisionKit

struct PairingScanner: View {
    let receive: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var phase
    @State private var permitted = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if let error {
                    ContentUnavailableView("Camera unavailable", systemImage: "camera", description: Text(error))
                } else if permitted {
                    PairingCamera(active: phase == .active, receive: receive, failure: { error = $0 })
                        .overlay(alignment: .bottom) {
                            Text("Scan the pairing QR code shown by Pi Remote for Mac.")
                                .padding().background(.regularMaterial).padding()
                        }
                } else {
                    ProgressView("Requesting camera access…")
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            guard DataScannerViewController.isSupported else {
                error = "QR scanning is not supported on this device. Paste the pairing code instead."
                return
            }
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled else { return }
            guard granted else {
                error = "Allow camera access in Settings to scan a QR code, or cancel and paste the pairing code."
                return
            }
            guard DataScannerViewController.isAvailable else {
                error = "The camera is not available. Try again, or paste the pairing code."
                return
            }
            permitted = true
        }
    }
}

private struct PairingCamera: UIViewControllerRepresentable {
    let active: Bool
    let receive: (String) -> Void
    let failure: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(receive: receive, failure: failure) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        context.coordinator.active = active
        guard active, !context.coordinator.delivered else { controller.stopScanning(); return }
        guard !controller.isScanning else { return }
        do { try controller.startScanning() }
        catch {
            let failure = failure
            Task { @MainActor in failure("The camera could not start. Try again, or paste the pairing code.") }
        }
    }

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        coordinator.active = false
        controller.stopScanning()
        controller.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var active = false
        var delivered = false
        private let receive: (String) -> Void
        private let failure: (String) -> Void

        init(receive: @escaping (String) -> Void, failure: @escaping (String) -> Void) {
            self.receive = receive; self.failure = failure
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            accept(addedItems, scanner: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didUpdate updatedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            accept(updatedItems, scanner: dataScanner)
        }

        private func accept(_ items: [RecognizedItem], scanner: DataScannerViewController) {
            guard active, !delivered else { return }
            for item in items {
                guard case .barcode(let barcode) = item, let text = barcode.payloadStringValue else { continue }
                delivered = true
                scanner.stopScanning()
                receive(text)
                return
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard active, !delivered else { return }
            active = false
            dataScanner.stopScanning()
            failure("The camera became unavailable. Try again, or paste the pairing code.")
        }
    }
}
