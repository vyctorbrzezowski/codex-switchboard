import Foundation

/// Stores resolved workspace names by `account_id` to avoid slow refetches on every refresh.
enum TeamNameCacheStore {

    private struct Entry: Codable {
        var name: String
        var updatedAtEpoch: TimeInterval
    }

    private struct Payload: Codable {
        var entries: [String: Entry]
    }

    private static let cacheTTL: TimeInterval = 7 * 24 * 60 * 60

    private static var url: URL {
        AppStorage.rootURL.appendingPathComponent("team-name-cache.json")
    }

    static func load() -> [String: String] {
        let now = Date().timeIntervalSince1970
        let freshEntries = freshEntries(from: loadPayload().entries, now: now)

        if !freshEntries.isEmpty {
            return persistIfPruned(freshEntries)
        }

        let seeded = seedEntriesFromSnapshot(now: now)
        if !seeded.isEmpty {
            savePayload(Payload(entries: seeded))
            return seeded.mapValues { $0.name }
        }

        return [:]
    }

    static func save(_ names: [String: String]) {
        guard !names.isEmpty else { return }

        let now = Date().timeIntervalSince1970
        var entries = loadPayload().entries

        for (accountID, name) in names
        where !accountID.isEmpty
            && !accountID.isLikelyPersonalAccountID
            && !name.isEmpty
            && !name.isGenericWorkspaceName {
            entries[accountID] = Entry(name: name, updatedAtEpoch: now)
        }

        entries = freshEntries(from: entries, now: now)
        savePayload(Payload(entries: entries))
    }

    private static func freshEntries(
        from entries: [String: Entry],
        now: TimeInterval
    ) -> [String: Entry] {
        entries.filter { accountID, entry in
            !accountID.isEmpty
            && !accountID.isLikelyPersonalAccountID
            && !entry.name.isEmpty
            && !entry.name.isGenericWorkspaceName
            && now - entry.updatedAtEpoch <= cacheTTL
        }
    }

    private static func persistIfPruned(_ entries: [String: Entry]) -> [String: String] {
        let payload = loadPayload()
        if entries.count != payload.entries.count {
            savePayload(Payload(entries: entries))
        }
        return entries.mapValues { $0.name }
    }

    private static func seedEntriesFromSnapshot(now: TimeInterval) -> [String: Entry] {
        guard let snapshot = AccountSnapshotStore.load() else { return [:] }

        var seeded: [String: Entry] = [:]
        for account in snapshot.accounts {
            guard !account.workspace.isEmpty,
                  !account.workspace.isGenericWorkspaceName,
                  let accountID = account.id.split(separator: "|", maxSplits: 1).last,
                  !accountID.isEmpty,
                  !String(accountID).isLikelyPersonalAccountID,
                  !account.plan.isPersonalPlanType else { continue }

            seeded[String(accountID)] = Entry(name: account.workspace, updatedAtEpoch: now)
        }
        return seeded
    }

    private static func loadPayload() -> Payload {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return Payload(entries: [:])
        }
        return payload
    }

    private static func savePayload(_ payload: Payload) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let tempURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try? data.write(to: tempURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
        try? FileManager.default.moveItem(at: tempURL, to: url)
    }
}
