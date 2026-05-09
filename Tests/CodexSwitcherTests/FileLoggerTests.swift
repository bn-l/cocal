import Testing
import Foundation
@testable import CodexSwitcher

@Suite("FileLogger — verbose file-based logging")
struct FileLoggerTests {

    private static func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filelogger-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Build a FileLogger that's always enabled, writing to a temp file.
    private static func makeLogger(dir: URL, filename: String = "debug.log") -> (FileLogger, URL) {
        let logURL = dir.appendingPathComponent(filename)
        let fl = FileLogger(url: logURL, isEnabled: { true })
        return (fl, logURL)
    }

    // MARK: - Writing

    @Test("Lines are written and flushed to disk when enabled")
    func writesWhenEnabled() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fl, logURL) = Self.makeLogger(dir: dir)

        fl.log("Cat", "first")
        fl.log("Cat", "second")
        fl.flush()

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == 2, "Should have 2 lines, got \(lines.count)")
        #expect(content.contains("first"))
        #expect(content.contains("second"))
    }

    @Test("Nothing is written when disabled")
    func silentWhenDisabled() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("debug.log")
        let fl = FileLogger(url: logURL, isEnabled: { false })

        fl.log("Cat", "should not appear")
        fl.flush()

        #expect(!FileManager.default.fileExists(atPath: logURL.path), "File should not be created when disabled")
    }

    @Test("Each line is tab-separated: timestamp, category, message")
    func lineFormat() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fl, logURL) = Self.makeLogger(dir: dir)

        fl.log("MyCategory", "Something happened")
        fl.flush()

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let parts = content.trimmingCharacters(in: .newlines).split(separator: "\t", maxSplits: 2)
        #expect(parts.count == 3, "Line should have 3 tab-separated parts, got \(parts.count)")
        #expect(parts[1] == "MyCategory")
        #expect(parts[2] == "Something happened")
        // Timestamp should parse back to a valid date.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        #expect(formatter.date(from: String(parts[0])) != nil, "Timestamp '\(parts[0])' should be valid ISO8601")
    }

    // MARK: - Rotation

    @Test("File is rotated when it exceeds maxBytes")
    func rotatesLargeFile() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fl, logURL) = Self.makeLogger(dir: dir)

        // Seed the file beyond the 2 MB threshold.
        let bigLine = String(repeating: "X", count: 1024) + "\n"
        var seed = ""
        for _ in 0..<2200 { seed += bigLine }
        try seed.data(using: .utf8)!.write(to: logURL)

        let sizeBefore = try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as! Int
        #expect(sizeBefore > FileLogger.maxBytes, "Pre-condition: file should exceed maxBytes")

        // Writing one more line triggers rotateIfNeeded.
        fl.log("Rot", "trigger rotation")
        fl.flush()

        let sizeAfter = try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as! Int
        #expect(sizeAfter < sizeBefore, "File should shrink after rotation (was \(sizeBefore), now \(sizeAfter))")
        #expect(sizeAfter <= FileLogger.maxBytes, "File should be under maxBytes after rotation")

        // The new line should be at the end.
        let content = try String(contentsOf: logURL, encoding: .utf8)
        #expect(content.hasSuffix("trigger rotation\n"), "New line should be appended after rotation")
    }

    @Test("File under maxBytes is not rotated")
    func noRotationWhenSmall() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fl, logURL) = Self.makeLogger(dir: dir)

        fl.log("A", "small")
        fl.flush()

        let sizeBefore = try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as! Int

        fl.log("A", "also small")
        fl.flush()

        let sizeAfter = try FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as! Int
        #expect(sizeAfter > sizeBefore, "File should grow, not shrink")
    }

    // MARK: - Edge cases

    @Test("Parent directories are created if absent")
    func createsParentDirs() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("a/b/c/debug.log")
        let fl = FileLogger(url: nested, isEnabled: { true })

        fl.log("Deep", "nested write")
        fl.flush()

        #expect(FileManager.default.fileExists(atPath: nested.path), "File should exist at nested path")
        let content = try String(contentsOf: nested, encoding: .utf8)
        #expect(content.contains("nested write"))
    }

    @Test("Multiple concurrent writes don't corrupt the file")
    func concurrentWrites() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (fl, logURL) = Self.makeLogger(dir: dir)

        let count = 100
        DispatchQueue.concurrentPerform(iterations: count) { i in
            fl.log("Concurrent", "line \(i)")
        }
        fl.flush()

        let content = try String(contentsOf: logURL, encoding: .utf8)
        let lines = content.split(separator: "\n")
        #expect(lines.count == count, "Should have exactly \(count) lines, got \(lines.count)")
    }

    @Test("flog global function does not crash")
    func flogSmoke() {
        flog("Test", "smoke test")
        flog("", "")
    }

    // MARK: - AppConfig integration

    @Test("AppConfig round-trips verboseLogging flag")
    func configRoundTrip() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.json")

        var config = AppConfig()
        #expect(config.verboseLogging == false)

        config.verboseLogging = true
        AppConfig.save(config, to: configURL)
        #expect(AppConfig.load(from: configURL).verboseLogging == true)

        config.verboseLogging = false
        AppConfig.save(config, to: configURL)
        #expect(AppConfig.load(from: configURL).verboseLogging == false)
    }

    @Test("Config missing verboseLogging key defaults to false")
    func configMissingKeyDefaultsFalse() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.json")

        try #"{"pollIntervalSeconds": 300}"#.data(using: .utf8)!
            .write(to: configURL, options: .atomic)
        #expect(AppConfig.load(from: configURL).verboseLogging == false)
    }

    @Test("Toggle flips enabled state dynamically")
    func toggleDynamicEnable() throws {
        let dir = Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let logURL = dir.appendingPathComponent("debug.log")
        let toggle = SendableToggle()
        let fl = FileLogger(url: logURL, isEnabled: { toggle.value })

        fl.log("A", "should not appear")
        fl.flush()
        #expect(!FileManager.default.fileExists(atPath: logURL.path))

        toggle.value = true
        fl.log("A", "should appear")
        fl.flush()
        #expect(FileManager.default.fileExists(atPath: logURL.path))
        let content = try String(contentsOf: logURL, encoding: .utf8)
        #expect(content.contains("should appear"))
        #expect(!content.contains("should not appear"))
    }
}

/// Thread-safe boolean for test use.
private final class SendableToggle: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
