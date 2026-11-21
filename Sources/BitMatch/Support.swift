import SwiftUI
import os

let appLog = Logger(subsystem: "io.github.qkdeoddl12.BitMatch", category: "app")

private let prefersKorean = Locale.preferredLanguages.first?.hasPrefix("ko") == true

/// Picks the Korean string when the system language is Korean, English otherwise.
func L(_ english: String, _ korean: String) -> String {
    prefersKorean ? korean : english
}

/// 44100 -> "44.1", 48000 -> "48"
func rateNumber(_ rate: Double) -> String {
    let khz = rate / 1000
    return khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
}

/// 44100 -> "44.1 kHz"
func formatRate(_ rate: Double) -> String {
    "\(rateNumber(rate)) kHz"
}

/// The single source of truth for the version; build.sh reads it from here.
let appVersion = "0.1.0"

enum Theme {
    static let brandTop = Color(red: 0.37, green: 0.95, blue: 0.76)
    static let brandBottom = Color(red: 0.23, green: 0.62, blue: 1.0)

    static func good(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 0.27, green: 0.87, blue: 0.64) : Color(red: 0.03, green: 0.60, blue: 0.41)
    }

    static func warn(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(red: 1.0, green: 0.71, blue: 0.27) : Color(red: 0.84, green: 0.45, blue: 0.0)
    }

    /// Text colour that stays readable on top of `good` / `warn` fills.
    static func onStatus(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.black.opacity(0.85) : .white
    }
}
