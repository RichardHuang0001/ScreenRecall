import Foundation

@main
enum PreferencesTests {
    static func main() {
        let suite = "ScreenRecall.PreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { fatalError("suite unavailable") }
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = AppPreferences(defaults: defaults)
        precondition(!preferences.captureEnabled, "first launch must not capture")
        preferences.captureEnabled = true
        precondition(AppPreferences(defaults: defaults).captureEnabled, "consent was not persisted")
        preferences.excludedBundleIDs = ["com.apple.Safari", "com.apple.Mail"]
        precondition(AppPreferences(defaults: defaults).excludedBundleIDs.count == 2, "exclusions were not persisted")
        precondition(AppPreferences.parseBundleIDs("com.apple.Safari, com.apple.Mail")?.count == 2)
        precondition(AppPreferences.parseBundleIDs("invalid bundle") == nil)
        precondition(preferences.retentionHours == 24 && preferences.maximumGiB == 2)
        preferences.retentionHours = 12
        preferences.maximumGiB = 4
        precondition(AppPreferences(defaults: defaults).retentionHours == 12)
        precondition(AppPreferences(defaults: defaults).maximumGiB == 4)
        print("PASS: first-run opt-in, persisted consent, exclusions, retention settings")
    }
}
