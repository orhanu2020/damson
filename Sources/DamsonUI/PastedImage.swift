import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Pictures for chat: from the clipboard, a file chooser or a drop. They are shrunk and kept as PNG data.
enum PastedImage {
    /// The longest side sent to the model; bigger pictures are scaled down.
    static let maxSide: CGFloat = 1568

    static func prepare(_ data: Data) -> Data? {
        guard let image = NSImage(data: data), let rep = image.representations.first else { return nil }
        let w = CGFloat(rep.pixelsWide > 0 ? rep.pixelsWide : Int(image.size.width))
        let h = CGFloat(rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(image.size.height))
        guard w > 0, h > 0 else { return nil }
        let scale = min(1, maxSide / max(w, h))
        let size = NSSize(width: (w * scale).rounded(), height: (h * scale).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    static func prepare(url: URL) -> Data? {
        guard let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
              let data = try? Data(contentsOf: url) else { return nil }
        return prepare(data)
    }

    /// Pictures on the clipboard: image data (a screenshot, a copied picture) or copied image files.
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [Data] {
        var found: [Data] = []
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            found += urls.compactMap { prepare(url: $0) }
        }
        if found.isEmpty, let data = pb.data(forType: .png) ?? pb.data(forType: .tiff), let png = prepare(data) { found.append(png) }
        return found
    }

    @MainActor static func choose() -> [Data] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { prepare(url: $0) }
    }

    /// Pictures dropped on a view.
    static func load(from providers: [NSItemProvider], into add: @escaping @MainActor ([Data]) -> Void) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    var url: URL?
                    if let u = item as? URL { url = u } else if let d = item as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                    if let url, let data = prepare(url: url) { Task { @MainActor in add([data]) } }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    if let data, let png = prepare(data) { Task { @MainActor in add([png]) } }
                }
            }
        }
    }
}

/// A small picture with a remove button.
struct PictureChip: View {
    let data: Data
    var onRemove: (() -> Void)?

    var body: some View {
        if let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFill()
                .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if let onRemove {
                        Button(action: onRemove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.white, Color.black.opacity(0.65)) }
                            .buttonStyle(.plain).padding(3)
                    }
                }
        }
    }
}
