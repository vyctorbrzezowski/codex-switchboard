import AppKit
import CryptoKit
import Darwin
import Foundation
import Network
import Security

struct CapturedCodexAccount {
    let profileName: String
    let email: String
    let accountID: String
    let sourceProfileKey: String?
}

enum CodexAccountCaptureError: LocalizedError {
    case callbackServerUnavailable
    case browserOpenFailed
    case loginTimedOut
    case loginFailed(String)
    case tokenExchangeFailed(Int)
    case invalidTokenResponse
    case staleTokenResponse
    case missingIdentity
    case identityMismatch(expected: String, got: String)
    case invalidProfileName
    case localProfileInvalid(URL)

    var errorDescription: String? {
        switch self {
        case .callbackServerUnavailable:
            return "Local login port is unavailable."
        case .browserOpenFailed:
            return "Could not open the browser."
        case .loginTimedOut:
            return "Login timed out before the callback."
        case let .loginFailed(message):
            return "Login was canceled or refused: \(message)."
        case let .tokenExchangeFailed(status):
            return "OAuth code exchange failed (\(status))."
        case .invalidTokenResponse:
            return "Invalid OAuth response."
        case .staleTokenResponse:
            return "Login returned an old auth snapshot. Please sign out of OpenAI in the browser and sign in again."
        case .missingIdentity:
            return "Login did not include email or account_id."
        case let .identityMismatch(expected, got):
            return "Login does not match the selected row. Expected: \(expected). Got: \(got)."
        case .invalidProfileName:
            return "Invalid profile name."
        case let .localProfileInvalid(url):
            return "Invalid account store: \(url.path)"
        }
    }
}

final class CodexAccountCaptureService: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let homeURL = FileManager.default.homeDirectoryForCurrentUser
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private let authorizeURL = URL(string: "https://auth.openai.com/oauth/authorize")!
    private let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private let redirectURI = "http://localhost:1455/auth/callback"
    private let scope = "openid profile email offline_access"
    private let loginTokenIssueTolerance: TimeInterval = 600

    private var profileStoreURL: URL {
        AppStorage.profilesURL
    }

    func captureNewAccount() async throws -> CapturedCodexAccount {
        let loginStartedAt = Date()
        let verifier = try randomURLSafeString(byteCount: 48)
        let challenge = codeChallenge(for: verifier)
        let state = try randomURLSafeString(byteCount: 24)
        let callbackServer = try OAuthCallbackServer(state: state)
        defer { callbackServer.close() }

        let loginURL = makeAuthorizationURL(challenge: challenge, state: state)
        let opened = await MainActor.run {
            NSWorkspace.shared.open(loginURL)
        }
        guard opened else {
            throw CodexAccountCaptureError.browserOpenFailed
        }

        let callbackResult = await withTaskCancellationHandler {
            await callbackServer.waitForResult(timeout: 300)
        } onCancel: {
            callbackServer.close()
        }
        try Task.checkCancellation()

        guard let callbackResult else {
            throw CodexAccountCaptureError.loginTimedOut
        }

        let code: String
        switch callbackResult {
        case let .code(value):
            code = value
        case let .failure(message):
            throw CodexAccountCaptureError.loginFailed(message)
        }

        let tokenResponse = try await exchangeCode(code, verifier: verifier)
        try validateFreshLoginToken(tokenResponse, startedAt: loginStartedAt)
        let identity = try identity(from: tokenResponse.idToken)
        let capture = try CodexAuthFileLock.withLock {
            let localProfileKey = try plannedLocalProfileKey(identity: identity)
            let name = try writeCapturedAuth(
                tokenResponse,
                identity: identity,
                sourceProfileKey: localProfileKey
            )
            try updateLocalProfiles(
                tokenResponse,
                identity: identity,
                profileKey: localProfileKey,
                oldProfileKey: nil
            )
            return CapturedCodexAccount(
                profileName: name,
                email: identity.email,
                accountID: identity.accountID,
                sourceProfileKey: localProfileKey
            )
        }

        return capture
    }

    func captureAccount(for target: Account) async throws -> CapturedCodexAccount {
        let loginStartedAt = Date()
        let verifier = try randomURLSafeString(byteCount: 48)
        let challenge = codeChallenge(for: verifier)
        let state = try randomURLSafeString(byteCount: 24)
        let callbackServer = try OAuthCallbackServer(state: state)
        defer { callbackServer.close() }

        let loginURL = makeAuthorizationURL(
            challenge: challenge,
            state: state,
            loginHint: target.email
        )
        let opened = await MainActor.run {
            NSWorkspace.shared.open(loginURL)
        }
        guard opened else {
            throw CodexAccountCaptureError.browserOpenFailed
        }

        let callbackResult = await withTaskCancellationHandler {
            await callbackServer.waitForResult(timeout: 300)
        } onCancel: {
            callbackServer.close()
        }
        try Task.checkCancellation()

        guard let callbackResult else {
            throw CodexAccountCaptureError.loginTimedOut
        }

        let code: String
        switch callbackResult {
        case let .code(value):
            code = value
        case let .failure(message):
            throw CodexAccountCaptureError.loginFailed(message)
        }

        let tokenResponse = try await exchangeCode(code, verifier: verifier)
        try validateFreshLoginToken(tokenResponse, startedAt: loginStartedAt)
        let identity = try identity(from: tokenResponse.idToken)
        try validate(identity: identity, matches: target)
        let capture = try CodexAuthFileLock.withLock {
            let localProfileKey = try plannedLocalProfileKey(identity: identity, target: target)
            let name = try writeCapturedAuth(
                tokenResponse,
                identity: identity,
                sourceProfileKey: localProfileKey
            )
            try updateLocalProfiles(
                tokenResponse,
                identity: identity,
                profileKey: localProfileKey,
                oldProfileKey: target.profileKey
            )
            return CapturedCodexAccount(
                profileName: name,
                email: identity.email,
                accountID: identity.accountID,
                sourceProfileKey: localProfileKey
            )
        }

        return capture
    }

    private func makeAuthorizationURL(challenge: String, state: String, loginHint: String? = nil) -> URL {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "id_token_add_organizations", value: "true"),
            URLQueryItem(name: "codex_cli_simplified_flow", value: "true"),
            URLQueryItem(name: "originator", value: "codex_cli_rs"),
            URLQueryItem(name: "prompt", value: "login"),
        ]
        if let loginHint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !loginHint.isEmpty {
            queryItems.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        components.queryItems = queryItems
        return components.url!
    }

    private func exchangeCode(_ code: String, verifier: String) async throws -> OAuthTokenResponse {
        var request = URLRequest(url: tokenURL, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = URLSearchParams([
            ("grant_type", "authorization_code"),
            ("client_id", clientID),
            ("code", code),
            ("code_verifier", verifier),
            ("redirect_uri", redirectURI),
        ]).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CodexAccountCaptureError.tokenExchangeFailed(status)
        }

        let decoded = try JSONDecoder().decode(OAuthTokenResponse.self, from: data)
        guard !decoded.accessToken.isEmpty,
              !decoded.refreshToken.isEmpty,
              !decoded.idToken.isEmpty else {
            throw CodexAccountCaptureError.invalidTokenResponse
        }
        return decoded
    }

    private func validateFreshLoginToken(_ tokenResponse: OAuthTokenResponse, startedAt: Date) throws {
        let payload = try decodeJWTPayload(tokenResponse.idToken)
        guard let issuedAtSeconds = payload["iat"] as? Double,
              let expiresAtSeconds = payload["exp"] as? Double else {
            throw CodexAccountCaptureError.invalidTokenResponse
        }

        let issuedAt = Date(timeIntervalSince1970: issuedAtSeconds)
        let expiresAt = Date(timeIntervalSince1970: expiresAtSeconds)
        let now = Date()
        guard issuedAt >= startedAt.addingTimeInterval(-loginTokenIssueTolerance),
              expiresAt > now.addingTimeInterval(60) else {
            throw CodexAccountCaptureError.staleTokenResponse
        }
    }

    private func identity(from idToken: String) throws -> CapturedIdentity {
        let payload = try decodeJWTPayload(idToken)
        guard let email = (payload["email"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !email.isEmpty,
              let auth = payload["https://api.openai.com/auth"] as? [String: Any],
              let accountID = (auth["chatgpt_account_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !accountID.isEmpty else {
            throw CodexAccountCaptureError.missingIdentity
        }
        return CapturedIdentity(email: email, accountID: accountID)
    }

    private func validate(identity: CapturedIdentity, matches target: Account) throws {
        guard identity.email == target.email.lowercased() else {
            throw CodexAccountCaptureError.identityMismatch(
                expected: target.email.lowercased(),
                got: identity.email
            )
        }

        let expectedAccountID = target.accountID.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.plan.isPersonalPlanType
            || target.workspace.isPersonalPlanType
            || expectedAccountID.isLikelyPersonalAccountID {
            return
        }

        if !expectedAccountID.isEmpty {
            guard identity.accountID == expectedAccountID else {
                throw CodexAccountCaptureError.identityMismatch(
                    expected: expectedAccountID,
                    got: identity.accountID
                )
            }
            return
        }
    }

    private func writeCapturedAuth(
        _ tokenResponse: OAuthTokenResponse,
        identity: CapturedIdentity,
        sourceProfileKey: String?
    ) throws -> String {
        try ensureDirectory(profileStoreURL, permissions: 0o700)

        let profileName = try resolveProfileName(email: identity.email, accountID: identity.accountID)
        let profileURL = profileStoreURL.appendingPathComponent(profileName, isDirectory: true)
        try ensureDirectory(profileURL, permissions: 0o700)

        let payload: [String: Any] = [
            "OPENAI_API_KEY": NSNull(),
            "auth_mode": "chatgpt",
            "last_refresh": ISO8601DateFormatter.codexSwitchboard.string(from: Date()),
            "tokens": [
                "id_token": tokenResponse.idToken,
                "access_token": tokenResponse.accessToken,
                "refresh_token": tokenResponse.refreshToken,
                "account_id": identity.accountID,
            ],
        ]

        let authURL = profileURL.appendingPathComponent("auth.json")
        try writeJSONObject(payload, to: authURL, permissions: 0o600)

        let meta: [String: Any] = [
            "email": identity.email,
            "account_id": identity.accountID,
            "source_profile_key": sourceProfileKey ?? NSNull(),
            "captured_at": ISO8601DateFormatter.codexSwitchboard.string(from: Date()),
            "expires_at": Int(tokenResponse.expiresAt),
        ]
        try writeJSONObject(meta, to: profileURL.appendingPathComponent("meta.json"), permissions: 0o600)
        let removedProfileKeys = try CapturedProfileDedupeService.removeDuplicates(
            keeping: profileURL,
            email: identity.email,
            accountID: identity.accountID,
            profileStoreURL: profileStoreURL
        )
        let keysToRemove = removedProfileKeys.subtracting([sourceProfileKey].compactMap { $0 })
        try AccountProfileStore.remove(profileKeys: keysToRemove)

        return profileName
    }

    private func updateLocalProfiles(
        _ tokenResponse: OAuthTokenResponse,
        identity: CapturedIdentity,
        profileKey: String,
        oldProfileKey: String?
    ) throws {
        try AccountProfileStore.upsert(
            profileKey: profileKey,
            oldProfileKey: oldProfileKey,
            email: identity.email,
            accountID: identity.accountID,
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expiresAt: Int(tokenResponse.expiresAt)
        )
    }

    private func removeDuplicateProfiles(
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

    private func plannedLocalProfileKey(
        identity: CapturedIdentity
    ) throws -> String {
        let profiles = AccountProfileStore.load().profiles

        return resolveLocalProfileKey(
            profiles: profiles,
            email: identity.email,
            accountID: identity.accountID
        )
    }

    private func plannedLocalProfileKey(identity: CapturedIdentity, target: Account) throws -> String {
        let profiles = AccountProfileStore.load().profiles

        return resolveLocalProfileKey(
            profiles: profiles,
            email: identity.email,
            accountID: identity.accountID,
            target: target
        )
    }

    private func resolveLocalProfileKey(
        profiles: [String: Any],
        email: String,
        accountID: String,
        target: Account
    ) -> String {
        let targetScope = profileScopeSegment(for: target)
        let resolvedScope = accountScopeSegment(accountID: accountID, profiles: profiles)
        let scope = targetScope.isLegacyProfileScope ? (resolvedScope ?? "team") : targetScope
        let base = "openai-codex:\(scope):\(email)"
        let targetProfileKey = target.profileKey

        if let existing = profiles[base] as? [String: Any],
           let existingAccountID = existing["accountId"] as? String,
           !existingAccountID.isEmpty,
           existingAccountID != accountID,
           targetProfileKey != base {
            return uniqueLocalProfileKey(base: base, accountID: accountID, profiles: profiles)
        }

        return base
    }

    private func resolveLocalProfileKey(
        profiles: [String: Any],
        email: String,
        accountID: String
    ) -> String {
        let resolvedScope = accountScopeSegment(accountID: accountID, profiles: profiles)
        let scope = resolvedScope ?? "team"
        let base = "openai-codex:\(scope):\(email)"

        if let existing = profiles[base] as? [String: Any],
           let existingAccountID = existing["accountId"] as? String,
           !existingAccountID.isEmpty,
           existingAccountID != accountID {
            return uniqueLocalProfileKey(base: base, accountID: accountID, profiles: profiles)
        }

        return base
    }

    private func accountScopeSegment(accountID: String, profiles: [String: Any]) -> String? {
        guard !accountID.isEmpty else { return nil }

        for (key, value) in profiles {
            guard let entry = value as? [String: Any],
                  (entry["accountId"] as? String) == accountID,
                  let scope = localScopeSegment(from: key),
                  !scope.isLegacyProfileScope else {
                continue
            }
            return scope
        }

        return nil
    }

    private func localScopeSegment(from key: String) -> String? {
        let parts = key.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              parts[0] == "openai-codex" else {
            return nil
        }
        return String(parts[1])
    }

    private func profileScopeSegment(for target: Account) -> String {
        if let segment = sanitizedKeySegment(target.workspace),
           segment != "team" {
            return segment
        }

        if let segment = sanitizedKeySegment(target.plan),
           segment != "team" {
            return segment
        }

        if let keySegment = target.profileKey?.split(separator: ":").dropFirst().first,
           let segment = sanitizedKeySegment(String(keySegment)),
           !segment.contains("@"),
           !segment.isLegacyProfileScope {
            return segment
        }

        return "default"
    }

    private func sanitizedKeySegment(_ raw: String) -> String? {
        AccountProfileNaming.sanitizedKeySegment(raw)
    }

    private func uniqueLocalProfileKey(
        base: String,
        accountID: String,
        profiles: [String: Any]
    ) -> String {
        let suffix = accountID
            .filter { $0.isLetter || $0.isNumber }
            .prefix(8)
        let stableSuffix = suffix.isEmpty ? UUID().uuidString.prefix(8) : suffix
        var candidate = "\(base):\(stableSuffix)"
        var index = 2
        while profiles[candidate] != nil {
            candidate = "\(base):\(stableSuffix)-\(index)"
            index += 1
        }
        return candidate
    }

    private func replaceProfileKey(in root: inout [String: Any], from oldKey: String, to newKey: String) {
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

    private func removeProfileKey(in root: inout [String: Any], key: String) {
        guard var order = root["order"] as? [String: Any] else { return }

        for (group, value) in order {
            guard let keys = value as? [String] else { continue }
            order[group] = keys.filter { $0 != key }
        }

        root["order"] = order
    }

    private func resolveProfileName(email: String, accountID: String) throws -> String {
        let base = try sanitizedProfileName(email)
        let baseURL = profileStoreURL.appendingPathComponent(base, isDirectory: true)
        if !fileManager.fileExists(atPath: baseURL.path) || storedAccountID(in: baseURL) == accountID {
            return base
        }

        let suffix = accountID
            .filter { $0.isLetter || $0.isNumber }
            .prefix(8)
        guard !suffix.isEmpty else {
            throw CodexAccountCaptureError.invalidProfileName
        }

        var candidate = "\(base)__\(suffix)"
        var index = 2
        while true {
            let url = profileStoreURL.appendingPathComponent(candidate, isDirectory: true)
            if !fileManager.fileExists(atPath: url.path) || storedAccountID(in: url) == accountID {
                return candidate
            }
            candidate = "\(base)__\(suffix)_\(index)"
            index += 1
        }
    }

    private func sanitizedProfileName(_ raw: String) throws -> String {
        try AccountProfileNaming.sanitizedProfileName(raw)
    }

    private func storedAccountID(in profileURL: URL) -> String? {
        let authURL = profileURL.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: authURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any] else {
            return nil
        }
        return tokens["account_id"] as? String
    }

    private func ensureDirectory(_ url: URL, permissions: Int) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: permissions]
        )
        try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
    }

    private func writeJSONObject(_ object: Any, to url: URL, permissions: Int) throws {
        try AppStorage.writeJSON(object, to: url, permissions: permissions)
    }

    private func randomURLSafeString(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CodexAccountCaptureError.invalidTokenResponse
        }
        return Data(bytes).base64URLEncodedString()
    }

    private func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    private func decodeJWTPayload(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3,
              let payloadData = Data(base64URLString: String(parts[1])),
              let payload = try JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            throw CodexAccountCaptureError.invalidTokenResponse
        }
        return payload
    }
}

struct CodexLoginStatus: Equatable {
    let accountIDs: Set<String>
    let sourceProfileKeys: Set<String>
    let emailsWithoutAccountID: Set<String>

    static let empty = CodexLoginStatus(
        accountIDs: [],
        sourceProfileKeys: [],
        emailsWithoutAccountID: []
    )

    func contains(_ account: Account) -> Bool {
        if !sourceProfileKeys.isEmpty {
            guard let profileKey = account.profileKey else { return false }
            return sourceProfileKeys.contains(profileKey)
        }

        if !account.accountID.isEmpty {
            return accountIDs.contains(account.accountID)
        }

        return emailsWithoutAccountID.contains(account.email.lowercased())
    }
}

enum CodexLoginStatusStore {
    static func load() -> CodexLoginStatus {
        let root = AppStorage.profilesURL
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return .empty
        }

        var accountIDs = Set<String>()
        var sourceProfileKeys = Set<String>()
        var emailsWithoutAccountID = Set<String>()

        for entry in entries where entry.lastPathComponent != "backups" {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }

            if let auth = readJSONObject(entry.appendingPathComponent("auth.json")),
               let tokens = auth["tokens"] as? [String: Any],
               let accountID = tokens["account_id"] as? String,
               !accountID.isEmpty {
                accountIDs.insert(accountID)
            }

            if let meta = readJSONObject(entry.appendingPathComponent("meta.json")) {
                if let sourceProfileKey = meta["source_profile_key"] as? String,
                   !sourceProfileKey.isEmpty {
                    sourceProfileKeys.insert(sourceProfileKey)
                }

                if let email = meta["email"] as? String,
                   !email.isEmpty,
                   (meta["account_id"] as? String)?.isEmpty != false {
                    emailsWithoutAccountID.insert(email.lowercased())
                }
            }
        }

        return CodexLoginStatus(
            accountIDs: accountIDs,
            sourceProfileKeys: sourceProfileKeys,
            emailsWithoutAccountID: emailsWithoutAccountID
        )
    }

    private static func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

struct LocalAccountRemovalResult {
    let backupURL: URL
}

enum LocalAccountRemovalError: LocalizedError {
    case missingProfileKey
    case localProfileInvalid(URL)

    var errorDescription: String? {
        switch self {
        case .missingProfileKey:
            return "Account has no profile key to remove."
        case let .localProfileInvalid(url):
            return "Invalid account store: \(url.path)"
        }
    }
}

final class LocalAccountRemovalService: @unchecked Sendable {
    private let fileManager = FileManager.default

    private var profileStoreURL: URL {
        AppStorage.profilesURL
    }

    func remove(_ account: Account) throws -> LocalAccountRemovalResult {
        guard let profileKey = account.profileKey else {
            throw LocalAccountRemovalError.missingProfileKey
        }

        let backupURL = try makeBackupURL()
        try backupAccountStore(to: backupURL)
        let matchingProfiles = capturedProfilesMatching(account: account, profileKey: profileKey)
        try backupCapturedProfiles(matchingProfiles, to: backupURL)
        let profiles = AccountProfileStore.loadLocalProfiles()
        let removeKeys = profileKeysToRemove(from: profiles, profileKey: profileKey, account: account)
        try AccountProfileStore.remove(profileKeys: removeKeys)

        for profileURL in matchingProfiles {
            try? fileManager.removeItem(at: profileURL)
        }

        return LocalAccountRemovalResult(backupURL: backupURL)
    }

    private func profileKeysToRemove(
        from profiles: [String: [String: Any]],
        profileKey: String,
        account: Account
    ) -> Set<String> {
        var keys = Set([profileKey])
        guard !account.accountID.isEmpty else { return keys }

        for (key, value) in profiles {
            guard (value["accountId"] as? String) == account.accountID,
                  (value["email"] as? String)?.lowercased() == account.email.lowercased() else {
                continue
            }
            keys.insert(key)
        }

        return keys
    }

    private func capturedProfilesMatching(account: Account, profileKey: String) -> [URL] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: profileStoreURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.filter { entry in
            guard entry.lastPathComponent != "backups",
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return false
            }

            let meta = readJSONObject(entry.appendingPathComponent("meta.json")) ?? [:]
            if (meta["source_profile_key"] as? String) == profileKey {
                return true
            }

            guard !account.accountID.isEmpty else { return false }
            return (meta["email"] as? String)?.lowercased() == account.email.lowercased()
                && (meta["account_id"] as? String) == account.accountID
        }
    }

    private func makeBackupURL() throws -> URL {
        let timestamp = DateFormatter.codexSwitchboardBackup.string(from: Date())
        let url = AppStorage.backupsURL
            .appendingPathComponent("\(timestamp)-remove-account", isDirectory: true)
        try AppStorage.ensureDirectory(url, permissions: 0o700)
        return url
    }

    private func backupAccountStore(to backupURL: URL) throws {
        guard fileManager.fileExists(atPath: AppStorage.accountsURL.path) else { return }
        let targetRoot = backupURL.appendingPathComponent("app-store", isDirectory: true)
        try AppStorage.ensureDirectory(targetRoot, permissions: 0o700)
        try fileManager.copyItem(
            at: AppStorage.accountsURL,
            to: targetRoot.appendingPathComponent(AppStorage.accountsURL.lastPathComponent)
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: targetRoot.appendingPathComponent(AppStorage.accountsURL.lastPathComponent).path
        )
    }

    private func backupCapturedProfiles(_ profiles: [URL], to backupURL: URL) throws {
        guard !profiles.isEmpty else { return }

        let targetRoot = backupURL.appendingPathComponent("profiles", isDirectory: true)
        try AppStorage.ensureDirectory(targetRoot, permissions: 0o700)
        for profileURL in profiles {
            try fileManager.copyItem(
                at: profileURL,
                to: targetRoot.appendingPathComponent(profileURL.lastPathComponent, isDirectory: true)
            )
        }
    }

    private func removeProfileKey(in root: inout [String: Any], key: String) {
        guard var order = root["order"] as? [String: Any] else { return }
        for (group, value) in order {
            guard let keys = value as? [String] else { continue }
            order[group] = keys.filter { $0 != key }
        }
        root["order"] = order
    }

    private func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private func writeJSONObject(_ object: Any, to url: URL, permissions: Int) throws {
        try AppStorage.writeJSON(object, to: url, permissions: permissions)
    }
}

struct CodexSwitchResult {
    let profileName: String
    let sourceProfileKey: String?
}

enum CodexAccountSwitchError: LocalizedError {
    case codexAppMissing
    case capturedProfileMissing(String)
    case capturedProfileAmbiguous(String)
    case codexDidNotQuit
    case codexAuthConsumersStillRunning([String])
    case codexDatabaseStillLocked([String])

    var errorDescription: String? {
        switch self {
        case .codexAppMissing:
            return "Codex.app was not found in /Applications."
        case let .capturedProfileMissing(email):
            return "Captured auth was not found for \(email)."
        case let .capturedProfileAmbiguous(email):
            return "More than one captured auth matches \(email)."
        case .codexDidNotQuit:
            return "Codex did not quit; switch canceled."
        case let .codexAuthConsumersStillRunning(processes):
            return "Codex auth consumers are still running; switch canceled: \(processes.joined(separator: ", "))"
        case let .codexDatabaseStillLocked(processes):
            return "Codex database is still locked; switch canceled: \(processes.joined(separator: ", "))"
        }
    }
}

final class CodexAccountSwitchService: @unchecked Sendable {
    private let fileManager = FileManager.default
    private let homeURL = FileManager.default.homeDirectoryForCurrentUser
    private let appURL = URL(fileURLWithPath: "/Applications/Codex.app")
    private let codexBundleIdentifier = "com.openai.codex"
    private let authMirrorService = CodexAuthMirrorService()

    private var profileStoreURL: URL {
        AppStorage.profilesURL
    }

    private var defaultAuthURL: URL {
        homeURL.appendingPathComponent(".codex/auth.json")
    }

    private var bundledCodexURL: URL {
        appURL.appendingPathComponent("Contents/Resources/codex")
    }

    private var bundledNodeReplURL: URL {
        appURL.appendingPathComponent("Contents/Resources/node_repl")
    }

    private var defaultCodexHomePath: String {
        homeURL.appendingPathComponent(".codex", isDirectory: true).standardizedFileURL.path
    }

    var isCodexInstalled: Bool {
        fileManager.fileExists(atPath: appURL.path)
            || !NSRunningApplication.runningApplications(withBundleIdentifier: codexBundleIdentifier).isEmpty
    }

    func switchToAccount(_ account: Account) throws -> CodexSwitchResult {
        guard isCodexInstalled else {
            throw CodexAccountSwitchError.codexAppMissing
        }

        try CodexAuthFileLock.withLock {
            authMirrorService.syncActiveAuth()
            _ = try capturedProfile(for: account)
        }

        var didTerminateCodex = false
        var didLaunchCodex = false
        defer {
            if didTerminateCodex && !didLaunchCodex {
                try? launchCodex()
            }
        }

        let codexWasRunning = !runningCodexApps().isEmpty
        do {
            try terminateCodex()
            didTerminateCodex = codexWasRunning
        } catch CodexAccountSwitchError.codexDidNotQuit {
            throw CodexAccountSwitchError.codexDidNotQuit
        } catch {
            didTerminateCodex = codexWasRunning && runningCodexApps().isEmpty
            throw error
        }
        let profile = try CodexAuthFileLock.withLock {
            // Close consumers that may have appeared while Codex was shutting down
            // before replacing the live auth snapshot.
            try terminateResidualAuthConsumers()
            // Codex can rotate the active refresh token while shutting down.
            authMirrorService.syncActiveAuth()
            let profile = try capturedProfile(for: account)
            try copyReplacing(source: profile.authURL, destination: defaultAuthURL)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: defaultAuthURL.path)
            return profile
        }
        try waitForCodexSQLiteHandlesToClose()
        try launchCodex()
        didLaunchCodex = true

        return CodexSwitchResult(
            profileName: profile.name,
            sourceProfileKey: profile.sourceProfileKey
        )
    }

    func currentSourceProfileKey() -> String? {
        guard let activeAuth = StoredCodexAuth.load(from: defaultAuthURL) else { return nil }
        return capturedProfiles().first { profile in
            guard let profileAuth = StoredCodexAuth.load(from: profile.authURL) else { return false }
            return profileAuth.idToken == activeAuth.idToken
                && profileAuth.accessToken == activeAuth.accessToken
                && profileAuth.refreshToken == activeAuth.refreshToken
        }?.sourceProfileKey
    }

    private func capturedProfile(for account: Account) throws -> CapturedCodexProfile {
        let profiles = capturedProfiles()

        if let profileKey = account.profileKey {
            let matches = profiles.filter { $0.sourceProfileKey == profileKey }
            if let profile = try canonicalCapturedProfile(from: matches) {
                return profile
            }
        }

        let fallbackMatches = profiles.filter { profile in
            profile.email == account.email.lowercased()
                && !account.accountID.isEmpty
                && profile.accountID == account.accountID
        }
        if let fallbackProfile = try canonicalCapturedProfile(from: fallbackMatches) {
            return fallbackProfile
        }

        throw CodexAccountSwitchError.capturedProfileMissing(account.email)
    }

    private func canonicalCapturedProfile(from matches: [CapturedCodexProfile]) throws -> CapturedCodexProfile? {
        guard let keep = matches.max(by: { $0.freshnessDate < $1.freshnessDate }) else {
            return nil
        }
        guard matches.count > 1 else { return keep }

        let removedProfileKeys = try CapturedProfileDedupeService.removeDuplicates(
            keeping: keep.profileURL,
            email: keep.email,
            accountID: keep.accountID,
            profileStoreURL: profileStoreURL
        )
        let keysToRemove = removedProfileKeys.subtracting([keep.sourceProfileKey].compactMap { $0 })
        try AccountProfileStore.remove(profileKeys: keysToRemove)
        return keep
    }

    private func capturedProfiles() -> [CapturedCodexProfile] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: profileStoreURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry -> CapturedCodexProfile? in
            guard entry.lastPathComponent != "backups",
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return nil
            }

            let authURL = entry.appendingPathComponent("auth.json")
            guard fileManager.fileExists(atPath: authURL.path) else { return nil }

            let metaURL = entry.appendingPathComponent("meta.json")
            let meta = readJSONObject(metaURL) ?? [:]
            let auth = readJSONObject(authURL) ?? [:]
            let tokens = auth["tokens"] as? [String: Any] ?? [:]

            let email = (meta["email"] as? String)?.lowercased()
            let accountID = (meta["account_id"] as? String) ?? (tokens["account_id"] as? String)
            let freshnessDate = CapturedProfileDedupeService.record(for: entry)?.freshnessDate ?? .distantPast
            return CapturedCodexProfile(
                name: entry.lastPathComponent,
                profileURL: entry,
                authURL: authURL,
                email: email ?? "",
                accountID: accountID ?? "",
                sourceProfileKey: meta["source_profile_key"] as? String,
                freshnessDate: freshnessDate
            )
        }
    }

    private func terminateCodex() throws {
        let runningApps = runningCodexApps()
        for app in runningApps {
            app.terminate()
        }

        for _ in 0..<30 {
            if runningCodexApps().isEmpty {
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }

        if !runningCodexApps().isEmpty {
            throw CodexAccountSwitchError.codexDidNotQuit
        }

        stopAppServerDaemonBestEffort()
        try terminateResidualAuthConsumers()
    }

    private func runningCodexApps() -> [NSRunningApplication] {
        NSRunningApplication
            .runningApplications(withBundleIdentifier: codexBundleIdentifier)
            .filter { !$0.isTerminated }
    }

    private func launchCodex() throws {
        try run("/usr/bin/open", ["-n", appURL.path])
    }

    private func stopAppServerDaemonBestEffort() {
        guard fileManager.isExecutableFile(atPath: bundledCodexURL.path) else { return }
        _ = try? run(bundledCodexURL.path, ["app-server", "daemon", "stop"])
    }

    private func terminateResidualAuthConsumers() throws {
        let pids = residualAuthConsumerPIDs()
        guard !pids.isEmpty else { return }

        _ = try? run("/bin/kill", ["-TERM"] + pids.map(String.init))
        if waitForResidualAuthConsumersToExit(timeout: 5) {
            return
        }

        let stubbornPIDs = residualAuthConsumerPIDs()
        if !stubbornPIDs.isEmpty {
            _ = try? run("/bin/kill", ["-KILL"] + stubbornPIDs.map(String.init))
        }

        if !waitForResidualAuthConsumersToExit(timeout: 2) {
            throw CodexAccountSwitchError.codexAuthConsumersStillRunning(residualAuthConsumerDescriptions())
        }
    }

    private func waitForResidualAuthConsumersToExit(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if residualAuthConsumerPIDs().isEmpty {
                return true
            }
            Thread.sleep(forTimeInterval: 0.1)
        } while Date() < deadline

        return residualAuthConsumerPIDs().isEmpty
    }

    private func waitForCodexSQLiteHandlesToClose(timeout: TimeInterval = 8) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastProcesses: [String] = []

        repeat {
            lastProcesses = codexSQLiteLockingProcesses()
            if lastProcesses.isEmpty {
                Thread.sleep(forTimeInterval: 0.25)
                if codexSQLiteLockingProcesses().isEmpty {
                    return
                }
            }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline

        throw CodexAccountSwitchError.codexDatabaseStillLocked(lastProcesses)
    }

    private func codexSQLiteLockingProcesses() -> [String] {
        let paths = codexSQLiteStateFiles()
        guard !paths.isEmpty else { return [] }

        let output = runBestEffort("/usr/sbin/lsof", ["-nP"] + paths.map(\.path))
        return output
            .split(separator: "\n")
            .dropFirst()
            .compactMap { line -> String? in
                let text = String(line)
                guard isCodexSQLiteHandle(text) else { return nil }
                return text
            }
    }

    private func isCodexSQLiteHandle(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        guard lowercased.contains(".codex/"),
              lowercased.contains(".sqlite") else {
            return false
        }
        return lowercased.hasPrefix("codex")
            || lowercased.hasPrefix("node_repl")
    }

    private func codexSQLiteStateFiles() -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: homeURL.appendingPathComponent(".codex", isDirectory: true),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                return nil
            }
            let name = url.lastPathComponent
            guard name.hasSuffix(".sqlite")
                    || name.hasSuffix(".sqlite-wal")
                    || name.hasSuffix(".sqlite-shm") else {
                return nil
            }
            return url
        }
    }

    private func residualAuthConsumerPIDs() -> [Int32] {
        residualAuthConsumers().map(\.pid)
    }

    private func residualAuthConsumerDescriptions() -> [String] {
        residualAuthConsumers().map { "\($0.pid) \($0.command)" }
    }

    private func residualAuthConsumers() -> [(pid: Int32, command: String)] {
        let output = runBestEffort("/bin/ps", ["eww", "-axo", "pid=,command="])
        return output.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }),
                  let pid = Int32(trimmed[..<space]) else {
                return nil
            }

            let command = trimmed[space...].trimmingCharacters(in: .whitespaces)
            guard isDefaultCodexHomeAuthConsumer(command) else { return nil }
            return (pid, command)
        }
    }

    private func isDefaultCodexHomeAuthConsumer(_ command: String) -> Bool {
        if isBundledAuthConsumer(command) {
            return true
        }

        guard isCodexAuthConsumer(command) else {
            return false
        }

        guard let codexHome = environmentValue("CODEX_HOME", in: command) else {
            return true
        }
        return URL(fileURLWithPath: codexHome).standardizedFileURL.path == defaultCodexHomePath
    }

    private func isBundledAuthConsumer(_ command: String) -> Bool {
        let codexPath = bundledCodexURL.path
        let nodeReplPath = bundledNodeReplURL.path
        return command == codexPath
            || command.hasPrefix("\(codexPath) ")
            || command == nodeReplPath
            || command.hasPrefix("\(nodeReplPath) ")
    }

    private func isCodexAuthConsumer(_ command: String) -> Bool {
        let lowercased = command.lowercased()
        if lowercased == "codex"
            || lowercased.hasPrefix("codex app-server ") {
            return true
        }
        if lowercased.hasPrefix("node "),
           lowercased.contains("/codex "),
           lowercased.contains(" app-server ") {
            return true
        }

        return lowercased.hasPrefix("/")
            && (
                lowercased.contains("/codex app-server ")
                    || lowercased.contains("/node_repl ")
                    || lowercased.hasSuffix("/node_repl")
            )
    }

    private func environmentValue(_ name: String, in command: String) -> String? {
        let marker = "\(name)="
        for token in command.split(separator: " ") {
            guard token.hasPrefix(marker) else { continue }
            let value = token.dropFirst(marker.count).trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func copyReplacing(source: URL, destination: URL) throws {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tempURL = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        try fileManager.copyItem(at: source, to: tempURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempURL.path)
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: tempURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: tempURL, to: destination)
        }
    }

    private func readJSONObject(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 10) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchboard-\(UUID().uuidString).log")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = FileHandle(forWritingAtPath: outputURL.path) else {
            throw NSError(
                domain: "CodexSwitchboard.CodexAccountSwitchService",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create temporary command output file."]
            )
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        defer {
            try? outputHandle.close()
            try? fileManager.removeItem(at: outputURL)
        }

        process.standardOutput = outputHandle
        process.standardError = outputHandle
        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.25)
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            throw NSError(
                domain: "CodexSwitchboard.CodexAccountSwitchService",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Command timed out: \(launchPath) \(arguments.joined(separator: " "))"]
            )
        }

        process.waitUntilExit()
        try outputHandle.synchronize()
        let data = (try? Data(contentsOf: outputURL)) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "CodexSwitchboard.CodexAccountSwitchService",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.trimmingCharacters(in: .whitespacesAndNewlines)]
            )
        }
        return output
    }

    private func runBestEffort(_ launchPath: String, _ arguments: [String]) -> String {
        (try? run(launchPath, arguments)) ?? ""
    }
}

private struct CapturedCodexProfile {
    let name: String
    let profileURL: URL
    let authURL: URL
    let email: String
    let accountID: String
    let sourceProfileKey: String?
    let freshnessDate: Date
}

private struct OAuthTokenResponse: Decodable {
    let accessToken: String
    let refreshToken: String
    let idToken: String
    let expiresAt: Double

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case idToken = "id_token"
        case expiresIn = "expires_in"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decode(String.self, forKey: .refreshToken)
        idToken = try container.decode(String.self, forKey: .idToken)
        let expiresIn = try container.decode(Double.self, forKey: .expiresIn)
        expiresAt = Date().timeIntervalSince1970 * 1000 + expiresIn * 1000
    }
}

private struct CapturedIdentity {
    let email: String
    let accountID: String
}

private enum OAuthCallbackResult {
    case code(String)
    case failure(String)
}

private final class OAuthCallbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let state: String
    private let queue = DispatchQueue(label: "CodexSwitchboard.OAuthCallback")
    private let lock = NSLock()
    private var capturedResult: OAuthCallbackResult?
    private var continuation: CheckedContinuation<OAuthCallbackResult?, Never>?

    init(state: String) throws {
        guard let port = NWEndpoint.Port(rawValue: 1455) else {
            throw CodexAccountCaptureError.callbackServerUnavailable
        }
        self.state = state
        listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
    }

    func waitForResult(timeout: TimeInterval) async -> OAuthCallbackResult? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let capturedResult {
                lock.unlock()
                continuation.resume(returning: capturedResult)
                return
            }
            self.continuation = continuation
            lock.unlock()

            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self?.finish(with: nil)
            }
        }
    }

    func close() {
        listener.cancel()
        finish(with: nil)
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveRequest(on: connection, buffer: Data())
        queue.asyncAfter(deadline: .now() + 8) { [weak connection] in
            connection?.cancel()
        }
    }

    private func receiveRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else {
                self.respond(connection, status: 400, body: "Bad request")
                return
            }

            var nextBuffer = buffer
            if let data, !data.isEmpty {
                nextBuffer.append(data)
            }

            if let headerEnd = nextBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = nextBuffer[..<headerEnd.lowerBound]
                guard let request = String(data: headerData, encoding: .utf8) else {
                    self.respond(connection, status: 400, body: "Bad request")
                    return
                }
                self.handleRequest(request, connection: connection)
                return
            }

            guard !isComplete, nextBuffer.count < 64 * 1024 else {
                self.respond(connection, status: 400, body: "Bad request")
                return
            }

            self.receiveRequest(on: connection, buffer: nextBuffer)
        }
    }

    private func handleRequest(_ request: String, connection: NWConnection) {
        guard let firstLine = request.components(separatedBy: "\r\n").first else {
            respond(connection, status: 400, body: "Bad request")
            return
        }

        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2,
              let components = URLComponents(string: "http://localhost:1455\(parts[1])"),
              components.path == "/auth/callback" else {
            respond(connection, status: 404, body: "Not found")
            return
        }

        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard query["state"] == state else {
            respond(connection, status: 400, body: "State mismatch")
            finish(with: .failure("state mismatch"))
            return
        }
        if let error = query["error"], !error.isEmpty {
            respond(connection, status: 400, body: "OAuth error")
            finish(with: .failure(error))
            return
        }
        guard let code = query["code"], !code.isEmpty else {
            respond(connection, status: 400, body: "Missing code")
            finish(with: .failure("missing code"))
            return
        }

        respond(connection, status: 200, body: successHTML)
        finish(with: .code(code))
    }

    private func respond(_ connection: NWConnection, status: Int, body: String) {
        let reason = status == 200 ? "OK" : "Error"
        let bodyData = Data(body.utf8)
        var response = "HTTP/1.1 \(status) \(reason)\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Connection: close\r\n"
        response += "X-Frame-Options: DENY\r\n"
        response += "X-Content-Type-Options: nosniff\r\n"
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(bodyData)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
        queue.asyncAfter(deadline: .now() + 1) {
            connection.cancel()
        }
    }

    private func finish(with result: OAuthCallbackResult?) {
        lock.lock()
        if let result, capturedResult == nil {
            capturedResult = result
        }
        let finalResult = capturedResult
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: finalResult)
    }

    private var successHTML: String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>Codex login captured</title></head>
        <body>Codex login captured. You can close this tab.</body>
        </html>
        """
    }
}

private struct URLSearchParams {
    private let pairs: [(String, String)]

    init(_ pairs: [(String, String)]) {
        self.pairs = pairs
    }

    func data(using encoding: String.Encoding) -> Data? {
        pairs
            .map { key, value in
                "\(key.urlFormEncoded)=\(value.urlFormEncoded)"
            }
            .joined(separator: "&")
            .data(using: encoding)
    }
}

private extension String {
    var isLegacyProfileScope: Bool {
        hasPrefix("backup")
            || hasPrefix("old")
            || hasPrefix("temp")
            || self == "profiles"
            || self == "default"
            || range(of: #"^[a-f0-9]{6}$"#, options: .regularExpression) != nil
    }

    var urlFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .codexSwitchboardFormAllowed) ?? self
    }
}

private extension CharacterSet {
    static let codexSwitchboardFormAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return set
    }()
}

private extension Data {
    init?(base64URLString: String) {
        var normalized = base64URLString
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - normalized.count % 4) % 4
        normalized += String(repeating: "=", count: padding)
        self.init(base64Encoded: normalized)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension ISO8601DateFormatter {
    static var codexSwitchboard: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
}

extension DateFormatter {
    static var codexSwitchboardBackup: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }
}
