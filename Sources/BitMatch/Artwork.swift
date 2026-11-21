import AppKit
import SwiftUI

/// The BitMatch mark is one period of a sine wave drawn as discrete samples.
enum Mark {
    /// Nine samples including the zero crossings, which draw as dots. Used at large sizes.
    static let detailed: [Double] = (0...8).map { sin(2 * .pi * Double($0) / 8) }
    /// Six samples with no zero crossings. Reads better when tiny.
    static let simple: [Double] = (0..<6).map { sin(2 * .pi * (Double($0) + 0.5) / 6) }
}

/// Draws samples (-1...1) as round-capped bars growing from a shared centre line.
struct SampleBars: View {
    var samples: [Double]
    /// Bar width as a fraction of the space each sample gets.
    var fill: CGFloat = 0.56

    var body: some View {
        GeometryReader { geo in
            let slot = geo.size.width / CGFloat(samples.count)
            let barWidth = slot * fill
            let middle = geo.size.height / 2
            ForEach(samples.indices, id: \.self) { index in
                let value = samples[index]
                // The rounded end sits on the centre line; the bar reaches `extent` away from it.
                let extent = CGFloat(abs(value)) * (middle - barWidth / 2)
                let direction: CGFloat = value >= 0 ? -1 : 1
                Capsule()
                    .frame(width: barWidth, height: extent + barWidth)
                    .position(x: slot * (CGFloat(index) + 0.5), y: middle + direction * extent / 2)
            }
        }
    }
}

/// The icon artwork, filling whatever square it is given.
struct AppIconArt: View {
    /// Small renditions drop the glow and use the simpler mark.
    var small = false

    var body: some View {
        GeometryReader { geo in
            let side = geo.size.width
            let shape = RoundedRectangle(cornerRadius: side * 0.225, style: .continuous)
            let ink = LinearGradient(
                colors: [Theme.brandTop, Color(red: 0.25, green: 0.80, blue: 0.93), Theme.brandBottom],
                startPoint: .top, endPoint: .bottom)
            let bars = SampleBars(samples: small ? Mark.simple : Mark.detailed, fill: small ? 0.56 : 0.6)
            let barsWidth = side * (small ? 0.62 : 0.70)
            let barsHeight = side * (small ? 0.52 : 0.50)

            ZStack {
                // Body: deep navy falling off to near black.
                shape.fill(LinearGradient(
                    colors: [Color(red: 0.13, green: 0.17, blue: 0.27), Color(red: 0.03, green: 0.04, blue: 0.07)],
                    startPoint: .top, endPoint: .bottom))
                // Light pooling behind the waveform.
                shape.fill(RadialGradient(
                    colors: [Theme.brandBottom.opacity(0.30), .clear],
                    center: .center, startRadius: 0, endRadius: side * 0.55))
                // Soft sheen across the top edge.
                shape.fill(LinearGradient(
                    colors: [.white.opacity(0.10), .clear],
                    startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)))

                if !small {
                    ink.mask(bars)
                        .frame(width: barsWidth, height: barsHeight)
                        .blur(radius: side * 0.035)
                        .opacity(0.65)
                }
                ink.mask(bars)
                    .frame(width: barsWidth, height: barsHeight)

                shape.strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0.04)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: max(0.5, side * 0.007))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// 1024 pt canvas laid out on the macOS icon grid (824 pt body plus shadow room).
struct AppIconCanvas: View {
    var body: some View {
        AppIconArt()
            .frame(width: 824, height: 824)
            .compositingGroup()
            .shadow(color: .black.opacity(0.32), radius: 14, y: 10)
            .frame(width: 1024, height: 1024)
    }
}

enum MenuBarGlyph {
    /// Template image of the mark, sized for the menu bar.
    static let image: NSImage = {
        let samples = Mark.simple
        let barWidth: CGFloat = 2
        let gap: CGFloat = 1
        let size = NSSize(width: CGFloat(samples.count) * barWidth + CGFloat(samples.count - 1) * gap, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let middle = rect.midY
            NSColor.black.setFill()
            for (index, value) in samples.enumerated() {
                let extent = CGFloat(abs(value)) * (middle - barWidth / 2)
                let x = CGFloat(index) * (barWidth + gap)
                let y = value >= 0 ? middle - barWidth / 2 : middle - extent - barWidth / 2
                let bar = NSRect(x: x, y: y, width: barWidth, height: extent + barWidth)
                NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
