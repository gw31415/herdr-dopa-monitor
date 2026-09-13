import XCTest
@testable import herdr_dopa

/// Unit tests for session naming / LaunchAgent path helpers.
final class LaunchAgentTests: XCTestCase {

    var savedEnv: [String: String?] = [:]
    let trackedKeys = ["HERDR_SESSION_NAME", "HERDR_SESSION",
                       "HERDR_PLUGIN_CONFIG_DIR", "HERDR_PLUGIN_STATE_DIR"]

    override func setUp() {
        super.setUp()
        for key in trackedKeys {
            savedEnv[key] = Env.get(key)
        }
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
        XCTAssertTrue(try LaunchAgent.label().hasPrefix("com.herdr.dopa.monitor."))
    }

    func testPathsLayout() throws {
        Env.set("HERDR_SESSION_NAME", "s1")
        Env.set("HERDR_PLUGIN_CONFIG_DIR", nil)
        Env.set("HERDR_PLUGIN_STATE_DIR", nil)
        let p = try LaunchAgent.paths(homeDir: "/tmp/fakehome")
        XCTAssertTrue(p.plist.hasPrefix("/tmp/fakehome"))
        XCTAssertTrue((p.plist as NSString).lastPathComponent
            .hasPrefix("com.herdr.dopa.monitor."))
        XCTAssertTrue(p.logDir.contains("herdr-dopa"))
        XCTAssertTrue(p.configDir.contains("herdr-dopa"))
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
        let target = LaunchAgent.serviceTarget(labelName: "com.herdr.dopa.monitor.x")
        XCTAssertEqual(target, "gui/\(getuid())/com.herdr.dopa.monitor.x")
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
}
