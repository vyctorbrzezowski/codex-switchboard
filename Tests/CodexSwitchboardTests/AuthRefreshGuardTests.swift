import XCTest

final class AuthRefreshGuardTests: XCTestCase {
    func testSwitchboardNeverUsesRefreshTokenGrant() throws {
        let files = try productionTextFiles()

        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let compact = text
                .lowercased()
                .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)

            for snippet in forbiddenRefreshGrantSnippets {
                XCTAssertFalse(compact.contains(snippet), "\(file.path) must not spend refresh tokens")
            }

            for identifier in forbiddenRefreshGrantIdentifiers {
                XCTAssertFalse(text.contains(identifier), "\(file.path) must not define refresh-token grant flow")
            }

            for line in text.components(separatedBy: .newlines)
            where line.contains("grant_type") {
                XCTAssertTrue(
                    line.contains("authorization_code"),
                    "\(file.path) uses a non-login OAuth grant: \(line)"
                )
            }
        }
    }

    func testSwitchPersistsFinalAuthRotationAfterCodexStops() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexAccountCaptureService.swift")
        let text = try String(contentsOf: serviceURL, encoding: .utf8)

        guard let terminateRange = text.range(of: "try terminateCodex()"),
              let copyRange = text.range(
                of: "try copyReplacing(source: profile.authURL, destination: defaultAuthURL)",
                range: terminateRange.upperBound..<text.endIndex
              ) else {
            return XCTFail("Could not locate the Codex auth handoff")
        }

        let shutdownHandoff = text[terminateRange.upperBound..<copyRange.lowerBound]
        XCTAssertTrue(
            shutdownHandoff.contains("try terminateResidualAuthConsumers()"),
            "Switching accounts must close auth consumers again immediately before replacing live auth"
        )
        XCTAssertTrue(
            shutdownHandoff.contains("authMirrorService.syncActiveAuth()"),
            "Switching accounts must persist any refresh-token rotation produced during Codex shutdown"
        )
    }

    func testSwitchWaitsForCodexSQLiteLocksBeforeRelaunching() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexAccountCaptureService.swift")
        let text = try String(contentsOf: serviceURL, encoding: .utf8)

        guard let copyRange = text.range(of: "try copyReplacing(source: profile.authURL, destination: defaultAuthURL)"),
              let launchRange = text.range(of: "try launchCodex()", range: copyRange.upperBound..<text.endIndex) else {
            return XCTFail("Could not locate the Codex launch handoff")
        }

        let launchHandoff = text[copyRange.upperBound..<launchRange.lowerBound]
        XCTAssertTrue(
            launchHandoff.contains("try waitForCodexSQLiteHandlesToClose()"),
            "Switching accounts must wait for native Codex SQLite handles to close before relaunch"
        )
    }

    func testSwitchTerminatesDefaultCodexHomeAuthConsumers() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexAccountCaptureService.swift")
        let text = try String(contentsOf: serviceURL, encoding: .utf8)

        XCTAssertTrue(
            text.contains(#"runBestEffort("/bin/ps", ["eww", "-axo", "pid=,command="])"#),
            "Residual auth consumer detection must include process environments so CODEX_HOME can be inspected"
        )

        guard let detectorRange = text.range(of: "private func isDefaultCodexHomeAuthConsumer") else {
            return XCTFail("Could not locate default CODEX_HOME auth-consumer detector")
        }
        let detectorBody = text[detectorRange.lowerBound...].prefix(700)
        XCTAssertTrue(
            detectorBody.contains(#"environmentValue("CODEX_HOME", in: command)"#),
            "Residual auth consumer detection must inspect CODEX_HOME to avoid killing isolated Codex homes"
        )
        XCTAssertTrue(
            detectorBody.contains("return true"),
            "Codex auth consumers without CODEX_HOME must be treated as default ~/.codex consumers"
        )
        XCTAssertTrue(
            detectorBody.contains("standardizedFileURL.path == defaultCodexHomePath"),
            "Only explicit CODEX_HOME processes pointing at the default ~/.codex should be terminated"
        )

        guard let consumerRange = text.range(of: "private func isCodexAuthConsumer"),
              let envRange = text.range(
                of: "private func environmentValue",
                range: consumerRange.upperBound..<text.endIndex
              ) else {
            return XCTFail("Could not locate Codex auth-consumer matcher")
        }

        let consumerMatcher = text[consumerRange.lowerBound..<envRange.lowerBound]
        XCTAssertTrue(consumerMatcher.contains(#"hasPrefix("codex app-server ")"#))
        XCTAssertTrue(consumerMatcher.contains(#"contains("/codex app-server ")"#))
        XCTAssertTrue(consumerMatcher.contains(#"contains("/node_repl ")"#))
    }

    func testSwitchboardPersistsLatestAuthBeforeNormalTermination() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let mainURL = root.appendingPathComponent("Sources/CodexSwitchboard/main.swift")
        let text = try String(contentsOf: mainURL, encoding: .utf8)

        guard let terminationRange = text.range(of: "func applicationWillTerminate"),
              let stopRange = text.range(
                of: "authMirrorService.stop()",
                range: terminationRange.upperBound..<text.endIndex
              ) else {
            return XCTFail("Could not locate the Switchboard termination handoff")
        }

        let terminationHandoff = text[terminationRange.upperBound..<stopRange.lowerBound]
        XCTAssertTrue(
            terminationHandoff.contains("authMirrorService.syncActiveAuth()"),
            "Normal app termination must persist the latest native Codex auth before stopping the mirror"
        )
    }

    func testLoginCaptureRejectsStaleOAuthResponsesBeforePersisting() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexAccountCaptureService.swift")
        let text = try String(contentsOf: serviceURL, encoding: .utf8)

        try assertStaleLoginValidation(in: text, functionName: "captureNewAccount")
        try assertStaleLoginValidation(in: text, functionName: "captureAccount(for target: Account)")
    }

    func testLoginCaptureHoldsAuthFileLockWhilePersisting() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexAccountCaptureService.swift")
        let text = try String(contentsOf: serviceURL, encoding: .utf8)

        try assertCaptureUsesAuthFileLock(in: text, functionName: "captureNewAccount")
        try assertCaptureUsesAuthFileLock(in: text, functionName: "captureAccount(for target: Account)")
    }

    func testAccountProfileStoreMethodsHoldAuthFileLock() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let storageURL = root.appendingPathComponent("Sources/CodexSwitchboard/AppStorage.swift")
        let text = try String(contentsOf: storageURL, encoding: .utf8)

        for method in ["func upsert(", "func updateTokens(", "func remove(profileKeys:"] {
            guard let methodRange = text.range(of: method) else {
                XCTFail("Could not locate \(method) in AppStorage.swift")
                continue
            }
            let trailing = text[methodRange.upperBound...]
            let functionBody = trailing.prefix(500)
            XCTAssertTrue(
                functionBody.contains("CodexAuthFileLock.withLock"),
                "\(method) must hold CodexAuthFileLock to prevent concurrent read-modify-write races on accounts.json"
            )
        }
    }

    func testCapturedProfileDedupeDoesNotIgnoreDeleteFailures() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let dedupeURL = root.appendingPathComponent("Sources/CodexSwitchboard/CapturedProfileDedupeService.swift")
        let text = try String(contentsOf: dedupeURL, encoding: .utf8)

        XCTAssertFalse(
            text.contains("try? FileManager.default.removeItem(at: duplicate.profileURL)"),
            "Dedupe must not remove account references when deleting the duplicate profile directory failed"
        )
        XCTAssertTrue(
            text.contains("try FileManager.default.removeItem(at: duplicate.profileURL)"),
            "Dedupe must surface failed duplicate-profile deletion"
        )
        XCTAssertTrue(
            text.contains("makeBackupURL(profileStoreURL: profileStoreURL)"),
            "Dedupe backups must follow the injected profile store instead of writing test/custom backups to the live app store"
        )
    }

    private var forbiddenRefreshGrantSnippets: [String] {
        [
            #""grant_type","refresh_token""#,
            #""grant_type":"refresh_token""#,
            #"grant_type=refresh_token"#,
            #"grant_type%3drefresh_token"#,
            #"grant_type\",value:\"refresh_token"#,
        ]
    }

    private var forbiddenRefreshGrantIdentifiers: [String] {
        [
            "refreshAccessToken",
            "refreshTokens",
            "RefreshedTokenResponse",
            "automaticTokenRefreshEnabled",
            "tokenRefreshFailedUsage",
        ]
    }

    private func productionTextFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let directories = [
            root.appendingPathComponent("Sources", isDirectory: true),
            root.appendingPathComponent("scripts", isDirectory: true),
        ]
        let roots = directories + [
            root.appendingPathComponent("build-app.sh"),
            root.appendingPathComponent("build-pkg.sh"),
        ]
        var files: [URL] = []

        for url in roots {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                files += FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey]
                )?.compactMap { item -> URL? in
                    guard let url = item as? URL,
                          Self.productionExtensions.contains(url.pathExtension),
                          (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                        return nil
                    }
                    return url
                } ?? []
            } else if FileManager.default.fileExists(atPath: url.path) {
                files.append(url)
            }
        }

        return files
    }

    private static let productionExtensions: Set<String> = ["swift", "mjs", "js", "sh"]

    private func assertStaleLoginValidation(in text: String, functionName: String) throws {
        guard let functionRange = text.range(of: "func \(functionName)") else {
            return XCTFail("Could not locate \(functionName)")
        }
        guard let tokenExchangeRange = text.range(
            of: "let tokenResponse = try await exchangeCode",
            range: functionRange.upperBound..<text.endIndex
        ), let validationRange = text.range(
            of: "try validateFreshLoginToken(tokenResponse, startedAt: loginStartedAt)",
            range: tokenExchangeRange.upperBound..<text.endIndex
        ), let persistRange = text.range(
            of: "try writeCapturedAuth",
            range: validationRange.upperBound..<text.endIndex
        ) else {
            return XCTFail("Could not locate login-token validation handoff in \(functionName)")
        }

        XCTAssertLessThan(tokenExchangeRange.lowerBound, validationRange.lowerBound)
        XCTAssertLessThan(validationRange.lowerBound, persistRange.lowerBound)
    }

    private func assertCaptureUsesAuthFileLock(in text: String, functionName: String) throws {
        guard let functionRange = text.range(of: "func \(functionName)") else {
            return XCTFail("Could not locate \(functionName)")
        }
        guard let writeRange = text.range(
            of: "try writeCapturedAuth",
            range: functionRange.upperBound..<text.endIndex
        ) else {
            return XCTFail("Could not locate writeCapturedAuth in \(functionName)")
        }
        // Look backwards from writeCapturedAuth for the lock wrapper
        let preamble = text[functionRange.upperBound..<writeRange.lowerBound]
        XCTAssertTrue(
            preamble.contains("CodexAuthFileLock.withLock"),
            "\(functionName) must hold CodexAuthFileLock while persisting captured auth"
        )
    }
}
