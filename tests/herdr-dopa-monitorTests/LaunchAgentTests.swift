import XCTest
@testable import herdr_dopa_monitor

/// Unit tests for session naming / LaunchAgent path helpers.
final class LaunchAgentTests: XCTestCase {

    var savedEnv: [String: String?] = [:]
    let trackedKeys = ["HERDR_SESSION_NAME", "HERDR_SESSION",
                       "HERDR_PLUGIN_CONFIG_DIR", "HERDR_PLUGIN_STATE_DIR",
                       "HERDR_DOPA_CONFIG_DIR", "HERDR_DOPA_STATE_DIR"]

    override func setUp() {
        super.setUp()
        for key in trackedKeys {
            savedEnv[key] = Env.get(key)
        }
        Env.set("HERDR_DOPA_CONFIG_DIR", nil)
        Env.set("HERDR_DOPA_STATE_DIR", nil)
    }

    override func tearDown() {
        for (key, value) in savedEnv {
            Env.set(key, value)
        }
        super.tearDown()
    }

    func testEnvSessionNameWins() throws {
        Env.set("HERDR_SESSION_NAME", "work")
        Env.set("HERDR_SESSION", "other")
        defer { Env.set("HERDR_SESSION_NAME", nil); Env.set("HERDR_SESSION", nil) }
        XCTAssertEqual(try LaunchAgent.sessionName(), "work")
    }

    func testSessionNameFallbackEnv() throws {
        Env.set("HERDR_SESSION_NAME", nil)
        Env.set("HERDR_SESSION", "second-key")
        defer { Env.set("HERDR_SESSION", nil) }
        XCTAssertEqual(try LaunchAgent.sessionName(), "second-key")
    }

    func testSlugStableAndSafe() throws {
        Env.set("HERDR_SESSION_NAME", "my session/01")
        defer { Env.set("HERDR_SESSION_NAME", nil) }
        let first = try LaunchAgent.sessionSlug()
        let second = try LaunchAgent.sessionSlug()
        XCTAssertEqual(first, second)
        // my session/01 -> "my-session-01" + "." + sha1("my session/01") prefix
        XCTAssertEqual(first, "my-session-01.1ab3ddee")
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains(" "))
        let regex = try NSRegularExpression(pattern: "^[A-Za-z0-9_.-]+\\.[0-9a-f]{8}$")
        let range = NSRange(first.startIndex..<first.endIndex, in: first)
        XCTAssertNotNil(regex.firstMatch(in: first, range: range))
    }

    func testSlugEmptyNameBecomesDefault() throws {
        Env.set("HERDR_SESSION_NAME", "///")
        defer { Env.set("HERDR_SESSION_NAME", nil) }
        let slug = try LaunchAgent.sessionSlug()
        // "///" slugifies to nothing -> "default.<sha1 of '///'>"
        XCTAssertTrue(slug.hasPrefix("default."))
    }

    func testLabelFormat() throws {
        Env.set("HERDR_SESSION_NAME", "default")
        defer { Env.set("HERDR_SESSION_NAME", nil) }
        XCTAssertTrue(try LaunchAgent.label().hasPrefix("com.amas.herdr.dopa.monitor."))
    }

    func testPathsLayout() throws {
        Env.set("HERDR_SESSION_NAME", "s1")
        Env.set("HERDR_PLUGIN_CONFIG_DIR", nil)
        Env.set("HERDR_PLUGIN_STATE_DIR", nil)
        let p = try LaunchAgent.paths(homeDir: "/tmp/fakehome")
        XCTAssertTrue(p.plist.hasPrefix("/tmp/fakehome"))
        XCTAssertTrue((p.plist as NSString).lastPathComponent
            .hasPrefix("com.amas.herdr.dopa.monitor."))
        XCTAssertTrue(p.logDir.contains("/herdr-dopa-monitor/"))
        XCTAssertTrue(p.configDir.contains("/herdr-dopa-monitor/"))
        XCTAssertEqual(p.configDir, "/tmp/fakehome/Library/Application Support/herdr-dopa-monitor/s1.\(String(SHA1.hex("s1").prefix(8)))")
        XCTAssertEqual(p.logDir, "/tmp/fakehome/Library/Logs/herdr-dopa-monitor/s1.\(String(SHA1.hex("s1").prefix(8)))")
        XCTAssertEqual(p.plist, "/tmp/fakehome/Library/LaunchAgents/\(p.label).plist")
    }

    func testPluginRootsHonored() throws {
        Env.set("HERDR_SESSION_NAME", "s1")
        Env.set("HERDR_PLUGIN_CONFIG_DIR", "/tmp/cfg")
        Env.set("HERDR_PLUGIN_STATE_DIR", "/tmp/st")
        defer {
            Env.set("HERDR_PLUGIN_CONFIG_DIR", nil)
            Env.set("HERDR_PLUGIN_STATE_DIR", nil)
        }
        let p = try LaunchAgent.paths(homeDir: "/tmp/fakehome")
        XCTAssertTrue(p.configDir.hasPrefix("/tmp/cfg/"))
        XCTAssertTrue(p.stateDir.hasPrefix("/tmp/st/"))
    }

    func testServiceTargetFormat() throws {
        Env.set("HERDR_SESSION_NAME", "s1")
        defer { Env.set("HERDR_SESSION_NAME", nil) }
        let target = LaunchAgent.serviceTarget(labelName: "com.amas.herdr.dopa.monitor.x")
        XCTAssertEqual(target, "gui/\(getuid())/com.amas.herdr.dopa.monitor.x")
    }

    func testJsonSessionsParsesRawAndEnvelope() {
        let raw = ProcResult(
            exitCode: 0,
            stdout: #"{"sessions":[{"name":"a","running":true}]}"#,
            stderr: "")
        XCTAssertEqual(LaunchAgent.jsonSessions(raw).count, 1)
        let envelope = ProcResult(
            exitCode: 0,
            stdout: #"{"id":"x","result":{"sessions":[{"name":"a","running":false}]}}"#,
            stderr: "")
        XCTAssertEqual(LaunchAgent.jsonSessions(envelope).count, 1)
        let broken = ProcResult(exitCode: 1, stdout: "nope", stderr: "err")
        XCTAssertEqual(LaunchAgent.jsonSessions(broken).count, 0)
    }

    // MARK: - legacy label cleanup (com.herdr.* -> com.amas.*)

    func testLegacyLabelMapping() {
        XCTAssertEqual(
            LaunchAgent.legacyLabel(slug: "s1.1ab3ddee"),
            "com.herdr.dopa.monitor.s1.1ab3ddee")
        XCTAssertEqual(
            LaunchAgent.legacyLabel(forCurrentLabel: "com.amas.herdr.dopa.monitor.s1.1ab3ddee"),
            "com.herdr.dopa.monitor.s1.1ab3ddee")
        XCTAssertNil(LaunchAgent.legacyLabel(forCurrentLabel: "com.herdr.dopa.monitor.s1"))
        XCTAssertNil(LaunchAgent.legacyLabel(forCurrentLabel: "com.other.agent"))
        XCTAssertEqual(
            LaunchAgent.legacyPlistPath(homeDir: "/tmp/fakehome", slug: "s1.1ab3ddee"),
            "/tmp/fakehome/Library/LaunchAgents/com.herdr.dopa.monitor.s1.1ab3ddee.plist")
    }

    /// Hermetic cleanup check: temp home, stubbed launchctl runner. Only the
    /// same-slug legacy plist may be removed; every other plist stays.
    func testCleanupLegacyAgentRemovesSameSlugOnly() throws {
        let home = NSTemporaryDirectory() + "herdr-dopa-legacy-\(UUID().uuidString)"
        let agentsDir = home + "/Library/LaunchAgents"
        FsUtil.mkdirp(agentsDir)
        defer { try? FileManager.default.removeItem(atPath: home) }

        let legacySameSlug = agentsDir + "/com.herdr.dopa.monitor.s1.1ab3ddee.plist"
        let legacyOtherSlug = agentsDir + "/com.herdr.dopa.monitor.other.00000000.plist"
        let current = agentsDir + "/com.amas.herdr.dopa.monitor.s1.1ab3ddee.plist"
        for path in [legacySameSlug, legacyOtherSlug, current] {
            try "x".write(toFile: path, atomically: true, encoding: .utf8)
        }

        var commands: [[String]] = []
        let cleaned = LaunchAgent.cleanupLegacyAgent(
            currentLabel: "com.amas.herdr.dopa.monitor.s1.1ab3ddee",
            homeDir: home,
            run: { cmd in
                commands.append(cmd)
                return (0, "")
            })

        XCTAssertTrue(cleaned)
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands.first?.first, "launchctl")
        XCTAssertTrue(commands.first?.contains("bootout") == true)
        XCTAssertTrue(commands.first?.contains(
            "gui/\(getuid())/com.herdr.dopa.monitor.s1.1ab3ddee") == true)
        XCTAssertFalse(FsUtil.isFile(legacySameSlug), "same-slug legacy plist must be removed")
        XCTAssertTrue(FsUtil.isFile(legacyOtherSlug), "other-slug legacy plist must stay")
        XCTAssertTrue(FsUtil.isFile(current), "current-label plist must stay")
    }

    func testCleanupLegacyAgentNoResidue() {
        var commands: [[String]] = []
        let cleaned = LaunchAgent.cleanupLegacyAgent(
            currentLabel: "com.amas.herdr.dopa.monitor.s1.1ab3ddee",
            homeDir: NSTemporaryDirectory() + "herdr-dopa-legacy-absent-\(UUID().uuidString)",
            run: { cmd in
                commands.append(cmd)
                return (0, "")
            })
        XCTAssertFalse(cleaned)
        XCTAssertTrue(commands.isEmpty, "no residue means no launchctl calls")
    }

    // MARK: - data dir migration (herdr-dopa -> herdr-dopa-monitor)

    /// Hermetic fixture: a temp home with legacy `herdr-dopa/<slug>` dirs
    /// (config.json + state.json + monitor.lock, and log files) and the
    /// LAPaths the current layout resolves to.
    private func makeMigrationFixture(
        legacyExists: Bool, currentExists: Bool
    ) throws -> (home: String, current: LAPaths, slug: String) {
        let home = NSTemporaryDirectory() + "herdr-dopa-monitor-migrate-\(UUID().uuidString)"
        let slug = "s1.1ab3ddee"
        let label = LaunchAgent.BASE_LABEL + "." + slug
        let current = LAPaths(
            label: label,
            configDir: home + "/Library/Application Support/herdr-dopa-monitor/" + slug,
            stateDir: home + "/Library/Application Support/herdr-dopa-monitor/" + slug,
            logDir: home + "/Library/Logs/herdr-dopa-monitor/" + slug,
            plist: home + "/Library/LaunchAgents/\(label).plist")
        if legacyExists {
            let legacySupport = LaunchAgent.legacySupportDir(homeDir: home, slug: slug)
            let legacyLogs = LaunchAgent.legacyLogDir(homeDir: home, slug: slug)
            FsUtil.mkdirp(legacySupport)
            FsUtil.mkdirp(legacyLogs)
            try #"{"armed":false,"poll_seconds":9}"#.write(
                toFile: legacySupport + "/config.json", atomically: true, encoding: .utf8)
            try #"{"monitor_state":"off"}"#.write(
                toFile: legacySupport + "/state.json", atomically: true, encoding: .utf8)
            FileManager.default.createFile(
                atPath: legacySupport + "/monitor.lock", contents: nil)
            try "old log\n".write(
                toFile: legacyLogs + "/monitor.out.log", atomically: true, encoding: .utf8)
        }
        if currentExists {
            FsUtil.mkdirp(current.configDir)
            try #"{"armed":true}"#.write(
                toFile: current.configDir + "/config.json", atomically: true, encoding: .utf8)
            FsUtil.mkdirp(current.logDir)
            try "new log\n".write(
                toFile: current.logDir + "/monitor.out.log", atomically: true, encoding: .utf8)
        }
        return (home, current, slug)
    }

    /// Legacy-only: install/daemon startup moves the whole legacy slug dirs
    /// (config + state + lock together, and the log dir) to the new layout.
    func testMigrateMovesLegacyDirsWhenCurrentMissing() throws {
        let fixture = try makeMigrationFixture(legacyExists: true, currentExists: false)
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }

        let moved = LaunchAgent.migrateLegacyDataDirs(
            current: fixture.current, homeDir: fixture.home, log: { _ in })

        XCTAssertTrue(moved)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: LaunchAgent.legacySupportDir(homeDir: fixture.home, slug: fixture.slug)),
            "legacy support dir must be gone after the move")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: LaunchAgent.legacyLogDir(homeDir: fixture.home, slug: fixture.slug)),
            "legacy log dir must be gone after the move")
        let cfg = fixture.current.configDir + "/config.json"
        XCTAssertTrue(FsUtil.isFile(cfg), "config.json must arrive in the new dir")
        XCTAssertEqual(try String(contentsOfFile: cfg, encoding: .utf8),
                       #"{"armed":false,"poll_seconds":9}"#)
        XCTAssertTrue(FsUtil.isFile(fixture.current.configDir + "/state.json"))
        XCTAssertTrue(FsUtil.isFile(fixture.current.configDir + "/monitor.lock"))
        XCTAssertTrue(FsUtil.isFile(fixture.current.logDir + "/monitor.out.log"))

        // Idempotent: a second run finds no legacy dirs and moves nothing.
        XCTAssertFalse(LaunchAgent.migrateLegacyDataDirs(
            current: fixture.current, homeDir: fixture.home, log: { _ in }))
        XCTAssertTrue(FsUtil.isFile(cfg), "data survives the second run")
    }

    /// Both exist: the current dirs win, the legacy dirs are kept untouched
    /// (never merged, never deleted).
    func testMigrateKeepsLegacyWhenBothExist() throws {
        let fixture = try makeMigrationFixture(legacyExists: true, currentExists: true)
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }

        let moved = LaunchAgent.migrateLegacyDataDirs(
            current: fixture.current, homeDir: fixture.home, log: { _ in })

        XCTAssertFalse(moved)
        XCTAssertEqual(try String(
            contentsOfFile: fixture.current.configDir + "/config.json", encoding: .utf8),
                       #"{"armed":true}"#,
                       "current config must win")
        XCTAssertEqual(try String(
            contentsOfFile: fixture.current.logDir + "/monitor.out.log", encoding: .utf8),
                       "new log\n",
                       "current log must win")
        XCTAssertTrue(FsUtil.isFile(
            LaunchAgent.legacySupportDir(homeDir: fixture.home, slug: fixture.slug)
                + "/config.json"),
            "legacy config must be preserved for manual recovery")
        XCTAssertTrue(FsUtil.isFile(
            LaunchAgent.legacyLogDir(homeDir: fixture.home, slug: fixture.slug)
                + "/monitor.out.log"),
            "legacy log must be preserved for manual recovery")
    }

    /// No legacy dirs at all: nothing happens, nothing is created.
    func testMigrateNoLegacyIsNoop() throws {
        let fixture = try makeMigrationFixture(legacyExists: false, currentExists: false)
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }

        XCTAssertFalse(LaunchAgent.migrateLegacyDataDirs(
            current: fixture.current, homeDir: fixture.home, log: { _ in }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.current.configDir))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.current.logDir))
    }

    /// A failed move (current parent path is a regular file) reports
    /// .failed, keeps the legacy dir intact, and never falls back to it.
    func testMigrateFailedMoveKeepsLegacyIntact() throws {
        let home = NSTemporaryDirectory() + "herdr-dopa-monitor-migrate-fail-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: home) }
        let legacy = home + "/legacy-data"
        FsUtil.mkdirp(legacy)
        try "x".write(toFile: legacy + "/config.json", atomically: true, encoding: .utf8)
        // A regular file where the current dir's parent should be makes
        // moveItem (and createDirectory) fail.
        let blocker = home + "/blocker"
        try "file".write(toFile: blocker, atomically: true, encoding: .utf8)

        let outcome = LaunchAgent.migrateSessionDataDir(
            legacy: legacy, current: blocker + "/current", log: { _ in })

        guard case .failed = outcome else {
            return XCTFail("expected .failed, got \(outcome)")
        }
        XCTAssertTrue(FsUtil.isFile(legacy + "/config.json"),
                      "a failed move must not destroy legacy data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: blocker + "/current"))
    }

    /// The env-pinned HERDR_DOPA_CONFIG_DIR (what the plist pins for the
    /// daemon) wins over the computed layout as the migration target.
    func testMigrateHonorsPinnedConfigDir() throws {
        let fixture = try makeMigrationFixture(legacyExists: true, currentExists: false)
        defer { try? FileManager.default.removeItem(atPath: fixture.home) }
        let pinned = fixture.home + "/pinned-config"
        Env.set("HERDR_DOPA_CONFIG_DIR", pinned)

        XCTAssertTrue(LaunchAgent.migrateLegacyDataDirs(
            current: fixture.current, homeDir: fixture.home, log: { _ in }))
        XCTAssertTrue(FsUtil.isFile(pinned + "/config.json"),
                      "config must land in the pinned dir")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.current.configDir),
                       "computed config dir must stay untouched when a pin wins")
    }
}
