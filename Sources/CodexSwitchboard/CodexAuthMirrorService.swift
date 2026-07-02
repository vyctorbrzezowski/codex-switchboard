import Foundation

struct CodexAuthMirrorResult: Equatable {
    enum Status: Equatable {
        case synced
        case skipped
    }

    let status: Status
    let profileKey: String?
    let reason: String?
}

final class CodexAuthMirrorService: @unchecked Sendable {
    private let fileManager: FileManager
    private let authURL: URL
    private let profileStoreURL: URL
    private let queue = DispatchQueue(label: "CodexSwitchboard.CodexAuthMirror")
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
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
            guard self.timer == nil else { return }

            self.lastSignature = self.fileSignature()
            _ = self.syncActiveAuth()

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
        guard matches.count == 1, let match = matches.first else {
            return CodexAuthMirrorResult(
                status: .skipped,
                profileKey: nil,
                reason: matches.isEmpty ? "no matching profile" : "ambiguous matching profiles"
            )
        }

        do {
            try copyAuth(liveAuth.root, to: match.authURL)
            try updateMeta(match, with: liveAuth)
            if let profileKey = match.sourceProfileKey, !profileKey.isEmpty {
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
            return CodexAuthMirrorResult(status: .synced, profileKey: match.sourceProfileKey, reason: nil)
        } catch {
            return CodexAuthMirrorResult(status: .skipped, profileKey: match.sourceProfileKey, reason: error.localizedDescription)
        }
    }

    private func syncIfChanged() {
        let signature = fileSignature()
        guard signature != lastSignature else { return }
        lastSignature = signature
        _ = syncActiveAuth()
    }

    private func fileSignature() -> FileSignature? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: authURL.path),
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber else {
            return nil
        }
        return FileSignature(modified: modified, size: size.int64Value)
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
                authURL: authURL,
                metaURL: metaURL,
                auth: auth,
                sourceProfileKey: meta["source_profile_key"] as? String
            )
        }
    }

    private func copyAuth(_ object: [String: Any], to url: URL) throws {
        var updated = object
        updated["last_refresh"] = ISO8601DateFormatter.codexSwitchboard.string(from: Date())
        try AppStorage.writeJSON(updated, to: url, permissions: 0o600)
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
}

private struct MirrorableCapturedProfile {
    let authURL: URL
    let metaURL: URL
    let auth: StoredCodexAuth
    let sourceProfileKey: String?

    func matches(_ live: StoredCodexAuth) -> Bool {
        guard !auth.subject.isEmpty,
              auth.subject == live.subject else {
            return false
        }

        if !auth.accountID.isEmpty,
           !live.accountID.isEmpty,
           auth.accountID != live.accountID {
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
    let idExpiresAt: Int

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
        let accessExp = (accessPayload?["exp"] as? Double) ?? (idPayload["exp"] as? Double)
        let idExp = idPayload["exp"] as? Double
        return StoredCodexAuth(
            root: root,
            idToken: idToken,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountID: (tokens["account_id"] as? String) ?? "",
            email: ((idPayload["email"] as? String) ?? "").lowercased(),
            subject: (idPayload["sub"] as? String) ?? "",
            accessExpiresAt: accessExp.map { Int($0 * 1000) } ?? 0,
            idExpiresAt: idExp.map { Int($0 * 1000) } ?? 0
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
}

private extension Data {
    init?(codexBase64URLString: String) {
        var normalized = codexBase64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        normalized += String(repeating: "=", count: (4 - normalized.count % 4) % 4)
        self.init(base64Encoded: normalized)
    }
}
