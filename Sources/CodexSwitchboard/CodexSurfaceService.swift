import AppKit
import Foundation

enum CodexDesktopApp {
    static let bundleIdentifier = "com.openai.codex"
    static let candidateURLs = [
        URL(fileURLWithPath: "/Applications/ChatGPT.app"),
        URL(fileURLWithPath: "/Applications/Codex.app"),
    ]

    static func installedURL(
        fileManager: FileManager = .default,
        candidateURLs: [URL] = CodexDesktopApp.candidateURLs
    ) -> URL? {
        candidateURLs.first { isCodexApp(at: $0, fileManager: fileManager) }
    }

    private static func isCodexApp(at url: URL, fileManager: FileManager) -> Bool {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard fileManager.fileExists(atPath: infoURL.path),
              let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return false
        }
        return info["CFBundleIdentifier"] as? String == bundleIdentifier
    }
}

enum CodexSurfaceKind: String, CaseIterable, Codable, Identifiable {
    case desktop
    case cli

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .desktop: return "Codex Desktop"
        case .cli: return "Codex CLI"
        }
    }
}

struct CodexSurfaceStatus: Identifiable, Equatable, Codable {
    var id: CodexSurfaceKind { kind }

    let kind: CodexSurfaceKind
    let detected: Bool
    let running: Bool
    let codexHomePath: String
    let authStoreMode: String
    let activeProfileKey: String?
    let activeEmail: String?
    let activeAccountID: String?
    let sharedWith: CodexSurfaceKind?

    var isLoggedIn: Bool {
        activeEmail?.isEmpty == false || activeAccountID?.isEmpty == false
    }
}

final class CodexSurfaceService {
    private let fileManager: FileManager
    private let homeURL: URL

    init(
        fileManager: FileManager = .default,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeURL = homeURL
    }

    func statuses() -> [CodexSurfaceStatus] {
        Self.annotatingSharedStores([
            desktopStatus(),
            cliStatus()
        ]).filter(\.detected)
    }

    static func annotatingSharedStores(_ statuses: [CodexSurfaceStatus]) -> [CodexSurfaceStatus] {
        statuses.map { status in
            guard status.detected else { return status }
            let shared = statuses.first {
                $0.kind != status.kind
                    && $0.detected
                    && !$0.codexHomePath.isEmpty
                    && $0.codexHomePath == status.codexHomePath
            }?.kind

            return CodexSurfaceStatus(
                kind: status.kind,
                detected: status.detected,
                running: status.running,
                codexHomePath: status.codexHomePath,
                authStoreMode: status.authStoreMode,
                activeProfileKey: status.activeProfileKey,
                activeEmail: status.activeEmail,
                activeAccountID: status.activeAccountID,
                sharedWith: shared
            )
        }
    }

    private func desktopStatus() -> CodexSurfaceStatus {
        let codexHome = defaultCodexHome()
        let activeAuth = activeAuth(in: codexHome)
        let running = isDesktopRunning
        return CodexSurfaceStatus(
            kind: .desktop,
            detected: isDesktopDetected(running: running),
            running: running,
            codexHomePath: codexHome.standardizedFileURL.path,
            authStoreMode: authStoreMode(in: codexHome),
            activeProfileKey: activeProfileKey(for: activeAuth),
            activeEmail: activeAuth?.email,
            activeAccountID: activeAuth?.accountID,
            sharedWith: nil
        )
    }

    private func cliStatus() -> CodexSurfaceStatus {
        let codexHome = cliCodexHome()
        let activeAuth = activeAuth(in: codexHome)
        let running = isCLIRunning
        return CodexSurfaceStatus(
            kind: .cli,
            detected: cliExecutablePath() != nil || running,
            running: running,
            codexHomePath: codexHome.standardizedFileURL.path,
            authStoreMode: authStoreMode(in: codexHome),
            activeProfileKey: activeProfileKey(for: activeAuth),
            activeEmail: activeAuth?.email,
            activeAccountID: activeAuth?.accountID,
            sharedWith: nil
        )
    }

    private func isDesktopDetected(running: Bool) -> Bool {
        CodexDesktopApp.installedURL(fileManager: fileManager) != nil || running
    }

    private var isDesktopRunning: Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: CodexDesktopApp.bundleIdentifier)
            .filter { !$0.isTerminated }
            .isEmpty
    }

    private var isCLIRunning: Bool {
        processLines().contains { line in
            let lowercased = line.lowercased()
            return lowercased == "codex"
                || lowercased.hasPrefix("codex ")
                || lowercased.contains("/codex ")
                || lowercased.hasSuffix("/codex")
                || lowercased.contains(" codex ")
        }
    }

    private func defaultCodexHome() -> URL {
        homeURL.appendingPathComponent(".codex", isDirectory: true)
    }

    private func cliCodexHome() -> URL {
        if let value = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: value)
        }
        return defaultCodexHome()
    }

    private func activeAuth(in codexHome: URL) -> StoredCodexAuth? {
        StoredCodexAuth.load(from: codexHome.appendingPathComponent("auth.json"))
    }

    private func authStoreMode(in codexHome: URL) -> String {
        guard let config = try? String(
            contentsOf: codexHome.appendingPathComponent("config.toml"),
            encoding: .utf8
        ) else {
            return "file"
        }

        for key in ["cli_auth_credentials_store", "auth_credentials_store_mode", "auth_credentials_store"] {
            if let value = tomlStringValue(named: key, in: config) {
                return value
            }
        }
        return "file"
    }

    private func tomlStringValue(named key: String, in text: String) -> String? {
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.split(separator: "#", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard line.hasPrefix("\(key)") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            return parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                .lowercased()
        }
        return nil
    }

    private func activeProfileKey(for activeAuth: StoredCodexAuth?) -> String? {
        guard let activeAuth else { return nil }
        return capturedProfileAuths().first { profile in
            profile.auth.idToken == activeAuth.idToken
                && profile.auth.accessToken == activeAuth.accessToken
                && profile.auth.refreshToken == activeAuth.refreshToken
        }?.sourceProfileKey
    }

    private func capturedProfileAuths() -> [(auth: StoredCodexAuth, sourceProfileKey: String?)] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: AppStorage.profilesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return entries.compactMap { entry in
            guard entry.lastPathComponent != "backups",
                  (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let auth = StoredCodexAuth.load(from: entry.appendingPathComponent("auth.json")) else {
                return nil
            }
            let meta = AppStorage.readJSON(entry.appendingPathComponent("meta.json")) ?? [:]
            return (auth, meta["source_profile_key"] as? String)
        }
    }

    private func cliExecutablePath() -> String? {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let candidates = envPath.split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path
        } + [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(homeURL.path)/.local/bin/codex",
            "\(homeURL.path)/.openclaw/bin/codex"
        ]
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }

    private func processLines() -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "command="]

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchboardSurface-\(UUID().uuidString).log")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
              let outputHandle = FileHandle(forWritingAtPath: outputURL.path) else {
            return []
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
        defer {
            try? outputHandle.close()
            try? fileManager.removeItem(at: outputURL)
        }

        process.standardOutput = outputHandle
        process.standardError = outputHandle

        do {
            try process.run()
            process.waitUntilExit()
            try outputHandle.synchronize()
            let data = (try? Data(contentsOf: outputURL)) ?? Data()
            return (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        } catch {
            return []
        }
    }
}
