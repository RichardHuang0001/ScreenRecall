import Foundation

struct AppPreferences {
    private let defaults: UserDefaults
    private static let enabledKey = "captureEnabled.v1"
    private static let exclusionsKey = "excludedBundleIDs.v1"
    private static let retentionHoursKey = "retentionHours.v1"
    private static let maximumGiBKey = "maximumGiB.v1"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var captureEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    var excludedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.exclusionsKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.exclusionsKey) }
    }

    var retentionHours: Int {
        get { [6, 12, 24, 48].contains(defaults.integer(forKey: Self.retentionHoursKey)) ? defaults.integer(forKey: Self.retentionHoursKey) : 24 }
        set { defaults.set(newValue, forKey: Self.retentionHoursKey) }
    }

    var maximumGiB: Int {
        get { [1, 2, 4].contains(defaults.integer(forKey: Self.maximumGiBKey)) ? defaults.integer(forKey: Self.maximumGiBKey) : 2 }
        set { defaults.set(newValue, forKey: Self.maximumGiBKey) }
    }

    static func parseBundleIDs(_ text: String) -> Set<String>? {
        let values = text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard values.allSatisfy({ $0.contains(".") && !$0.contains(" ") }) else { return nil }
        return Set(values)
    }
}
