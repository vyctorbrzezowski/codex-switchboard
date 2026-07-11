import Foundation
import XCTest
@testable import CodexSwitchboard

final class CodexAccountSwitchSafetyTests: XCTestCase {
    func testUnifiedChatGPTProcessIsRecognizedAsDesktopConsumer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chatGPT = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try writeAppBundle(at: chatGPT, bundleIdentifier: CodexDesktopApp.bundleIdentifier)

        let command = chatGPT
            .appendingPathComponent("Contents/MacOS/ChatGPT")
            .path
            .lowercased()

        XCTAssertTrue(CodexDesktopApp.isDesktopProcessCommand(
            command,
            candidateURLs: [chatGPT]
        ))
    }

    func testOldNativeChatGPTProcessIsNotRecognizedAsDesktopConsumer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let chatGPT = root.appendingPathComponent("ChatGPT.app", isDirectory: true)
        try writeAppBundle(at: chatGPT, bundleIdentifier: "com.openai.chat")

        let command = chatGPT
            .appendingPathComponent("Contents/MacOS/ChatGPT")
            .path
            .lowercased()

        XCTAssertFalse(CodexDesktopApp.isDesktopProcessCommand(
            command,
            candidateURLs: [chatGPT]
        ))
    }

    func testLegacyCodexProcessRemainsRecognizedAsDesktopConsumer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let codex = root.appendingPathComponent("Codex.app", isDirectory: true)
        try writeAppBundle(at: codex, bundleIdentifier: CodexDesktopApp.bundleIdentifier)

        let command = codex
            .appendingPathComponent("Contents/MacOS/Codex")
            .path
            .lowercased()

        XCTAssertTrue(CodexDesktopApp.isDesktopProcessCommand(
            command,
            candidateURLs: [codex]
        ))
    }

    func testFailedAuthReplacementPreservesExistingDestination() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let missingSource = root.appendingPathComponent("missing-auth.json")
        let destination = root.appendingPathComponent("auth.json")
        let original = Data("original-auth".utf8)
        try original.write(to: destination)

        XCTAssertThrowsError(try CodexAuthFileTransaction.replace(
            source: missingSource,
            destination: destination
        ))
        XCTAssertEqual(try Data(contentsOf: destination), original)
    }

    func testSuccessfulAuthReplacementUsesOwnerOnlyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let source = root.appendingPathComponent("captured-auth.json")
        let destination = root.appendingPathComponent("auth.json")
        try Data("replacement-auth".utf8).write(to: source)
        try Data("original-auth".utf8).write(to: destination)

        try CodexAuthFileTransaction.replace(source: source, destination: destination)

        XCTAssertEqual(try Data(contentsOf: destination), Data("replacement-auth".utf8))
        let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
        XCTAssertEqual(attributes[.posixPermissions] as? NSNumber, NSNumber(value: 0o600))
    }

    private func writeAppBundle(at url: URL, bundleIdentifier: String) throws {
        let contents = url.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: ["CFBundleIdentifier": bundleIdentifier],
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
