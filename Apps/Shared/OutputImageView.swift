import ImageIO
import PiRemoteCore
import SwiftUI
import UniformTypeIdentifiers

struct OutputImageList: View {
    let images: [OutputImageReference]
    let request: ((SessionAction) async throws -> AppResult)?
    @State private var selected: OutputImageReference?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(images.prefix(16).enumerated()), id: \.offset) { index, image in
                if let fault = image.fault {
                    Text("Image \(index + 1): " + explanation(fault)).font(.callout)
                } else if request != nil {
                    Button { selected = image } label: {
                        Label("View image \(index + 1)", systemImage: "photo").frame(minHeight: 44)
                    }
                } else { Text("Update the apps to view this image.").font(.caption) }
            }
        }
        .sheet(item: $selected) { image in
            if let request { OutputImageView(id: image.id, request: request) }
        }
    }

    private func explanation(_ fault: RemoteFault) -> String {
        switch fault {
        case .tooLarge: "This image exceeds 2 MiB, 20,000 pixels per side or 40 million pixels. Inspect it on the Mac."
        case .unsupportedFeature: "Unsupported image format. Use PNG, JPEG, WebP or GIF."
        case .invalidRequest: "The image data is invalid or does not match its format."
        default: fault.explanation
        }
    }
}

struct OutputImageView: View {
    let id: UUID
    let request: (SessionAction) async throws -> AppResult
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var error: String?
    @State private var zoom = 1.0
    @State private var fullResolution = false
    @State private var animated = false
    @State private var loading = false

    var body: some View {
        NavigationStack {
            VStack {
                if let error { Text(error).padding() }
                if loading { ProgressView("Loading image") }
                if let image {
                    Text("\(image.width) × \(image.height) pixels").font(.caption)
                    if animated { Text("First frame of animated image").font(.caption) }
                    GeometryReader { geometry in
                        let width = min(geometry.size.width, geometry.size.height * Double(image.width) / Double(image.height))
                        ScrollView([.horizontal, .vertical]) {
                            Image(image, scale: 1, label: Text("Pi image output")).resizable()
                                .frame(width: width * zoom, height: width * zoom * Double(image.height) / Double(image.width))
                                .frame(minWidth: geometry.size.width, minHeight: geometry.size.height)
                                .accessibilityLabel("Pi image output")
                        }
                    }
                    HStack {
                        Text("Zoom")
                        Slider(value: $zoom, in: 1...8).frame(minHeight: 44).accessibilityLabel("Image zoom")
                    }.padding(.horizontal)
                }
                Toggle("Full resolution", isOn: $fullResolution).frame(minHeight: 44).padding(.horizontal)
            }
            .navigationTitle("Image output")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .safeAreaInset(edge: .bottom) {
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity, minHeight: 44) }
                    .buttonStyle(.borderedProminent).foregroundStyle(.background).padding()
            }
            .task(id: fullResolution) { await load() }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 520)
        #endif
        .privacySensitive()
        .onDisappear { image = nil }
    }

    @MainActor private func load() async {
        loading = true; error = nil; zoom = 1
        let full = fullResolution
        defer { if !Task.isCancelled { loading = false } }
        do {
            guard case .image(let attachment) = try await request(.outputImage(id: id)) else { throw RemoteFault.incompatiblePi }
            let decoded = try await Task.detached(priority: .userInitiated) {
                let image = try OutputImageDecoder.decode(attachment, fullResolution: full)
                let source = CGImageSourceCreateWithData(attachment.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
                return (image, source.map { CGImageSourceGetCount($0) > 1 } ?? false)
            }.value
            try Task.checkCancellation()
            image = decoded.0; animated = decoded.1
        } catch {
            if !Task.isCancelled {
                self.error = error as? RemoteFault == .expired
                    ? "This image reference expired. Reload History and read its entry again."
                    : (error as? RemoteFault ?? .unavailable).explanation
            }
        }
    }
}

/// Decode only supported raster formats, with limits independent of host validation.
enum OutputImageDecoder {
    nonisolated static func decode(_ attachment: ImageAttachment, fullResolution: Bool) throws -> CGImage {
        guard attachment.data.count <= 2 * 1_024 * 1_024 else { throw RemoteFault.tooLarge }
        guard let expected = ["image/png": UTType.png, "image/jpeg": .jpeg, "image/webp": .webP, "image/gif": .gif][attachment.mimeType] else {
            throw RemoteFault.unsupportedFeature
        }
        guard let source = CGImageSourceCreateWithData(attachment.data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == expected.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { throw RemoteFault.invalidRequest }
        let w = width.doubleValue, h = height.doubleValue
        guard w.isFinite, h.isFinite, w > 0, h > 0, w <= 20_000, h <= 20_000, w * h <= 40_000_000 else { throw RemoteFault.tooLarge }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: fullResolution ? max(w, h) : 2_048,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw RemoteFault.invalidRequest }
        return image
    }
}
