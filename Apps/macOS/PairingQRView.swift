import SwiftUI

struct PairingQRView: View {
    let code: String

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("Pair your iPhone").font(.title2)
                if code.isEmpty {
                    Text("This pairing code is no longer available. Close this sheet and select Pair iPhone to create a new code.")
                } else {
                    if let image = PairingQRCode.image(for: code) {
                        Image(image, scale: 1, label: Text("Pairing QR code"))
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .padding(24)
                            .background(.white)
                            .frame(maxWidth: 440)
                        Text("In Pi Remote on your iPhone, open Connections, select Pair a Mac, then Scan QR code.")
                    } else {
                        Text("This code is too large for a QR code. Copy the pairing code and paste it into Pi Remote on your iPhone.")
                    }
                    Text("The code expires after two minutes. Approve the device on this Mac after the phone requests pairing.")
                        .font(.callout).foregroundStyle(.primary.opacity(0.75))
                    Text("This code gives access to pairing. Do not share it or include it in screenshots.")
                        .font(.callout)
                    Button("Copy pairing code") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                }
            }
            .multilineTextAlignment(.center)
            .padding(24)
        }
    }
}
