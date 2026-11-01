import Foundation

/// What the user chose for one app. `deviceUID == nil` means "system default output".
struct Rule: Codable, Equatable {
    var deviceUID: String?
    var deviceName: String?
    var volume: Float = 1

    /// Default device at 100% needs no tap at all.
    var isDefault: Bool { deviceUID == nil && volume >= 1 }
}

/// Rules keyed by app bundle ID, persisted as JSON in UserDefaults.
struct RouteStore {
    var defaults: UserDefaults = .standard
    private let key = "rules"

    func load() -> [String: Rule] {
        guard let data = defaults.data(forKey: key),
              let rules = try? JSONDecoder().decode([String: Rule].self, from: data) else { return [:] }
        return rules
    }

    func save(_ rules: [String: Rule]) {
        defaults.set(try? JSONEncoder().encode(rules), forKey: key)
    }
}
