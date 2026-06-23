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

    func testTokenRefreshServiceDoesNotExist() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexTokenRefreshService.swift")

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: serviceURL.path),
            "Switchboard must not include a service that spends/rotates refresh tokens"
        )
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
            shutdownHandoff.contains("terminateAllCodexProcesses()"),
            "Switching accounts must close all Codex processes again immediately before replacing live auth"
        )
        XCTAssertTrue(
            shutdownHandoff.contains("authMirrorService.syncActiveAuth()"),
            "Switching accounts must persist any refresh-token rotation produced during Codex shutdown"
        )
    }

    func testSwitchValidatesDestinationIdentityBeforeStoppingCurrentCodex() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexAccountCaptureService.swift")
        let text = try String(contentsOf: serviceURL, encoding: .utf8)

        guard let switchRange = text.range(of: "func switchToAccount"),
              let terminateRange = text.range(
                of: "try terminateCodex()",
                range: switchRange.upperBound..<text.endIndex
              ) else {
            return XCTFail("Could not locate switch preflight")
        }

        let beforeTerminate = text[switchRange.upperBound..<terminateRange.lowerBound]
        XCTAssertTrue(
            beforeTerminate.contains("try validateCapturedProfileIdentity(profile, for: account)"),
            "Switch must validate the destination profile identity before stopping the current Codex"
        )
        XCTAssertFalse(
            beforeTerminate.contains("refreshStoredProfile"),
            "Switch must not spend/rotate a refresh token before stopping Codex"
        )
    }

    func testSwitchCopiesOnlyAfterIdentityValidationAndLiveBackup() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexAccountCaptureService.swift")
        let text = try String(contentsOf: serviceURL, encoding: .utf8)

        guard let switchRange = text.range(of: "func switchToAccount"),
              let sourceRange = text.range(
                of: "try copyReplacing(source: profile.authURL, destination: defaultAuthURL)",
                range: switchRange.upperBound..<text.endIndex
              ) else {
            return XCTFail("Could not locate switch copy")
        }

        let beforeCopy = text[switchRange.upperBound..<sourceRange.lowerBound]
        XCTAssertFalse(
            beforeCopy.contains("refreshStoredProfile"),
            "Switch must not spend/rotate a refresh token before copying to live Codex auth"
        )
        XCTAssertTrue(
            beforeCopy.contains("try backupLiveAuthBeforeSwitch(to: profile)"),
            "Switch must backup the current live Codex auth before replacing it"
        )
        XCTAssertTrue(
            beforeCopy.contains("try validateCapturedProfileIdentity(profile, for: account)"),
            "Switch must re-check destination profile identity immediately before copying it"
        )
    }

    func testSwitchCreatesRecoverableLiveAuthBackupBeforeReplacement() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexAccountCaptureService.swift")
        let text = try String(contentsOf: serviceURL, encoding: .utf8)

        guard let backupRange = text.range(of: "private func backupLiveAuthBeforeSwitch"),
              let readRange = text.range(
                of: "private func readJSONObject",
                range: backupRange.upperBound..<text.endIndex
              ) else {
            return XCTFail("Could not locate live-auth backup function")
        }

        let backupBody = text[backupRange.lowerBound..<readRange.lowerBound]
        XCTAssertTrue(
            backupBody.contains("defaultAuthURL"),
            "Live-auth backup must copy the active ~/.codex/auth.json"
        )
        XCTAssertTrue(
            backupBody.contains(#""live-auth-before-switch""#),
            "Live-auth backup must use a clear recovery directory name"
        )
        XCTAssertTrue(
            backupBody.contains(#"appendingPathComponent("auth.json")"#),
            "Live-auth backup must preserve a directly restorable auth.json"
        )
        XCTAssertTrue(
            backupBody.contains(#"appendingPathComponent("metadata.json")"#),
            "Live-auth backup must include target metadata for recovery"
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

        guard let waitRange = text.range(of: "private func waitForCodexSQLiteHandlesToClose"),
              let lockerRange = text.range(
                of: "private func codexSQLiteLockingProcesses",
                range: waitRange.upperBound..<text.endIndex
              ) else {
            return XCTFail("Could not locate SQLite lock waiter")
        }
        let waitBody = text[waitRange.lowerBound..<lockerRange.lowerBound]
        XCTAssertTrue(
            waitBody.contains("terminateAllCodexProcesses()"),
            "SQLite wait must actively terminate new Codex processes instead of only timing out"
        )
    }

    func testSwitchTerminatesAllCodexProcesses() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let serviceURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexAccountCaptureService.swift")
        let text = try String(contentsOf: serviceURL, encoding: .utf8)

        // ps must NOT use `eww` flag (which leaks env vars into command column and causes false matches)
        XCTAssertTrue(
            text.contains(#"runBestEffort("/bin/ps", ["-axo", "pid=,command="])"#),
            "Codex process detection must use plain ps without eww to avoid false env-var matches"
        )
        XCTAssertFalse(
            text.contains(#""eww""#),
            "ps must not use eww flag — it causes false matches on env vars like CODEX_CI"
        )

        guard let terminateCodexRange = text.range(of: "private func terminateCodex"),
              let runningAppsRange = text.range(
                of: "private func runningCodexApps",
                range: terminateCodexRange.upperBound..<text.endIndex
              ) else {
            return XCTFail("Could not locate Codex shutdown function")
        }
        let terminateCodexBody = text[terminateCodexRange.lowerBound..<runningAppsRange.lowerBound]
        XCTAssertTrue(
            terminateCodexBody.contains("terminateAllCodexProcesses()"),
            "Codex.app graceful shutdown failure must fall back to aggressive process termination"
        )
        // Layer 3: Verify auth is synced during shutdown
        XCTAssertTrue(
            terminateCodexBody.contains("authMirrorService.syncActiveAuth()"),
            "terminateCodex must sync auth between SIGTERM and SIGKILL to capture final token rotation"
        )

        guard let terminatorRange = text.range(of: "private func terminateAllCodexProcesses") else {
            return XCTFail("Could not locate all-Codex terminator")
        }
        let terminatorBody = text[terminatorRange.lowerBound...].prefix(900)
        XCTAssertTrue(
            terminatorBody.contains(#"run("/bin/kill", ["-TERM"]"#),
            "Switching accounts must first terminate Codex processes cleanly"
        )
        XCTAssertTrue(
            terminatorBody.contains(#"run("/bin/kill", ["-KILL"]"#),
            "Switching accounts must force-kill stubborn Codex processes"
        )

        guard let processRange = text.range(of: "private func isCodexProcess"),
              let consumerRange = text.range(
                of: "private func isCodexAuthConsumer",
                range: processRange.upperBound..<text.endIndex
              ) else {
            return XCTFail("Could not locate Codex process matcher")
        }
        let processMatcher = text[processRange.lowerBound..<consumerRange.lowerBound]
        XCTAssertTrue(
            processMatcher.contains(#"contains("/applications/codex.app/contents/")"#),
            "Use in Codex must terminate every Codex.app helper process"
        )

        guard let envRange = text.range(
                of: "private func isCodexExecutableCommand",
                range: consumerRange.upperBound..<text.endIndex
              ) else {
            return XCTFail("Could not locate Codex auth-consumer matcher")
        }

        let consumerMatcher = text[consumerRange.lowerBound..<envRange.lowerBound]
        XCTAssertTrue(consumerMatcher.contains(#"contains(" exec ")"#))
        XCTAssertTrue(consumerMatcher.contains(#"contains("/node_repl ")"#))

        let executableMatcher = text[envRange.lowerBound...].prefix(900)
        XCTAssertTrue(executableMatcher.contains(#"hasPrefix("codex ")"#))
        XCTAssertTrue(consumerMatcher.contains(#"contains("/codex ")"#))
        XCTAssertTrue(executableMatcher.contains(#"contains("/codex/codex ")"#))
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

        for method in ["func upsert(", "func updateTokens(", "func updateAlias(", "func remove(profileKeys:"] {
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

    func testBackgroundTokenRefreshIsNotConfigured() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let mirrorURL = root.appendingPathComponent("Sources/CodexSwitchboard/CodexAuthMirrorService.swift")
        let text = try String(contentsOf: mirrorURL, encoding: .utf8)

        XCTAssertFalse(
            text.contains("backgroundRefreshTimer"),
            "AuthMirrorService must not have a background token refresh timer"
        )
        XCTAssertFalse(
            text.contains("refreshAllProfiles"),
            "AuthMirrorService must not refresh all profiles periodically"
        )
        XCTAssertFalse(
            text.contains("tokenRefreshService"),
            "AuthMirrorService must not spend/rotate stored refresh tokens"
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
