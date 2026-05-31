import Foundation

struct CapturedProfileRecord {
    let profileURL: URL
    let authURL: URL
    let metaURL: URL
    let email: String
    let accountID: String
    let sourceProfileKey: String?
    let freshnessDate: Date
}

enum CapturedProfileDedupeService {
    @discardableResult
    static func removeAllDuplicates(profileStoreURL: URL = AppStorage.profilesURL) throws -> Set<String> {
        let grouped = Dictionary(grouping: records(profileStoreURL: profileStoreURL)) { record in
            "\(record.email)|\(record.accountID)"
        }
        var removedProfileKeys = Set<String>()
        for records in grouped.values where records.count > 1 {
            let keep = records.max { lhs, rhs in
                lhs.freshnessDate < rhs.freshnessDate
            }!
            let removed = try removeDuplicates(
                keeping: keep.profileURL,
                email: keep.email,
                accountID: keep.accountID,
                profileStoreURL: profileStoreURL
            )
            removedProfileKeys.formUnion(removed.subtracting([keep.sourceProfileKey].compactMap { $0 }))
        }
        return removedProfileKeys
    }

    static func records(profileStoreURL: URL = AppStorage.profilesURL) -> [CapturedProfileRecord] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: profileStoreURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry in
            record(for: entry)
        }
    }

    static func record(for profileURL: URL) -> CapturedProfileRecord? {
        guard profileURL.lastPathComponent != "backups",
              (try? profileURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return nil
        }

        let authURL = profileURL.appendingPathComponent("auth.json")
        let metaURL = profileURL.appendingPathComponent("meta.json")
        guard let authRoot = AppStorage.readJSON(authURL) else { return nil }
        let tokens = authRoot["tokens"] as? [String: Any] ?? [:]
        let auth = StoredCodexAuth.load(from: authURL)
        let meta = AppStorage.readJSON(metaURL) ?? [:]
        let email = ((meta["email"] as? String) ?? auth?.email ?? "").lowercased()
        let accountID = (meta["account_id"] as? String) ?? (tokens["account_id"] as? String) ?? auth?.accountID ?? ""
        guard !email.isEmpty, !accountID.isEmpty else { return nil }

        return CapturedProfileRecord(
            profileURL: profileURL,
            authURL: authURL,
            metaURL: metaURL,
            email: email,
            accountID: accountID,
            sourceProfileKey: meta["source_profile_key"] as? String,
            freshnessDate: freshnessDate(for: authURL, authRoot: authRoot, auth: auth)
        )
    }

    @discardableResult
    static func removeDuplicates(
        keeping keepURL: URL,
        email: String,
        accountID: String,
        profileStoreURL: URL = AppStorage.profilesURL
    ) throws -> Set<String> {
        let normalizedEmail = email.lowercased()
        let normalizedKeepPath = keepURL.standardizedFileURL.path
        let duplicates = records(profileStoreURL: profileStoreURL).filter { record in
            record.profileURL.standardizedFileURL.path != normalizedKeepPath
                && record.email == normalizedEmail
                && record.accountID == accountID
        }
        guard !duplicates.isEmpty else { return [] }

        let backupURL = try makeBackupURL(profileStoreURL: profileStoreURL)
        try backupAccountStore(to: backupURL, profileStoreURL: profileStoreURL)
        let targetRoot = backupURL.appendingPathComponent("profiles", isDirectory: true)
        try AppStorage.ensureDirectory(targetRoot, permissions: 0o700)

        var removedProfileKeys = Set<String>()
        for duplicate in duplicates {
            let targetURL = uniqueBackupProfileURL(
                targetRoot.appendingPathComponent(duplicate.profileURL.lastPathComponent, isDirectory: true)
            )
            try FileManager.default.copyItem(at: duplicate.profileURL, to: targetURL)
            try FileManager.default.removeItem(at: duplicate.profileURL)
            if let sourceProfileKey = duplicate.sourceProfileKey, !sourceProfileKey.isEmpty {
                removedProfileKeys.insert(sourceProfileKey)
            }
        }
        return removedProfileKeys
    }

    private static func freshnessDate(for authURL: URL, authRoot: [String: Any], auth: StoredCodexAuth?) -> Date {
        if let lastRefreshDate = auth?.lastRefreshDate {
            return lastRefreshDate
        }
        if let lastRefreshDate = parseISO8601(authRoot["last_refresh"] as? String) {
            return lastRefreshDate
        }
        if let idIssuedAt = auth?.idIssuedAt, idIssuedAt > 0 {
            return Date(timeIntervalSince1970: TimeInterval(idIssuedAt) / 1000)
        }
        if let modified = try? FileManager.default.attributesOfItem(atPath: authURL.path)[.modificationDate] as? Date {
            return modified
        }
        return .distantPast
    }

    private static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) {
            return date
        }

        let fallbackFormatter = ISO8601DateFormatter()
        fallbackFormatter.formatOptions = [.withInternetDateTime]
        return fallbackFormatter.date(from: raw)
    }

    private static func makeBackupURL(profileStoreURL: URL) throws -> URL {
        let timestamp = DateFormatter.codexSwitchboardBackup.string(from: Date())
        let baseURL = backupRoot(for: profileStoreURL)
            .appendingPathComponent("\(timestamp)-dedupe-profiles", isDirectory: true)
        if !FileManager.default.fileExists(atPath: baseURL.path) {
            try AppStorage.ensureDirectory(baseURL, permissions: 0o700)
            return baseURL
        }

        let uniqueURL = backupRoot(for: profileStoreURL)
            .appendingPathComponent("\(timestamp)-dedupe-profiles-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try AppStorage.ensureDirectory(uniqueURL, permissions: 0o700)
        return uniqueURL
    }

    private static func backupRoot(for profileStoreURL: URL) -> URL {
        if profileStoreURL.standardizedFileURL.path == AppStorage.profilesURL.standardizedFileURL.path {
            return AppStorage.backupsURL
        }
        return profileStoreURL.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true)
    }

    private static func backupAccountStore(to backupURL: URL, profileStoreURL: URL) throws {
        guard profileStoreURL.standardizedFileURL.path == AppStorage.profilesURL.standardizedFileURL.path else {
            return
        }
        guard FileManager.default.fileExists(atPath: AppStorage.accountsURL.path) else { return }
        let targetRoot = backupURL.appendingPathComponent("app-store", isDirectory: true)
        try AppStorage.ensureDirectory(targetRoot, permissions: 0o700)
        try FileManager.default.copyItem(
            at: AppStorage.accountsURL,
            to: targetRoot.appendingPathComponent(AppStorage.accountsURL.lastPathComponent)
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: targetRoot.appendingPathComponent(AppStorage.accountsURL.lastPathComponent).path
        )
    }

    private static func uniqueBackupProfileURL(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        var index = 2
        while true {
            let candidate = parent.appendingPathComponent("\(name)-\(index)", isDirectory: true)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}
