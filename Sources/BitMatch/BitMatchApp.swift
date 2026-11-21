import SwiftUI

struct BitMatchApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(state: state)
        } label: {
            switch state.menuBarStyle {
            case .iconAndRate:
                HStack(spacing: 4) {
                    Image(nsImage: MenuBarGlyph.image)
                    Text(state.menuBarRate)
                }
            case .rateOnly:
                Text(state.menuBarRate)
            case .iconOnly:
                Image(nsImage: MenuBarGlyph.image)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
