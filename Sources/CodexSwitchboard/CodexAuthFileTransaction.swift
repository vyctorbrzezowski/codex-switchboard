import Foundation

enum CodexAuthFileTransaction {
    static func replace(
        source: URL,
        destination: URL,
        fileManager: FileManager = .default
    ) throws {
        let destinationDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let stagedURL = destinationDirectory.appendingPathComponent(
            ".\(destination.lastPathComponent).codex-switchboard-\(UUID().uuidString)"
        )
        defer { try? fileManager.removeItem(at: stagedURL) }

        try fileManager.copyItem(at: source, to: stagedURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: stagedURL.path
        )

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: stagedURL, to: destination)
        }
    }
}
