import Foundation

/// Stores the latest `/usage` result so the popover does not open empty after relaunch.
enum AccountSnapshotStore {

    private struct Payload: Codable {
        var lastRefreshEpoch: TimeInterval?
        var accounts: [Account]
    }

    private static var url: URL {
        AppStorage.rootURL.appendingPathComponent("accounts-snapshot.json")
    }

    static func load() -> (accounts: [Account], lastRefresh: Date?)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        guard let p = try? dec.decode(Payload.self, from: data), !p.accounts.isEmpty else { return nil }
        let date = p.lastRefreshEpoch.map { Date(timeIntervalSince1970: $0) }
        return (p.accounts, date)
    }

    static func save(accounts: [Account], lastRefresh: Date?) {
        let p = Payload(
            lastRefreshEpoch: lastRefresh.map { $0.timeIntervalSince1970 },
            accounts: accounts
        )
        guard let data = try? JSONEncoder().encode(p) else { return }
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
