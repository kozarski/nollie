#if os(macOS)
import Foundation
import Darwin
import Testing

/// Keys move out of a setup's `.env` files into the Keychain at each start, and each Hermes
/// process gets them from its key pipe. Every value here is an obvious fake.
struct RuntimeKeysTests {
    private let id = UUID()

    // MARK: Reading `.env` the way Hermes does

    @Test func envFileReadsLikeHermes() throws {
        let text = """
            # Hermes keys
            export OPENAI_API_KEY = fake-openai-1  # a comment
            ANTHROPIC_API_KEY="fake-\\"quoted\\"-2" # note
            GROQ_API_KEY='fake-3 # kept'
            PLAIN_SETTING=abc#def
            EMPTY_TOKEN=
            WINDOWS_KEY=fake-4\r

            """
        let env = try #require(RuntimeEnvFile(Data(("\u{FEFF}" + text).utf8)))
        let values = env.values.mapValues(\.value)
        #expect(values["OPENAI_API_KEY"] == "fake-openai-1")
        #expect(values["ANTHROPIC_API_KEY"] == "fake-\"quoted\"-2")
        #expect(values["GROQ_API_KEY"] == "fake-3 # kept")
        #expect(values["PLAIN_SETTING"] == "abc#def")
        #expect(values["EMPTY_TOKEN"] == "")
        #expect(values["WINDOWS_KEY"] == "fake-4")
        #expect(!env.hasOpenQuote)
        #expect(env.values.values.allSatisfy { !$0.ambiguous })
    }

    @Test func valuesHermesAndDotenvReadDifferentlyAreMarked() throws {
        let env = try #require(RuntimeEnvFile(Data("A_KEY=\"fake\\nline\"\nB_KEY=\"fake\" trailing\nC_KEY=fake\n".utf8)))
        #expect(env.values["A_KEY"]?.ambiguous == true)
        #expect(env.values["B_KEY"]?.ambiguous == true)
        #expect(env.values["C_KEY"]?.ambiguous == false)
        #expect(try #require(RuntimeEnvFile(Data("D_KEY=\"fake\nE_KEY=fake\n".utf8))).hasOpenQuote)
        #expect(RuntimeEnvFile(Data([0x41, 0x3D, 0xFF, 0xFE])) == nil)
        #expect(try #require(RuntimeEnvFile(Data("URL=https://x/${D_KEY}/${E_KEY}\n".utf8))).references == ["D_KEY", "E_KEY"])
    }

    @Test func keyNamesMatchHermesCredentials() {
        for name in ["OPENROUTER_API_KEY", "TELEGRAM_BOT_TOKEN", "FEISHU_APP_SECRET", "MATRIX_PASSWORD",
                     "AWS_SECRET_ACCESS_KEY", "HERMES_CUSTOM_LOCAL_API_KEY", "GH_TOKEN"] {
            #expect(RuntimeKeyNames.isKey(name), "\(name)")
        }
        for name in ["HERMES_DASHBOARD_SESSION_TOKEN", "TERMINAL_SSH_KEY", "HERMES_KANBAN_TOKEN", "NOLLIE_KEYS_KEY",
                     "OPENAI_BASE_URL", "TELEGRAM_ALLOWED_USERS", "1BAD_KEY", "BAD-KEY", "", "lower_key"] {
            #expect(!RuntimeKeyNames.isKey(name), "\(name)")
        }
        #expect(RuntimeKeyNames.isProfile("default") && RuntimeKeyNames.isProfile("scout-2"))
        #expect(!RuntimeKeyNames.isProfile(".scout.staging-12") && !RuntimeKeyNames.isProfile("Scout") && !RuntimeKeyNames.isProfile("a/b"))
    }

    // MARK: Moving keys

    @Test func keysMoveAndSettingsStay() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        let original = """
            # Hermes keys
            OPENROUTER_API_KEY=fake-openrouter-1
            HERMES_MAX_ITERATIONS=40

            export ANTHROPIC_API_KEY="fake-anthropic-2"
            """
        try setup.write(original + "\n", to: ".env")
        try setup.write("TELEGRAM_BOT_TOKEN=fake-telegram-3\nTELEGRAM_ALLOWED_USERS=1\n", to: "profiles/scout/.env")
        let store = MemoryKeys()

        let outcome = try migrate(setup, store)

        #expect(outcome == .init(moved: 3, cleared: 0, copied: 0, left: 0, forgotten: 0))
        #expect(try setup.read(".env") == """
            \(RuntimeKeyMigration.header)
            # Hermes keys
            HERMES_MAX_ITERATIONS=40


            """)
        #expect(try setup.read("profiles/scout/.env") == "\(RuntimeKeyMigration.header)\nTELEGRAM_ALLOWED_USERS=1\n")
        #expect(try setup.mode(".env") == 0o600)
        #expect(store.value("default", "OPENROUTER_API_KEY", id) == "fake-openrouter-1")
        #expect(store.value("default", "ANTHROPIC_API_KEY", id) == "fake-anthropic-2")
        #expect(store.value("scout", "TELEGRAM_BOT_TOKEN", id) == "fake-telegram-3")
        #expect(store.value("default", "TELEGRAM_BOT_TOKEN", id) == nil)

        // The next start finds nothing to do, and the note isn't added twice.
        let before = try setup.read(".env")
        #expect(try migrate(setup, store) == .init())
        #expect(try setup.read(".env") == before)
    }

    @Test func aBotFileOfOnlyKeysStaysNonEmpty() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        try setup.write("OPENROUTER_API_KEY=fake-1", to: "profiles/solo/.env")
        _ = try migrate(setup, MemoryKeys())
        #expect(try setup.read("profiles/solo/.env") == RuntimeKeyMigration.header + "\n")
    }

    @Test func stoppingHalfwayLosesNothing() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        let original = "OPENROUTER_API_KEY=fake-1\nGROQ_API_KEY=fake-2\nSETTING=on\n"
        try setup.write(original, to: ".env")
        let store = MemoryKeys()

        // The Keychain refuses one key: it stays in the file, the other moves.
        store.refusing = ["GROQ_API_KEY"]
        #expect(try migrate(setup, store) == .init(moved: 1, left: 1))
        #expect(try setup.read(".env").contains("GROQ_API_KEY=fake-2"))
        #expect(!(try setup.read(".env").contains("OPENROUTER_API_KEY")))

        // Stopped after the Keychain write, before the rename: the old file and a stray copy.
        store.refusing = []
        try setup.write(original, to: ".env")
        try setup.write("SETTING=on\n", to: ".env.nollie-\(UUID().uuidString)")
        #expect(try migrate(setup, store) == .init(moved: 2))
        #expect(try setup.read(".env") == "\(RuntimeKeyMigration.header)\nSETTING=on\n")
        #expect(try setup.names(in: "").filter { $0.contains(".nollie-") }.isEmpty)
        #expect(store.value("default", "OPENROUTER_API_KEY", id) == "fake-1")
        #expect(store.value("default", "GROQ_API_KEY", id) == "fake-2")
        #expect(store.count == 2)
    }

    @Test func keysHermesWritesBackMoveAtTheNextStart() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        try setup.write("OPENROUTER_API_KEY=fake-old\n", to: ".env")
        let store = MemoryKeys()
        _ = try migrate(setup, store)
        // Hermes's own key setup appends the new value to the file.
        try setup.write(try setup.read(".env") + "OPENROUTER_API_KEY=fake-new\n", to: ".env")
        #expect(try migrate(setup, store).moved == 1)
        #expect(store.value("default", "OPENROUTER_API_KEY", id) == "fake-new")
        #expect(!(try setup.read(".env").contains("fake-")))
    }

    @Test func aKeyHermesClearedIsForgotten() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        let store = MemoryKeys()
        try store.save(RuntimeKey(profile: "default", name: "ANTHROPIC_API_KEY", value: "fake-1"), for: id)
        try setup.write("ANTHROPIC_API_KEY=\nANTHROPIC_TOKEN=\n", to: ".env")
        #expect(try migrate(setup, store) == .init(cleared: 1))
        #expect(store.value("default", "ANTHROPIC_API_KEY", id) == nil)
        #expect(try setup.read(".env") == "ANTHROPIC_API_KEY=\nANTHROPIC_TOKEN=\n")
    }

    @Test func referencesAndValuesThatAreNotKeysStay() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        let text = "BASE_API_KEY=fake-1\nPROXY_URL=https://x/${BASE_API_KEY}\nVAULT_API_KEY=op://vault/item/field\n"
        try setup.write(text, to: ".env")
        let store = MemoryKeys()
        #expect(try migrate(setup, store) == .init(left: 1))
        #expect(try setup.read(".env") == text)
        #expect(store.count == 0)

        let open = "OPENROUTER_API_KEY=fake-2\nNOTE_TOKEN=\"starts here\nand ends here\"\n"
        try setup.write(open, to: ".env")
        #expect(try migrate(setup, store).left >= 1)
        #expect(try setup.read(".env") == open)
        #expect(store.count == 0)
    }

    @Test func linkedFilesAreNeverFollowedOrSplit() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        try setup.write("OPENROUTER_API_KEY=fake-1\n", to: "elsewhere.env")
        #expect(symlink(setup.url("elsewhere.env").path, setup.url(".env").path) == 0)
        try setup.write("OPENROUTER_API_KEY=fake-2\n", to: "profiles/linked/.env")
        #expect(link(setup.url("profiles/linked/.env").path, setup.url("profiles/linked/second.env").path) == 0)
        let store = MemoryKeys()
        #expect(try migrate(setup, store).left == 2)
        #expect(try setup.read("elsewhere.env") == "OPENROUTER_API_KEY=fake-1\n")
        #expect(try setup.read("profiles/linked/.env") == "OPENROUTER_API_KEY=fake-2\n")
        #expect(store.count == 0)
    }

    @Test func aFileHermesIsWritingIsLeftForTheNextStart() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        try setup.write("OPENROUTER_API_KEY=fake-1\nGROQ_API_KEY=fake-2\n", to: ".env")
        let lock = open(setup.url(".env.lock").path, O_RDWR | O_CREAT, 0o600)
        #expect(flock(lock, LOCK_EX) == 0)
        defer { close(lock) }
        let store = MemoryKeys()
        var migration = RuntimeKeyMigration(installationID: id, home: setup.home, store: store)
        migration.lockAttempts = 2
        #expect(try migration.run() == .init(left: 2))
        #expect(store.count == 0)
    }

    @Test func backupsKeepOnlyKeysTheKeychainLacks() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        try setup.write("OPENROUTER_API_KEY=fake-live\n", to: ".env")
        try setup.write("OPENROUTER_API_KEY=fake-older\nRETIRED_API_KEY=fake-retired\nSETTING=1\n", to: ".env.bak-20261027T000000Z")
        let store = MemoryKeys()
        #expect(try migrate(setup, store) == .init(moved: 1, left: 1))
        #expect(try setup.read(".env.bak-20261027T000000Z") == "RETIRED_API_KEY=fake-retired\nSETTING=1\n")
        #expect(store.value("default", "OPENROUTER_API_KEY", id) == "fake-live")
    }

    @Test func aCopiedBotGetsTheKeysItsCopyTookAlong() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        let store = MemoryKeys()
        try store.save(RuntimeKey(profile: "default", name: "OPENROUTER_API_KEY", value: "fake-shared"), for: id)
        try store.save(RuntimeKey(profile: "default", name: "GROQ_API_KEY", value: "fake-groq"), for: id)
        try setup.write("GROQ_API_KEY=fake-own\n", to: "profiles/copy/.env")
        try setup.write(#"{"version":1,"from":"default","names":["OPENROUTER_API_KEY","GROQ_API_KEY","TELEGRAM_BOT_TOKEN"]}"#,
                        to: "profiles/copy/\(RuntimeKeyMigration.cloneNote)")
        #expect(try migrate(setup, store) == .init(moved: 1, copied: 1))
        #expect(store.value("copy", "OPENROUTER_API_KEY", id) == "fake-shared")
        #expect(store.value("copy", "GROQ_API_KEY", id) == "fake-own")
        #expect(store.value("copy", "TELEGRAM_BOT_TOKEN", id) == nil)
        #expect(!setup.exists("profiles/copy/\(RuntimeKeyMigration.cloneNote)"))
    }

    @Test func keysOfDeletedBotsAreForgotten() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        let store = MemoryKeys()
        for profile in ["default", "kept", "gone", "tombstoned"] {
            try store.save(RuntimeKey(profile: profile, name: "OPENROUTER_API_KEY", value: "fake-\(profile)"), for: id)
        }
        try setup.write("SETTING=1\n", to: "profiles/kept/.env")
        try setup.write("SETTING=1\n", to: "profiles/tombstoned/.env")
        try setup.write("deleted\n", to: "profiles/.deleted/tombstoned")
        #expect(try migrate(setup, store).forgotten == 2)
        #expect(store.value("kept", "OPENROUTER_API_KEY", id) == "fake-kept")
        #expect(store.value("default", "OPENROUTER_API_KEY", id) == "fake-default")
        #expect(store.value("gone", "OPENROUTER_API_KEY", id) == nil)
        #expect(store.value("tombstoned", "OPENROUTER_API_KEY", id) == nil)

        // A profiles folder that can't be read forgets nothing on a guess.
        try store.save(RuntimeKey(profile: "gone", name: "OPENROUTER_API_KEY", value: "fake-gone"), for: id)
        #expect(chmod(setup.url("profiles").path, 0) == 0)
        defer { chmod(setup.url("profiles").path, 0o700) }
        #expect(try migrate(setup, store).forgotten == 0)
        #expect(store.value("gone", "OPENROUTER_API_KEY", id) == "fake-gone")
    }

    @Test func keysOfRemovedSetupsAreForgotten() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        let store = MemoryKeys()
        let removed = UUID(), present = UUID()
        try FileManager.default.createDirectory(at: setup.root.appendingPathComponent(present.uuidString), withIntermediateDirectories: true)
        for owner in [id, removed, present] {
            try store.save(RuntimeKey(profile: "default", name: "OPENROUTER_API_KEY", value: "fake"), for: owner)
        }
        #expect(try store.forgetRemovedInstallations(in: setup.root, keeping: id) == 1)
        #expect(try store.installations() == [id, present])
    }

    @Test func anUnreadableKeychainStopsTheStart() throws {
        let setup = try KeysFixture()
        defer { setup.remove() }
        try setup.write("OPENROUTER_API_KEY=fake-1\n", to: ".env")
        let store = MemoryKeys()
        store.unreadable = true
        #expect(throws: RuntimeKeyError.self) { try migrate(setup, store) }
        #expect(try setup.read(".env") == "OPENROUTER_API_KEY=fake-1\n")
    }

    // MARK: Handing keys over

    @Test func handoffGroupsKeysByBotAndKeepsOnlyKeys() throws {
        let data = RuntimeKeyHandoff.payload([
            RuntimeKey(profile: "default", name: "OPENROUTER_API_KEY", value: "fake-1"),
            RuntimeKey(profile: "scout", name: "GROQ_API_KEY", value: "fake-2"),
            RuntimeKey(profile: "../x", name: "GROQ_API_KEY", value: "fake-3"),
            RuntimeKey(profile: "scout", name: "HERMES_DASHBOARD_SESSION_TOKEN", value: "fake-4"),
        ])
        struct Body: Decodable { let version: Int; let profiles: [String: [String: String]] }
        let body = try JSONDecoder().decode(Body.self, from: data)
        #expect(body.version == 1)
        #expect(body.profiles == ["default": ["OPENROUTER_API_KEY": "fake-1"], "scout": ["GROQ_API_KEY": "fake-2"]])
        #expect(RuntimeKeyHandoff.payload([]) == Data(#"{"profiles":{},"version":1}"#.utf8))
    }

    #if NOLLIE_DIRECT
    @Test func handoverWritesTheWholePayloadAndCloses() throws {
        // More than a pipe holds at once, so the write has to wait for the reader.
        let payload = RuntimeKeyHandoff.payload((0..<2_000).map {
            RuntimeKey(profile: "default", name: "FAKE_\($0)_API_KEY", value: String(repeating: "f", count: 120))
        })
        #expect(payload.count > 200_000)
        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        NativeRuntimeBackend.handOver(payload, to: ends[1])
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(ends[0], &buffer, buffer.count)
            if count <= 0 { break }
            received.append(contentsOf: buffer.prefix(count))
        }
        close(ends[0])
        #expect(received == payload)
    }

    @Test func aChildThatNeverReadsCannotStopTheHelper() async throws {
        var ends: [Int32] = [-1, -1]
        #expect(pipe(&ends) == 0)
        close(ends[0])
        NativeRuntimeBackend.handOver(Data(repeating: 1, count: 100_000), to: ends[1])
        try await Task.sleep(for: .milliseconds(200))
        // Still here with SIGPIPE at its default, which ends a process: the write failed quietly.
        var current = sigaction()
        #expect(sigaction(SIGPIPE, nil, &current) == 0)
        #expect(current.__sigaction_u.__sa_handler == nil)
    }
    #endif

    @Test func aKeyNeverPrintsItsValue() {
        let key = RuntimeKey(profile: "default", name: "OPENROUTER_API_KEY", value: "fake-secret-value")
        #expect(String(describing: key) == "default/OPENROUTER_API_KEY")
        #expect(!String(reflecting: [key]).contains("fake-secret-value"))
    }

    private func migrate(_ setup: KeysFixture, _ store: MemoryKeys) throws -> RuntimeKeyMigration.Outcome {
        try RuntimeKeyMigration(installationID: id, home: setup.home, store: store).run()
    }
}

/// A Keychain in memory, with switches for the failures that matter.
final class MemoryKeys: RuntimeKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: String] = [:]
    var refusing: Set<String> = []
    var unreadable = false

    var count: Int { lock.withLock { items.count } }
    func value(_ profile: String, _ name: String, _ id: UUID) -> String? { lock.withLock { items["\(id)/\(profile)/\(name)"] } }

    func keys(for installationID: UUID) throws -> [RuntimeKey] {
        try lock.withLock {
            if unreadable { throw RuntimeKeyError.keychain(-25308) }
            return items.compactMap { account, value in
                let parts = account.split(separator: "/").map(String.init)
                return parts[0] == installationID.uuidString ? RuntimeKey(profile: parts[1], name: parts[2], value: value) : nil
            }
        }
    }
    func save(_ key: RuntimeKey, for installationID: UUID) throws {
        try lock.withLock {
            if refusing.contains(key.name) { throw RuntimeKeyError.keychain(-25293) }
            items["\(installationID)/\(key.profile)/\(key.name)"] = key.value
        }
    }
    func delete(profile: String, name: String, for installationID: UUID) throws {
        _ = lock.withLock { items.removeValue(forKey: "\(installationID)/\(profile)/\(name)") }
    }
    func installations() throws -> Set<UUID> {
        lock.withLock { Set(items.keys.compactMap { UUID(uuidString: String($0.split(separator: "/")[0])) }) }
    }
}

/// A private installation folder in the real temporary directory (no symbolic links on the path).
struct KeysFixture {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }

    init() throws {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw RuntimeKeyError.invalid }
        root = URL(fileURLWithPath: String(cString: resolved)).appendingPathComponent("nollie-keys-" + UUID().uuidString)
        free(resolved)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("home/profiles"), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        chmod(root.path, 0o700)
    }
    func url(_ path: String) -> URL { home.appendingPathComponent(path) }
    func write(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(at: url(path).deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(text.utf8).write(to: url(path))
        chmod(url(path).path, 0o600)
    }
    func read(_ path: String) throws -> String { String(decoding: try Data(contentsOf: url(path)), as: UTF8.self) }
    func mode(_ path: String) throws -> Int { (try FileManager.default.attributesOfItem(atPath: url(path).path)[.posixPermissions] as? Int) ?? -1 }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }
    func names(in path: String) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: url(path).path) }
    func remove() {
        chmod(home.appendingPathComponent("profiles").path, 0o700)
        try? FileManager.default.removeItem(at: root)
    }
}
#endif
