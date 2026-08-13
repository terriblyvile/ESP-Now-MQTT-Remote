import Foundation

/// Finding the firmware checkout this app is meant to write to.
///
/// The Python flasher never had to ask: it lived inside the repository and
/// walked up from its own source file. A `.app` can be dragged anywhere and is
/// launched with a working directory of `/`, so the location has to be
/// discovered once and then remembered.
public enum ProjectRoot {
    private static let defaultsKey = "projectRoot"

    /// A directory is the project if it holds the two files everything else
    /// keys off. Checking both keeps a sibling checkout, or a stray folder that
    /// merely contains a `platformio.ini`, from being adopted silently.
    public static func isProject(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.appendingPathComponent("platformio.ini").path)
            && fm.fileExists(atPath: url.appendingPathComponent("include/config.h").path)
    }

    /// The remembered choice, if it still looks like the project.
    ///
    /// Validated on the way out because a folder can be moved or renamed
    /// between launches, and a stale path would otherwise surface as a write
    /// failure much later on.
    public static var remembered: URL? {
        guard let path = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        let url = URL(fileURLWithPath: path)
        return isProject(url) ? url : nil
    }

    public static func remember(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: defaultsKey)
    }

    public static func forget() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }

    /// Best guess at the project without asking, or nil to fall back to a picker.
    ///
    /// Order matters: an explicit choice wins over anything inferred, and the
    /// working directory beats the executable's location so that running from a
    /// checkout during development targets that checkout rather than whichever
    /// one the binary was built in.
    public static func discover() -> URL? {
        if let remembered { return remembered }

        let candidates = [
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            // .build/debug/ESPNowFlasher, or Contents/MacOS inside a bundle
            // sitting in the checkout.
            URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath(),
        ]
        for candidate in candidates {
            if let found = ancestor(of: candidate) { return found }
        }
        return nil
    }

    /// The nearest enclosing directory that is the project, including `url`.
    private static func ancestor(of url: URL) -> URL? {
        var current = url.standardizedFileURL
        // Bounded rather than `while current.path != "/"`: a URL that fails to
        // shorten would otherwise spin forever, and no checkout is 40 deep.
        for _ in 0..<40 {
            if isProject(current) { return current }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent == current { break }
            current = parent
        }
        return nil
    }
}
