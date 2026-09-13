import XCTest
@testable import herdr_dopa

/// Unit tests for config load/save/validate/env-overrides (isolated config
/// dir via HERDR_DOPA_CONFIG_DIR).
final class ConfigTests: XCTestCase {

    var tmpDir: String = ""
    var savedEnv: [String: String?] = [:]

    override func setUp() {
        super.setUp()
        tmpDir = NSTemporaryDirectory() + "herdr-dopa-config-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: tmpDir, withIntermediateDirectories: true)
        for key in ["HERDR_DOPA_CONFIG_DIR", "HERDR_DOPA_STATE_DIR",
                    "HERDR_DOPA_POLL_SECONDS", "HERDR_BIN_PATH", "DOPA_BIN"] {
            savedEnv[key] = Env.get(key)
        }
        Env.set("HERDR_DOPA_CONFIG_DIR", tmpDir)
        Env.set("HERDR_DOPA_STATE_DIR", tmpDir)
        for key in ["HERDR_DOPA_POLL_SECONDS", "HERDR_BIN_PATH", "DOPA_BIN"] {
            Env.set(key, nil)
        }
    }

    override func tearDown() {
        for (key, value) in savedEnv {
            Env.set(key, value)
        }
        try? FileManager.default.removeItem(atPath: tmpDir)
        super.tearDown()
    }

    func testDefaultsWhenMissing() {
        let cfg = Config.loadResolved()
        XCTAssertEqual(cfg["armed"] as? Bool, true)
        XCTAssertEqual(cfg["poll_seconds"] as? Double, 5.0)
        XCTAssertEqual(cfg["keep_display_on"] as? Bool, false)
        XCTAssertEqual(cfg["stop_on_lid_close"] as? Bool, false)
        XCTAssertTrue((cfg["dopa_bin"] as? String ?? "").contains("dopa"))
    }

    func testSaveLoadRoundtrip() throws {
        var cfg = Config.defaultConfig()
        cfg["poll_seconds"] = 7.5
        cfg["keep_display_on"] = true
        try Config.saveConfigFile(cfg)
        let back = Config.loadResolved()
        XCTAssertEqual(back["poll_seconds"] as? Double, 7.5)
        XCTAssertEqual(back["keep_display_on"] as? Bool, true)
    }

    func testUnknownKeysDropped() throws {
        let path = Config.configPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["armed": false, "bogus_key": 1])
            .write(to: URL(fileURLWithPath: path))
        let cfg = Config.loadResolved()
        XCTAssertEqual(cfg["armed"] as? Bool, false)
        XCTAssertNil(cfg["bogus_key"])
    }

    func testLegacyGraceKeysIgnored() throws {
        // Older installs still carry grace keys in config.json; they must be
        // ignored (unknown keys are dropped) and never resurrected on save.
        let path = Config.configPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try JSONSerialization.data(
            withJSONObject: ["poll_seconds": 3.0,
                             "start_grace_seconds": 5.0,
                             "stop_grace_seconds": 30.0])
            .write(to: URL(fileURLWithPath: path))
        let cfg = Config.loadResolved()
        XCTAssertEqual(cfg["poll_seconds"] as? Double, 3.0)
        XCTAssertNil(cfg["start_grace_seconds"])
        XCTAssertNil(cfg["stop_grace_seconds"])
        try Config.saveConfigFile(cfg)
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(raw.contains("grace"))
    }

    func testCorruptFileGivesDefaults() throws {
        let path = Config.configPath()
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try "{broken".write(toFile: path, atomically: true, encoding: .utf8)
        let cfg = Config.loadResolved()
        XCTAssertEqual(cfg["poll_seconds"] as? Double, 5.0)
    }

    func testValidateClamps() {
        let out = Config.validate([
            "poll_seconds": 0.1,
            "armed": "off",
            "keep_display_on": "yes",
        ])
        XCTAssertEqual(out["poll_seconds"] as? Double, 1.0)
        XCTAssertEqual(out["armed"] as? Bool, false)
        XCTAssertEqual(out["keep_display_on"] as? Bool, true)
    }

    func testValidateBoolStrings() {
        XCTAssertEqual(Config.toBool("1" as Any?, true), true)
        XCTAssertEqual(Config.toBool("no" as Any?, true), false)
        XCTAssertEqual(Config.toBool("disarmed" as Any?, true), false)
        XCTAssertEqual(Config.toBool("junk" as Any?, false), false)
        XCTAssertEqual(Config.toBool("junk" as Any?, true), true)
        XCTAssertEqual(Config.toBool(nil, false), false)
    }

    func testEnvOverrides() {
        Env.set("HERDR_DOPA_POLL_SECONDS", "9")
        Env.set("DOPA_BIN", "/tmp/custom/dopa")
        let cfg = Config.loadResolved()
        XCTAssertEqual(cfg["poll_seconds"] as? Double, 9.0)
        XCTAssertEqual(cfg["dopa_bin"] as? String, "/tmp/custom/dopa")
    }

    func testEnvHerdrBinOverride() {
        Env.set("HERDR_BIN_PATH", "/opt/herdr/bin/herdr")
        let cfg = Config.loadResolved()
        XCTAssertEqual(Config.herdrBinPath(cfg), "/opt/herdr/bin/herdr")
    }

    func testPartialSaveKeepsDefaults() throws {
        try Config.saveConfigFile(["armed": false])
        let cfg = Config.loadResolved()
        XCTAssertEqual(cfg["armed"] as? Bool, false)
        XCTAssertEqual(cfg["poll_seconds"] as? Double, 5.0)
    }
}
