import Foundation

extension Bundle {
    /// Bundle with the Localizable.strings tables: the app itself, or the enclosing KeyZapper.app when running as
    /// `keyzapper-helper` from `Contents/Helpers`. Elsewhere (tests, `swift run`) the German source strings are used.
    public static let keyZapper: Bundle = {
        if Bundle.main.bundleURL.pathExtension == "app" { return .main }
        let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let app, app.pathExtension == "app", let bundle = Bundle(url: app) else { return .main }
        // A bare executable has no localizations of its own, so foreign bundles would fall back to English.
        // Pick the .lproj matching the user's languages explicitly.
        let language = Bundle.preferredLocalizations(from: bundle.localizations, forPreferences: Locale.preferredLanguages).first
        return language.flatMap { bundle.path(forResource: $0, ofType: "lproj") }.flatMap(Bundle.init(path:)) ?? bundle
    }()
}

/// Localized string for non-SwiftUI text (errors, notices, helper output). Keys are the German source strings.
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: .keyZapper)
}
