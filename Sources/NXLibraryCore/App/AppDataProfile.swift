import Foundation

/// Immutable location policy. The build declares its profile; filenames and branch names do not select it.
public struct AppDataProfile: Sendable {
    public let home: URL
    public let isDevelopment: Bool
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, isDevelopment: Bool) {
        self.home = home
        self.isDevelopment = isDevelopment
    }
    /// Folders are built as folders (`isDirectory: true`), never by asking the disk, so a root is the same URL
    /// before and after it is created: equal to `file.deletingLastPathComponent()` on a fresh Mac too.
    public var stableSupportRoot: URL { home.appendingPathComponent("Library/Application Support/ArcanePortal", isDirectory: true) }
    public var supportRoot: URL {
        isDevelopment ? home.appendingPathComponent("Library/Application Support/ArcanePortal-Development", isDirectory: true) : stableSupportRoot
    }
    public var cacheRoot: URL { home.appendingPathComponent("Library/Caches/" + (isDevelopment ? "ArcanePortal-Development" : "ArcanePortal"), isDirectory: true) }
    public var preferencesDomain: String { isDevelopment ? "io.github.akinware.arcaneportal.development" : "io.github.akinware.arcaneportal" }
}

/// All app-owned stores use this composition-root policy, including their default initializers.
/// Game installations, their runtime preferences and saves are separate, explicitly operated-on resources.
public enum AppData {
    public static let profile = AppDataProfile(isDevelopment: Bundle.main.object(forInfoDictionaryKey: "NXLibraryDevelopmentProfile") as? Bool == true)
    public static var supportRoot: URL { profile.supportRoot }
    public static var cacheRoot: URL { profile.cacheRoot }
    // Each packaged profile has its own bundle ID. Foundation already binds
    // standard preferences to that ID and rejects reopening it as a suite.
    public static var preferences: UserDefaults { .standard }
    public static func validateBuildIdentity(_ info: [String: Any]) throws {
        let development = info["NXLibraryDevelopmentProfile"] as? Bool == true
        let release = info["NXLibraryRelease"] as? Bool == true
        let identifier = info["CFBundleIdentifier"] as? String
        guard (development && !release && identifier == "io.github.akinware.arcaneportal.development")
                || (release && !development && identifier == "io.github.akinware.arcaneportal") else {
            throw DevelopmentProfileError.invalidConfiguration
        }
    }
    /// `checks` validate the module's own files in the copy (Porting: `prepare()`).
    public static func prepare(checks: [String: DevelopmentProfileImporter.Check]) throws {
        // An unmarked/mispackaged executable must not silently open the live profile.
        try validateBuildIdentity(Bundle.main.infoDictionary ?? [:])
        guard profile.isDevelopment else { return }
        let defaults = preferences
        _ = try DevelopmentProfileImporter(checks: checks).prepare(profile: profile, sourcePreferences: {
            UserDefaults.standard.persistentDomain(forName: "io.github.akinware.arcaneportal") ?? [:]
        }, savePreferences: { values in
            defaults.setPersistentDomain(values, forName: profile.preferencesDomain)
            guard CFPreferencesAppSynchronize(profile.preferencesDomain as CFString) else {
                throw DevelopmentProfileError.preferencesUnavailable
            }
        })
    }
}
