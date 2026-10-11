import Foundation

/// UI language. English is the source language and doubles as the lookup key; Russian lives in
/// `ru.lproj` next to the app and the widget.
///
/// All UI text goes through `tr(_:)` rather than SwiftUI's implicit `LocalizedStringKey`, so
/// the app and the widget resolve it the same way, the language can switch live from
/// Settings, and the widget can follow the app's choice.
public enum L10n {
    public static let supported = ["en", "ru"]

    /// A resolved language: the code, its locale and its strings.
    public struct Resolved: Sendable {
        public let language: String
        public let locale: Locale
        let bundle: Bundle?
    }

    nonisolated(unsafe) private static var current = make(nil, root: nil)
    /// Overrides `current` for one task, so tests can run in Russian alongside English ones.
    @TaskLocal public static var scoped: Resolved?
    private static var active: Resolved { scoped ?? current }

    /// Resolved language code, "en" or "ru".
    public static var language: String { active.language }
    /// Locale for dates, numbers and plural rules: the system region, in the UI language.
    public static var locale: Locale { active.locale }
    /// Folder holding the `.lproj` folders. Defaults to the running bundle's resources;
    /// preview renders point it at the repo's `Resources/Localization`.
    public nonisolated(unsafe) static var resourceRoot: URL?

    /// Sets the UI language. `preference` is "en", "ru", or anything else (e.g. "system") for
    /// the macOS language.
    public static func resolve(_ preference: String?) {
        current = make(preference, root: resourceRoot)
    }

    public static func make(_ preference: String?, root: URL?) -> Resolved {
        let code: String
        if let preference, supported.contains(preference) {
            code = preference
        } else {
            code = Bundle.preferredLocalizations(from: supported, forPreferences: Locale.preferredLanguages).first ?? "en"
        }
        let bundle = (root ?? Bundle.main.resourceURL).flatMap { Bundle(url: $0.appendingPathComponent("\(code).lproj")) }
        let system = Locale.current
        let locale = system.language.languageCode?.identifier == code
            ? system
            : Locale(identifier: system.region.map { "\(code)_\($0.identifier)" } ?? code)
        return Resolved(language: code, locale: locale, bundle: bundle)
    }

    static func string(_ key: String) -> String {
        active.bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
    }
}

/// Translated UI text for `key`, the English source string.
public func tr(_ key: String) -> String {
    L10n.string(key)
}

/// Translated format string filled with `args`; plurals come from `Localizable.stringsdict`.
public func tr(_ format: String, _ args: CVarArg...) -> String {
    String(format: L10n.string(format), locale: L10n.locale, arguments: args)
}

/// Inline Markdown (`code`, **bold**) in translated text.
public func md(_ text: String) -> AttributedString {
    (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
}
