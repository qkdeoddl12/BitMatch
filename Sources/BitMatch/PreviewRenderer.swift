import AppKit
import SwiftUI

/// Renders the icon and README screenshots straight from the SwiftUI views.
@MainActor
enum PreviewRenderer {
    static func render(_ kind: String, to path: String) -> Bool {
        let image: CGImage?
        switch kind {
        case "icon":
            let renderer = ImageRenderer(content: AppIconCanvas())
            renderer.scale = 1
            image = renderer.cgImage
        case "popover":
            let renderer = ImageRenderer(content: showcase)
            renderer.scale = 2
            image = renderer.cgImage
        default:
            FileHandle.standardError.write(Data("unknown render kind: \(kind)\n".utf8))
            return false
        }
        guard let image,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }

    /// The popover in dark and light appearance, side by side.
    private static var showcase: some View {
        HStack(alignment: .top, spacing: 28) {
            panel(.dark, scene: .appleMusic)
            panel(.light, scene: .spotify)
        }
        .padding(36)
        .background(LinearGradient(
            colors: [Color(red: 0.16, green: 0.20, blue: 0.30), Color(red: 0.07, green: 0.09, blue: 0.14)],
            startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private static func panel(_ scheme: ColorScheme, scene: AppState.SampleScene) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return PopoverView(state: .sample(scene))
            .background(scheme == .dark ? Color(white: 0.13) : Color(white: 0.97))
            .clipShape(shape)
            .compositingGroup()
            .overlay(shape.strokeBorder(Color.white.opacity(scheme == .dark ? 0.12 : 0), lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .environment(\.colorScheme, scheme)
    }
}
