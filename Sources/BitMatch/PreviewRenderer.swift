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
        case "players":
            // The popover while another player is being followed on "auto".
            let renderer = ImageRenderer(content: panel(.dark, scene: .otherPlayer).padding(36).background(backdrop))
            renderer.scale = 2
            image = renderer.cgImage
        case "social":
            // GitHub's link preview card: 1280 x 640.
            let renderer = ImageRenderer(content: socialCard)
            renderer.scale = 1
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

    private static let backdrop = LinearGradient(
        colors: [Color(red: 0.16, green: 0.20, blue: 0.30), Color(red: 0.07, green: 0.09, blue: 0.14)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    /// What shows up when the repository link is shared.
    private static var socialCard: some View {
        HStack(alignment: .center, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                AppIconArt()
                    .frame(width: 124, height: 124)
                    .compositingGroup()
                    .shadow(color: .black.opacity(0.4), radius: 16, y: 10)
                Text("BitMatch")
                    .font(.system(size: 84, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 30)
                Text("Your DAC, always at the sample rate\nof whatever is playing.")
                    .font(.system(size: 31, weight: .medium))
                    .foregroundStyle(.white.opacity(0.80))
                    .lineSpacing(4)
                    .padding(.top, 10)
                HStack(spacing: 10) {
                    ForEach(["Apple Music", "Spotify", "YouTube"], id: \.self) { name in
                        Text(name)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(Theme.brandTop)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Theme.brandTop.opacity(0.14)))
                    }
                }
                .padding(.top, 32)
                Text("Free, open source menu bar app for macOS")
                    .font(.system(size: 21))
                    .foregroundStyle(.white.opacity(0.5))
                    .padding(.top, 22)
            }
            .padding(.leading, 84)
            Spacer(minLength: 0)
            panel(.dark, scene: .appleMusic)
                .scaleEffect(1.08)
                .padding(.trailing, 104)
        }
        .frame(width: 1280, height: 640)
        .background(backdrop)
        .clipped()
    }

    /// The popover in dark and light appearance, side by side.
    private static var showcase: some View {
        HStack(alignment: .top, spacing: 28) {
            panel(.dark, scene: .appleMusic)
            panel(.light, scene: .spotify)
        }
        .padding(36)
        .background(backdrop)
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
