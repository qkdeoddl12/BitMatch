import AppKit

/// Finds the app that a helper process is working for.
enum ProcessOwner {
    enum Answer: Equatable {
        /// The bundle ID of the owning app.
        case app(String)
        /// Something owns the helper, but it is not an app with a bundle ID.
        case notAnApp
        /// This Mac could not say who owns it.
        case unknown
    }

    private typealias Lookup = @convention(c) (pid_t) -> pid_t

    /// `responsibility_get_pid_responsible_for_pid` is not in the public SDK, so it is looked up
    /// at run time and BitMatch keeps working if a future macOS drops it.
    private static let lookup: Lookup? = {
        let everyLoadedImage = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(everyLoadedImage, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: Lookup.self)
    }()

    static func of(_ pid: pid_t) -> Answer {
        guard let lookup, pid > 0 else { return .unknown }
        let owner = lookup(pid)
        // A helper that is reported as its own owner tells us nothing.
        guard owner > 0, owner != pid else { return .unknown }
        guard let bundle = NSRunningApplication(processIdentifier: owner)?.bundleIdentifier, !bundle.isEmpty else {
            return .notAnApp
        }
        return .app(bundle)
    }
}
