import CryptoKit
import Darwin
import Foundation

struct CodexAuthMirrorResult: Equatable {
    enum Status: Equatable {
        case synced
        case skipped
    }

    let status: Status
    let profileKey: String?
    let reason: String?
    let rememberSignature: Bool

    init(status: Status, profileKey: String?, reason: String?, rememberSignature: Bool = false) {
        self.status = status
        self.profileKey = profileKey
        self.reason = reason
        self.rememberSignature = rememberSignature
    }
}

final class CodexAuthMirrorService: @unchecked Sendable {
    private let fileManager: FileManager
    private let authURL: URL
    private let profileStoreURL: URL
    private let queue = DispatchQueue(label: "CodexSwitchboard.CodexAuthMirror")
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var directorySource: DispatchSourceFileSystemObject?
    private var lastSignature: FileSignature?

    init(
        fileManager: FileManager = .default,
        authURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/auth.json"),
        profileStoreURL: URL = AppStorage.profilesURL,
        interval: TimeInterval = 3
    ) {
        self.fileManager = fileManager
        self.authURL = authURL
        self.profileStoreURL = profileStoreURL
        self.interval = interval
    }

    func start() {
        queue.async {
            guard self.timer == nil, self.directorySource == nil else { return }

            self.syncIfChanged(force: true)
            self.startDirectoryWatch()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + self.interval, repeating: self.interval)
            timer.setEventHandler { [weak self] in
                self?.syncIfChanged()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.directorySource?.cancel()
            self.directorySource = nil
        }
    }

    @discardableResult
    func syncActiveAuth() -> CodexAuthMirrorResult {
        CodexAuthFileLock.withLock {
            syncActiveAuthWithoutLock()
        }
    }

    private func syncActiveAuthWithoutLock() -> CodexAuthMirrorResult {
        guard let liveAuth = StoredCodexAuth.load(from: authURL) else {
            return CodexAuthMirrorResult(status: .skipped, profileKey: nil, reason: "missing live auth")
        }

        let matches = capturedProfiles().filter { $0.matches(liveAuth) }
        guard !matches.isEmpty else {
            return CodexAuthMirrorResult(
                status: .skipped,
                profileKey: nil,
                reason: "no matching profile"
            )
        }
        let matchedAccountIDs = Set(matches.map(\.auth.accountID).filter { !$0.isEmpty })
        if liveAuth.accountID.isEmpty, matchedAccountIDs.count > 1 {
            return CodexAuthMirrorResult(
                status: .skipped,
                profileKey: nil,
                reason: "ambiguous live auth account"
            )
        }

        let canonicalMatch = matches.max { lhs, rhs in
            lhs.freshnessDate < rhs.freshnessDate
        }!
        do {
            let removedProfileKeys = try CapturedProfileDedupeService.removeDuplicates(
                keeping: canonicalMatch.profileURL,
                email: liveAuth.email,
                accountID: liveAuth.accountID,
                profileStoreURL: profileStoreURL
            )
            let keysToRemove = removedProfileKeys.subtracting([canonicalMatch.sourceProfileKey].compactMap { $0 })
            try AccountProfileStore.remove(profileKeys: keysToRemove)
        } catch {
            return CodexAuthMirrorResult(status: .skipped, profileKey: nil, reason: error.localizedDescription)
        }

        guard canonicalMatch.canAccept(liveAuth) else {
            return CodexAuthMirrorResult(
                status: .skipped,
                profileKey: nil,
                reason: "live auth is older than matching profile",
                rememberSignature: true
            )
        }

        do {
            var syncedProfileKeys: [String] = []
            try copyAuth(liveAuth.root, to: canonicalMatch.authURL)
            try updateMeta(canonicalMatch, with: liveAuth)
            if let profileKey = canonicalMatch.sourceProfileKey, !profileKey.isEmpty {
                syncedProfileKeys.append(profileKey)
            }

            for profileKey in Set(syncedProfileKeys) {
                try AccountProfileStore.updateTokens(
                    profileKey: profileKey,
                    email: liveAuth.email,
                    accountID: liveAuth.accountID,
                    accessToken: liveAuth.accessToken,
                    refreshToken: liveAuth.refreshToken,
                    idToken: liveAuth.idToken,
                    expiresAt: liveAuth.accessExpiresAt
                )
            }

            return CodexAuthMirrorResult(
                status: .synced,
                profileKey: syncedProfileKeys.sorted().first,
                reason: matches.count > 1 ? "deduped matching profiles" : nil
            )
        } catch {
            return CodexAuthMirrorResult(status: .skipped, profileKey: nil, reason: error.localizedDescription)
        }
    }

    private func syncIfChanged(force: Bool = false) {
        let signature = fileSignature()
        guard force || signature != lastSignature else { return }

        let result = syncActiveAuth()
        if result.status == .synced || result.rememberSignature {
            lastSignature = signature
        }
    }

    private func startDirectoryWatch() {
        let directoryURL = authURL.deletingLastPathComponent()
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.syncIfChanged()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directorySource = source
        source.resume()
    }

    private func fileSignature() -> FileSignature? {
        guard let data = try? Data(contentsOf: authURL),
              let attrs = try? fileManager.attributesOfItem(atPath: authURL.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return FileSignature(modified: modified, size: size.int64Value, hash: data.codexSwitchboardSHA256)
    }

    private func capturedProfiles() -> [MirrorableCapturedProfile] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: profileStoreURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

            return entries.compactMap { entryURL in
                guard (try? entryURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                    return nil
                }

            let authURL = entryURL.appendingPathComponent("auth.json")
            guard let auth = StoredCodexAuth.load(from: authURL) else { return nil }

            let metaURL = entryURL.appendingPathComponent("meta.json")
            let meta = AppStorage.readJSON(metaURL) ?? [:]
            return MirrorableCapturedProfile(
                profileURL: entryURL,
                authURL: authURL,
                metaURL: metaURL,
                auth: auth,
                sourceProfileKey: meta["source_profile_key"] as? String
            )
        }
    }

    private func copyAuth(_ object: [String: Any], to url: URL) throws {
        try AppStorage.writeJSON(object, to: url, permissions: 0o600)
    }

    private func updateMeta(_ profile: MirrorableCapturedProfile, with auth: StoredCodexAuth) throws {
        var meta = AppStorage.readJSON(profile.metaURL) ?? [:]
        meta["email"] = auth.email
        if !auth.accountID.isEmpty {
            meta["account_id"] = auth.accountID
        }
        meta["expires_at"] = auth.accessExpiresAt
        try AppStorage.writeJSON(meta, to: profile.metaURL, permissions: 0o600)
    }
}

enum CodexAuthFileLock {
    private static let lock = NSRecursiveLock()

    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

private struct FileSignature: Equatable {
    let modified: Date
    let size: Int64
    let hash: String
}

private struct MirrorableCapturedProfile {
    let profileURL: URL
    let authURL: URL
    let metaURL: URL
    let auth: StoredCodexAuth
    let sourceProfileKey: String?
    var freshnessDate: Date {
        CapturedProfileDedupeService.record(for: profileURL)?.freshnessDate ?? .distantPast
    }

    func matches(_ live: StoredCodexAuth) -> Bool {
        guard !auth.subject.isEmpty,
              auth.subject == live.subject else {
            return false
        }

        guard auth.email == live.email else {
            return false
        }

        if !auth.accountID.isEmpty,
           !live.accountID.isEmpty,
           auth.accountID != live.accountID {
            return false
        }

        return true
    }

    func canAccept(_ live: StoredCodexAuth) -> Bool {
        if live.refreshToken != auth.refreshToken,
           live.idIssuedAt > 0,
           live.idIssuedAt >= auth.idIssuedAt {
            return true
        }

        if let liveLastRefresh = live.lastRefreshDate,
           let profileLastRefresh = auth.lastRefreshDate,
           liveLastRefresh < profileLastRefresh.addingTimeInterval(-2) {
            return false
        }

        if live.idIssuedAt > 0,
           auth.idIssuedAt > 0,
           live.idIssuedAt + 2_000 < auth.idIssuedAt {
            return false
        }

        return true
    }
}

struct StoredCodexAuth {
    let root: [String: Any]
    let idToken: String
    let accessToken: String
    let refreshToken: String
    let accountID: String
    let email: String
    let subject: String
    let accessExpiresAt: Int
    let idIssuedAt: Int
    let idExpiresAt: Int
    let lastRefreshDate: Date?

    static func load(from url: URL) -> StoredCodexAuth? {
        guard let root = AppStorage.readJSON(url),
              let tokens = root["tokens"] as? [String: Any],
              let idToken = tokens["id_token"] as? String,
              let accessToken = tokens["access_token"] as? String,
              let refreshToken = tokens["refresh_token"] as? String,
              let idPayload = decodePayload(idToken) else {
            return nil
        }

        let accessPayload = decodePayload(accessToken)
        let authPayload = idPayload["https://api.openai.com/auth"] as? [String: Any]
        let accessExp = (accessPayload?["exp"] as? Double) ?? (idPayload["exp"] as? Double)
        let idIat = idPayload["iat"] as? Double
        let idExp = idPayload["exp"] as? Double
        return StoredCodexAuth(
            root: root,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: ((tokens["account_id"] as? String) ?? (authPayload?["chatgpt_account_id"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            email: ((idPayload["email"] as? String) ?? "").lowercased(),
            subject: (idPayload["sub"] as? String) ?? "",
            accessExpiresAt: accessExp.map { Int($0 * 1000) } ?? 0,
            idIssuedAt: idIat.map { Int($0 * 1000) } ?? 0,
            idExpiresAt: idExp.map { Int($0 * 1000) } ?? 0,
            lastRefreshDate: parseISO8601(root["last_refresh"] as? String)
        )
    }

    private static func decodePayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = Data(codexBase64URLString: String(parts[1])),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            return nil
        }
        return payload
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
}

private extension Data {
    var codexSwitchboardSHA256: String {
        SHA256.hash(data: self)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    init?(codexBase64URLString: String) {
        var normalized = codexBase64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}
