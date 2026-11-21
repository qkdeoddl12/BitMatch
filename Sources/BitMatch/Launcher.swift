import AppKit
import SwiftUI

@main
enum Launcher {
    @MainActor
    static func main() {
        // Developer tool: `BitMatch --render icon|popover <out.png>` draws artwork without launching the app.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--render"), arguments.count > flag + 2 {
            let ok = PreviewRenderer.render(arguments[flag + 1], to: arguments[flag + 2])
            exit(ok ? 0 : 1)
        }

        // Developer tool: `BitMatch --selftest` checks the source-selection logic without touching a device.
        if arguments.contains("--selftest") {
            exit(SelfTest.run() ? 0 : 1)
        }

        // One menu bar item is enough.
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            exit(0)
        }

        // `kill` and logout send signals rather than a quit event. Route them through a normal
        // quit so the log reader child process is cleaned up too.
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }

        BitMatchApp.main()
    }

    @MainActor private static var signalSources: [DispatchSourceSignal] = []
}
