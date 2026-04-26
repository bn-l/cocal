import Testing
import Foundation
@testable import CodexSwitcher

@Suite("CodexConfig — classify")
struct CodexConfigClassifyTests {

    @Test("Empty content => unset")
    func emptyIsUnset() {
        #expect(CodexConfig.classify("") == .unset)
    }

    @Test("file mode")
    func file() {
        #expect(CodexConfig.classify("cli_auth_credentials_store = \"file\"\n") == .file)
    }

    @Test("keyring mode")
    func keyring() {
        #expect(CodexConfig.classify("cli_auth_credentials_store = \"keyring\"\n") == .keyring)
    }

    @Test("auto mode")
    func auto() {
        #expect(CodexConfig.classify("cli_auth_credentials_store = \"auto\"\n") == .auto)
    }

    @Test("Case-insensitive value")
    func caseInsensitive() {
        #expect(CodexConfig.classify("cli_auth_credentials_store = \"FILE\"\n") == .file)
        #expect(CodexConfig.classify("cli_auth_credentials_store = \"KeyRing\"\n") == .keyring)
    }

    @Test("Comment lines are ignored")
    func commentsIgnored() {
        let toml = """
        # cli_auth_credentials_store = "keyring"
        cli_auth_credentials_store = "file"
        """
        #expect(CodexConfig.classify(toml) == .file)
    }

    @Test("First non-comment match wins")
    func firstWins() {
        let toml = """
        cli_auth_credentials_store = "file"
        cli_auth_credentials_store = "keyring"
        """
        #expect(CodexConfig.classify(toml) == .file)
    }

    @Test("Trailing comment does not break value")
    func trailingComment() {
        let toml = "cli_auth_credentials_store = \"file\" # use file\n"
        #expect(CodexConfig.classify(toml) == .file)
    }

    @Test("Unknown value => unset")
    func unknownValue() {
        #expect(CodexConfig.classify("cli_auth_credentials_store = \"hsm\"\n") == .unset)
    }

    @Test("StorageMode.needsFileMode (unset is treated as .file because Codex's documented default is file)")
    func needsFileModeFlag() {
        // Per openai/codex `codex-rs/config/src/types.rs`, the enum's #[default] is File.
        // Absence of the key in config.toml therefore resolves to file mode, so the
        // popover prompt should NOT fire on .unset — it would be a false alarm.
        #expect(CodexConfig.StorageMode.file.needsFileMode == false)
        #expect(CodexConfig.StorageMode.unset.needsFileMode == false)
        #expect(CodexConfig.StorageMode.keyring.needsFileMode == true)
        #expect(CodexConfig.StorageMode.auto.needsFileMode == true)
    }
}

@Suite("CodexConfig — rewriteFileMode")
struct CodexConfigRewriteTests {

    @Test("Empty content gets the key inserted")
    func emptyInserts() {
        let out = CodexConfig.rewriteFileMode("")
        #expect(out.contains("cli_auth_credentials_store = \"file\""))
        #expect(out.hasSuffix("\n"))
    }

    @Test("Existing key is replaced in place")
    func replacesExisting() {
        let input = """
        # header
        cli_auth_credentials_store = "keyring"
        other_key = 1
        """
        let out = CodexConfig.rewriteFileMode(input)
        #expect(CodexConfig.classify(out) == .file)
        #expect(out.contains("other_key = 1"))
        #expect(out.contains("# header"))
        #expect(!out.contains("\"keyring\""))
    }

    @Test("Key inserted before first [section] header")
    func insertsBeforeSection() {
        let input = """
        # top notes
        unrelated = true

        [profiles.foo]
        x = 1
        """
        let out = CodexConfig.rewriteFileMode(input)
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let storeIdx = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("cli_auth_credentials_store") }
        let sectionIdx = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "[profiles.foo]" }
        #expect(storeIdx != nil)
        #expect(sectionIdx != nil)
        if let s = storeIdx, let p = sectionIdx { #expect(s < p) }
        #expect(CodexConfig.classify(out) == .file)
    }

    @Test("Comment line containing the key is left alone, value still inserted")
    func commentNotMatched() {
        let input = "# cli_auth_credentials_store = \"keyring\"\n"
        let out = CodexConfig.rewriteFileMode(input)
        #expect(out.contains("# cli_auth_credentials_store = \"keyring\""))
        #expect(CodexConfig.classify(out) == .file)
    }

    @Test("Already file-mode is preserved (idempotent)")
    func idempotentFileMode() {
        let input = "cli_auth_credentials_store = \"file\"\n"
        let out = CodexConfig.rewriteFileMode(input)
        #expect(CodexConfig.classify(out) == .file)
        // No duplicate insertion
        let occurrences = out.components(separatedBy: "cli_auth_credentials_store").count - 1
        #expect(occurrences == 1)
    }

    @Test("File ends in newline after rewrite")
    func endsWithNewline() {
        let input = "x = 1"
        let out = CodexConfig.rewriteFileMode(input)
        #expect(out.hasSuffix("\n"))
    }
}

@Suite("CodexConfig — switchToFileMode (file IO)")
struct CodexConfigSwitchTests {

    private static func makeTemp() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-config-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Writes file mode when config absent")
    func writesWhenAbsent() throws {
        let dir = Self.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        let cfg = CodexConfig(configURL: url)
        try cfg.switchToFileMode()
        #expect(cfg.detectMode() == .file)
    }

    @Test("Replaces existing keyring value preserving other content")
    func replacesKeyring() throws {
        let dir = Self.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        let initial = """
        # comment
        cli_auth_credentials_store = "keyring"
        other = 42
        """
        try initial.data(using: .utf8)!.write(to: url)

        let cfg = CodexConfig(configURL: url)
        try cfg.switchToFileMode()

        let out = try String(contentsOf: url, encoding: .utf8)
        #expect(cfg.detectMode() == .file)
        #expect(out.contains("other = 42"))
        #expect(out.contains("# comment"))
    }

    @Test("Idempotent: switching when already file-mode preserves byte content")
    func idempotentSwitch() throws {
        let dir = Self.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.toml")
        let initial = """
        # header line
        cli_auth_credentials_store = "file"
        other = 42

        [profiles.foo]
        x = 1
        """
        try initial.data(using: .utf8)!.write(to: url)

        let cfg = CodexConfig(configURL: url)
        try cfg.switchToFileMode()
        try cfg.switchToFileMode()

        // Final file is still classified as .file, contains all the original keys
        // and exactly one occurrence of cli_auth_credentials_store.
        let out = try String(contentsOf: url, encoding: .utf8)
        #expect(cfg.detectMode() == .file)
        #expect(out.contains("# header line"))
        #expect(out.contains("[profiles.foo]"))
        #expect(out.contains("other = 42"))
        let count = out.components(separatedBy: "cli_auth_credentials_store").count - 1
        #expect(count == 1)
    }

    @Test("Creates parent dir when ~/.codex doesn't exist yet (fresh box)")
    func createsParentDir() throws {
        let dir = Self.makeTemp()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Note: parent dir is intentionally NOT pre-created.
        let nested = dir.appendingPathComponent("brand-new-codex").appendingPathComponent("config.toml")
        let cfg = CodexConfig(configURL: nested)
        try cfg.switchToFileMode()
        #expect(FileManager.default.fileExists(atPath: nested.path))
        #expect(cfg.detectMode() == .file)
    }
}
