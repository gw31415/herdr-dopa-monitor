import Foundation

/// LaunchAgent plist rendering and installation. Ported from `guard.py`'s
/// install helpers, with the Swift binary replacing the Python interpreter.

func templatePath() -> String {
    pluginRoot() + "/launchagents/com.amas.herdr.dopa.monitor.plist.template"
}

/// Absolute herdr path to bake into the LaunchAgent (minimal PATH there).
func resolveHerdrBinOrExit() -> String {
    let herdr = Env.get("HERDR_BIN_PATH") ?? which("herdr")
    guard let herdr else {
        FileHandle.standardError.write((
            "Could not find herdr on PATH. Run `herdr-dopa-monitor install` from a "
            + "shell that has herdr, or set HERDR_BIN_PATH to the absolute binary.\n"
        ).data(using: .utf8)!)
        exit(1)
    }
    return FsUtil.realPath(herdr) ?? herdr
}

/// The guard binary to run from the LaunchAgent: prefer the running
/// executable when it already lives in this plugin's .build tree, else the
/// release artifact under the plugin root (HERDR_PLUGIN_ROOT or discovered),
/// else the running executable.
func resolveGuardBin() -> String {
    let exeURL = Bundle.main.executableURL
    let exeRaw = exeURL?.path ?? CommandLine.arguments.first ?? ""
    let exe = FsUtil.realPath(exeRaw) ?? exeRaw
    let root = pluginRoot()
    let releaseCandidate = root + "/.build/release/herdr-dopa-monitor"
    if let releaseReal = FsUtil.realPath(releaseCandidate), exe == releaseReal {
        return exe
    }
    if exe.hasPrefix(root + "/.build/") {
        return exe // running a debug build of this checkout
    }
    if FsUtil.isExecutableFile(releaseCandidate) {
        return FsUtil.realPath(releaseCandidate) ?? releaseCandidate
    }
    return exe
}

func renderPlist(homeDir: String, p: LAPaths) throws -> String {
    let template = try String(contentsOfFile: templatePath(), encoding: .utf8)
    let socketPath = Env.get("HERDR_SOCKET_PATH") ?? ""
    return template
        .replacingOccurrences(of: "__LABEL__", with: p.label)
        .replacingOccurrences(of: "__GUARD_BIN__", with: resolveGuardBin())
        .replacingOccurrences(of: "__PLUGIN_ROOT__", with: pluginRoot())
        .replacingOccurrences(of: "__HOME__", with: homeDir)
        .replacingOccurrences(of: "__CONFIG_DIR__", with: p.configDir)
        .replacingOccurrences(of: "__STATE_DIR__", with: p.stateDir)
        .replacingOccurrences(of: "__LOG_DIR__", with: p.logDir)
        .replacingOccurrences(of: "__PLIST__", with: p.plist)
        .replacingOccurrences(of: "__HERDR_BIN__", with: resolveHerdrBinOrExit())
        .replacingOccurrences(of: "__HERDR_SOCKET__", with: socketPath)
}

/// Install (or refresh) this session's LaunchAgent. Leaves it registered but
/// stopped; `sync` starts it when agents exist.
@discardableResult
func doInstall() throws -> LAPaths {
    let homeDir = NSHomeDirectory()
    let p = try LaunchAgent.paths(homeDir: homeDir)
    // Pin the resolved per-session dirs so config/state land in the right
    // place for the migration below, the seeding, and any subprocess
    // spawned after this.
    Env.set("HERDR_DOPA_CONFIG_DIR", p.configDir)
    Env.set("HERDR_DOPA_STATE_DIR", p.stateDir)

    // One-time data-dir migration (herdr-dopa -> herdr-dopa-monitor), before
    // any mkdirp/seed below creates the new dirs: it only moves when the new
    // dir is still missing, so a re-install never merges or deletes data.
    if LaunchAgent.migrateLegacyDataDirs(
        current: p, homeDir: homeDir, log: { print("[install] \($0)") })
    {
        print("[install] migrated legacy data dirs to the herdr-dopa-monitor layout.")
    }

    FsUtil.mkdirp(p.logDir)
    FsUtil.mkdirp(p.configDir)
    FsUtil.mkdirp(p.stateDir)
    FsUtil.mkdirp(homeDir + "/Library/LaunchAgents")

    // Seed config.json with defaults if absent. Never overwrite (user edits).
    if !FsUtil.isFile(Config.configPath()) {
        try? Config.saveConfigFile(Config.defaultConfig())
        print("[install] wrote default config: \(Config.configPath())")
    }

    // Migration from the pre-rename label base (com.herdr.dopa.monitor.*):
    // boot out and delete this session's stale legacy agent, if any. Same
    // slug only — other sessions are never touched.
    if LaunchAgent.cleanupLegacyAgent(
        currentLabel: p.label,
        homeDir: homeDir,
        log: { print("[install] \($0)") })
    {
        print("[install] migrated to new label: \(p.label)")
    }

    try renderPlist(homeDir: homeDir, p: p).write(
        toFile: p.plist, atomically: true, encoding: .utf8)
    print("[install] wrote plist: \(p.plist)")

    _ = LaunchAgent.run(["launchctl", "bootout", LaunchAgent.domain(), p.plist])
    // A previous stop stores a persistent disabled override for this label.
    // Bootstrap of a disabled agent can fail with a generic I/O error, so
    // enable first; stop() below leaves the documented stopped state.
    _ = LaunchAgent.run(["launchctl", "enable", LaunchAgent.serviceTarget(labelName: p.label)])
    let (code, err) = LaunchAgent.run(
        ["launchctl", "bootstrap", LaunchAgent.domain(), p.plist])
    if code != 0 && !err.isEmpty {
        FileHandle.standardError.write(
            ("[install] bootstrap note (ignored if already loaded): \(err)\n")
                .data(using: .utf8)!)
    }

    LaunchAgent.stop(p.label)
    print("[install] registered LaunchAgent: \(p.label) (stopped)")
    print("[install] stdout log: \(p.logDir)/monitor.out.log")
    print("[install] stderr log: \(p.logDir)/monitor.err.log")
    print("[install] config file: \(p.configDir)/config.json")
    print("[install] state file: \(p.stateDir)/state.json")
    print("[install] verify with:")
    print("    launchctl print gui/$UID/\(p.label)")
    print("    tail -n 50 \(p.logDir)/monitor.out.log")
    print("    \(resolveGuardBin()) status")
    return p
}
