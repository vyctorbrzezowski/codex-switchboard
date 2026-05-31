import XCTest
@testable import CodexSwitchboard

final class CodexAuthMirrorServiceTests: XCTestCase {
    func testSyncCopiesLiveAuthIntoMatchingCapturedProfile() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        let profileURL = profilesURL.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)

        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "old-refresh",
            to: profileURL.appendingPathComponent("auth.json")
        )
        try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "fresh-refresh",
            to: liveAuthURL
        )

        let result = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 30
        ).syncActiveAuth()

        XCTAssertEqual(result.status, .synced)
        XCTAssertEqual(refreshToken(in: profileURL.appendingPathComponent("auth.json")), "fresh-refresh")
    }

    func testSyncPrunesDuplicateProfilesForSameIdentity() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        for name in ["one", "two"] {
            let profileURL = profilesURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
            try writeAuth(
                subject: "sub-1",
                email: "person@example.com",
                refreshToken: "\(name)-refresh",
                to: profileURL.appendingPathComponent("auth.json")
            )
            try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))
        }
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "fresh-refresh",
            to: liveAuthURL
        )

        let result = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 30
        ).syncActiveAuth()

        XCTAssertEqual(result.status, .synced)
        XCTAssertEqual(result.reason, "deduped matching profiles")
        let remainingProfiles = try FileManager.default.contentsOfDirectory(
            at: profilesURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        XCTAssertEqual(remainingProfiles.count, 1)
        XCTAssertEqual(refreshToken(in: remainingProfiles[0].appendingPathComponent("auth.json")), "fresh-refresh")
        let backupRoot = root.appendingPathComponent("backups", isDirectory: true)
        let backupDirs = try FileManager.default.contentsOfDirectory(
            at: backupRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ).filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        XCTAssertEqual(backupDirs.count, 1)
    }

    func testStartRetriesUnchangedLiveAuthAfterMatchingProfileAppears() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: profilesURL, withIntermediateDirectories: true)
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "fresh-refresh",
            to: liveAuthURL
        )

        let service = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 0.05
        )
        service.start()
        defer { service.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        let profileURL = profilesURL.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "old-refresh",
            to: profileURL.appendingPathComponent("auth.json")
        )
        try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))

        XCTAssertTrue(
            waitForRefreshToken("fresh-refresh", in: profileURL.appendingPathComponent("auth.json")),
            "The mirror must retry a live auth version that could not be persisted previously"
        )
    }

    func testStartMirrorsLiveAuthChangeWithoutWaitingForPollingFallback() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        let profileURL = profilesURL.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)

        for url in [liveAuthURL, profileURL.appendingPathComponent("auth.json")] {
            try writeAuth(
                subject: "sub-1",
                email: "person@example.com",
                refreshToken: "old-refresh",
                to: url
            )
        }
        try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))

        let service = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 30
        )
        service.start()
        defer { service.stop() }
        Thread.sleep(forTimeInterval: 0.1)

        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "fresh-refresh",
            to: liveAuthURL
        )

        XCTAssertTrue(
            waitForRefreshToken("fresh-refresh", in: profileURL.appendingPathComponent("auth.json")),
            "The file-system observer must mirror rotations immediately"
        )
    }

    func testSyncPreservesNativeLastRefreshTimestamp() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        let profileURL = profilesURL.appendingPathComponent("personal", isDirectory: true)
        let profileAuthURL = profileURL.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "old-refresh",
            lastRefresh: "2026-05-29T00:00:00Z",
            to: profileAuthURL
        )
        try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "fresh-refresh",
            lastRefresh: "2026-05-30T12:34:56Z",
            to: liveAuthURL
        )

        _ = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 30
        ).syncActiveAuth()

        XCTAssertEqual(
            AppStorage.readJSON(profileAuthURL)?["last_refresh"] as? String,
            "2026-05-30T12:34:56Z"
        )
    }

    func testSyncDoesNotOverwriteNewerCapturedProfileWithOlderLiveAuth() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        let profileURL = profilesURL.appendingPathComponent("personal", isDirectory: true)
        let profileAuthURL = profileURL.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "fresh-captured",
            lastRefresh: "2026-05-31T15:37:36.542Z",
            to: profileAuthURL
        )
        try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "old-live",
            lastRefresh: "2026-05-30T18:00:23.655Z",
            to: liveAuthURL
        )

        let result = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 30
        ).syncActiveAuth()

        XCTAssertEqual(result.status, .skipped)
        XCTAssertEqual(result.reason, "live auth is older than matching profile")
        XCTAssertEqual(refreshToken(in: profileAuthURL), "fresh-captured")
    }

    func testLiveAuthWithoutTokenAccountIDUsesIDTokenAccountID() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        let profileURL = profilesURL.appendingPathComponent("personal", isDirectory: true)
        try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            accountID: "account-1",
            refreshToken: "old-refresh",
            to: profileURL.appendingPathComponent("auth.json")
        )
        try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            accountID: "account-1",
            refreshToken: "fresh-refresh",
            includeTokenAccountID: false,
            to: liveAuthURL
        )

        let result = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 30
        ).syncActiveAuth()

        XCTAssertEqual(result.status, .synced)
        XCTAssertEqual(refreshToken(in: profileURL.appendingPathComponent("auth.json")), "fresh-refresh")
    }

    func testLiveAuthWithoutAccountIDDoesNotMirrorAmbiguousSameSubjectProfiles() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        for (name, accountID) in [("one", "account-1"), ("two", "account-2")] {
            let profileURL = profilesURL.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
            try writeAuth(
                subject: "sub-1",
                email: "person@example.com",
                accountID: accountID,
                refreshToken: "\(name)-refresh",
                to: profileURL.appendingPathComponent("auth.json")
            )
            try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))
        }
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            accountID: nil,
            refreshToken: "live-refresh",
            includeTokenAccountID: false,
            includeIDTokenAccountID: false,
            to: liveAuthURL
        )

        let result = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 30
        ).syncActiveAuth()

        XCTAssertEqual(result.status, .skipped)
        XCTAssertEqual(result.reason, "ambiguous live auth account")
        XCTAssertEqual(refreshToken(in: profilesURL.appendingPathComponent("one/auth.json")), "one-refresh")
        XCTAssertEqual(refreshToken(in: profilesURL.appendingPathComponent("two/auth.json")), "two-refresh")
    }

    func testOlderLiveAuthSkipsAllDuplicateProfilesWhenAnyProfileIsNewer() throws {
        let root = try temporaryDirectory()
        let liveAuthURL = root.appendingPathComponent("auth.json")
        let profilesURL = root.appendingPathComponent("profiles", isDirectory: true)
        let freshProfileURL = profilesURL.appendingPathComponent("fresh", isDirectory: true)
        let oldProfileURL = profilesURL.appendingPathComponent("old", isDirectory: true)
        for profileURL in [freshProfileURL, oldProfileURL] {
            try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
            try AppStorage.writeJSON([:], to: profileURL.appendingPathComponent("meta.json"))
        }
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "fresh-captured",
            lastRefresh: "2026-05-31T15:37:36.542Z",
            to: freshProfileURL.appendingPathComponent("auth.json")
        )
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "old-profile",
            lastRefresh: "2026-05-30T17:00:00.000Z",
            to: oldProfileURL.appendingPathComponent("auth.json")
        )
        try writeAuth(
            subject: "sub-1",
            email: "person@example.com",
            refreshToken: "old-live",
            lastRefresh: "2026-05-30T18:00:23.655Z",
            to: liveAuthURL
        )

        let result = CodexAuthMirrorService(
            authURL: liveAuthURL,
            profileStoreURL: profilesURL,
            interval: 30
        ).syncActiveAuth()

        XCTAssertEqual(result.status, .skipped)
        XCTAssertEqual(refreshToken(in: freshProfileURL.appendingPathComponent("auth.json")), "fresh-captured")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldProfileURL.path))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func writeAuth(
        subject: String,
        email: String,
        accountID: String? = nil,
        refreshToken: String,
        lastRefresh: String = "2026-05-29T00:00:00Z",
        includeTokenAccountID: Bool = true,
        includeIDTokenAccountID: Bool = true,
        to url: URL
    ) throws {
        var tokens: [String: Any] = [
            "access_token": "access-\(refreshToken)",
            "id_token": idToken(
                subject: subject,
                email: email,
                accountID: accountID,
                includeIDTokenAccountID: includeIDTokenAccountID
            ),
            "refresh_token": refreshToken,
        ]
        if includeTokenAccountID {
            tokens["account_id"] = accountID ?? subject
        }
        try AppStorage.writeJSON(
            [
                "auth_mode": "chatgpt",
                "last_refresh": lastRefresh,
                "tokens": tokens,
            ],
            to: url
        )
    }

    private func refreshToken(in url: URL) -> String? {
        let auth = AppStorage.readJSON(url)
        let tokens = auth?["tokens"] as? [String: Any]
        return tokens?["refresh_token"] as? String
    }

    private func waitForRefreshToken(_ expected: String, in url: URL) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        repeat {
            if refreshToken(in: url) == expected {
                return true
            }
            Thread.sleep(forTimeInterval: 0.02)
        } while Date() < deadline
        return false
    }

    private func idToken(
        subject: String,
        email: String,
        accountID: String? = nil,
        includeIDTokenAccountID: Bool = true
    ) -> String {
        let header = base64URL(["alg": "none"])
        var payload: [String: Any] = [
            "email": email,
            "exp": 1_800_000_000,
            "sub": subject,
        ]
        if includeIDTokenAccountID, let accountID {
            payload["https://api.openai.com/auth"] = ["chatgpt_account_id": accountID]
        }
        return "\(header).\(base64URL(payload)).sig"
    }

    private func base64URL(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
