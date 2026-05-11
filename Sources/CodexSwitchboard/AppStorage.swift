import Foundation

enum AppStorage {
    private static let fileManager = FileManager.default

    static var rootURL: URL {
        let url = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("CodexSwitchboard", isDirectory: true)
        try? ensureDirectory(url, permissions: 0o700)
        return url
    }

    static var profilesURL: URL {
        let url = rootURL.appendingPathComponent("profiles", isDirectory: true)
        try? ensureDirectory(url, permissions: 0o700)
        return url
    }

    static var backupsURL: URL {
        let url = rootURL.appendingPathComponent("backups", isDirectory: true)
        try? ensureDirectory(url, permissions: 0o700)
        return url
    }

    static var accountsURL: URL {
        rootURL.appendingPathComponent("accounts.json")
    }

    static func ensureDirectory(_ url: URL, permissions: Int) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    static func writeJSON(_ object: Any, to url: URL, permissions: Int = 0o600) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try ensureDirectory(url.deletingLastPathComponent(), permissions: 0o700)
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.moveItem(at: tempURL, to: url)
    }

    static func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct AccountProfileCollection {
    var profiles: [String: [String: Any]]
    var orderedKeys: [String]
}

enum AccountProfileStore {
    static func load() -> AccountProfileCollection {
        if let local = loadLocal(), !local.profiles.isEmpty {
            return local
        }

        return AccountProfileCollection(profiles: [:], orderedKeys: [])
    }

    static func loadLocalProfiles() -> [String: [String: Any]] {
        loadLocal()?.profiles ?? [:]
    }

    static var hasProfiles: Bool {
        !loadLocalProfiles().isEmpty
    }

    static func upsert(
        profileKey: String,
        oldProfileKey: String?,
        email: String,
        accountID: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Int
    ) throws {
        var root = accountsRoot()
        var profiles = root["profiles"] as? [String: Any] ?? [:]
        var entry = profiles[profileKey] as? [String: Any] ?? [:]

        if let oldProfileKey,
           oldProfileKey != profileKey,
           let oldEntry = profiles[oldProfileKey] as? [String: Any] {
            entry = oldEntry.merging(entry) { current, _ in current }
            profiles.removeValue(forKey: oldProfileKey)
            replaceProfileKey(in: &root, from: oldProfileKey, to: profileKey)
        }

        entry["access"] = accessToken
        entry["refresh"] = refreshToken
        entry["expires"] = expiresAt
        entry["provider"] = "openai-codex"
        entry["type"] = "oauth"
        entry["email"] = email
        entry["accountId"] = accountID

        removeDuplicateProfiles(from: &profiles, root: &root, keeping: profileKey, email: email, accountID: accountID)
        profiles[profileKey] = entry
        root["profiles"] = profiles
        if root["version"] == nil {
            root["version"] = 1
        }
        appendToDefaultOrder(in: &root, key: profileKey)
        try AppStorage.writeJSON(root, to: AppStorage.accountsURL, permissions: 0o600)
    }

    static func remove(profileKeys: Set<String>) throws {
        guard !profileKeys.isEmpty else { return }
        var root = accountsRoot()
        var profiles = root["profiles"] as? [String: Any] ?? [:]
        for key in profileKeys {
            profiles.removeValue(forKey: key)
            removeProfileKey(in: &root, key: key)
        }
        root["profiles"] = profiles
        try AppStorage.writeJSON(root, to: AppStorage.accountsURL, permissions: 0o600)
    }

    private static func loadLocal() -> AccountProfileCollection? {
        guard let root = AppStorage.readJSON(AppStorage.accountsURL),
              let profiles = root["profiles"] as? [String: [String: Any]] else {
            return nil
        }
        return AccountProfileCollection(profiles: profiles, orderedKeys: orderedKeys(root: root, profiles: profiles))
    }

    private static func accountsRoot() -> [String: Any] {
        AppStorage.readJSON(AppStorage.accountsURL) ?? ["version": 1, "profiles": [:], "order": ["default": []]]
    }

    private static func orderedKeys(root: [String: Any], profiles: [String: [String: Any]]) -> [String] {
        let orderMap = root["order"] as? [String: [String]] ?? [:]
        var ordered: [String] = []
        var seen = Set<String>()
        for keys in orderMap.values {
            for key in keys where profiles[key] != nil && !seen.contains(key) {
                seen.insert(key)
                ordered.append(key)
            }
        }
        for key in profiles.keys.sorted() where !seen.contains(key) {
            ordered.append(key)
        }
        return ordered
    }

    private static func appendToDefaultOrder(in root: inout [String: Any], key: String) {
        var order = root["order"] as? [String: Any] ?? [:]
        var keys = order["default"] as? [String] ?? []
        if !keys.contains(key) {
            keys.append(key)
        }
        order["default"] = keys
        root["order"] = order
    }

    private static func removeDuplicateProfiles(
        from profiles: inout [String: Any],
        root: inout [String: Any],
        keeping profileKey: String,
        email: String,
        accountID: String
    ) {
        guard !accountID.isEmpty else { return }
        let duplicates = profiles.compactMap { key, value -> String? in
            guard key != profileKey,
                  let entry = value as? [String: Any],
                  (entry["accountId"] as? String) == accountID,
                  (entry["email"] as? String)?.lowercased() == email else {
                return nil
            }
            return key
        }
        for key in duplicates {
            profiles.removeValue(forKey: key)
            removeProfileKey(in: &root, key: key)
        }
    }

    private static func replaceProfileKey(in root: inout [String: Any], from oldKey: String, to newKey: String) {
        guard var order = root["order"] as? [String: Any] else { return }
        for (group, value) in order {
            guard let keys = value as? [String] else { continue }
            var seen = Set<String>()
            var updated: [String] = []
            for key in keys {
                let next = key == oldKey ? newKey : key
                guard !seen.contains(next) else { continue }
                seen.insert(next)
                updated.append(next)
            }
            order[group] = updated
        }
        root["order"] = order
    }

    private static func removeProfileKey(in root: inout [String: Any], key: String) {
        guard var order = root["order"] as? [String: Any] else { return }
        for (group, value) in order {
            guard let keys = value as? [String] else { continue }
            order[group] = keys.filter { $0 != key }
        }
        root["order"] = order
    }
}
