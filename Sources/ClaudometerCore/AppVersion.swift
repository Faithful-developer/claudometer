import Foundation

/// The running app's version, from its bundle (`MARKETING_VERSION` in project.yml, which
/// scripts/build-app.sh also reads). "dev" under `swift run`, which has no bundle version.
public enum AppVersion {
    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
