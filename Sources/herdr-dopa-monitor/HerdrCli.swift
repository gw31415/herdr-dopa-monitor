import Foundation

/// Best-effort herdr CLI integration: notifications and pane report-metadata.
/// Everything here is fire-and-forget: when HERDR_BIN_PATH is not set (or the
/// call fails) it silently does nothing, so the monitor never depends on the
/// herdr UI being reachable. Raw socket JSON is deliberately not used — the
/// CLI path via HERDR_BIN_PATH is the portable plugin API.
enum HerdrCli {
    static let sourceID = "dopa-macos"

    /// herdr binary for UI calls: HERDR_BIN_PATH only (set by herdr for plugin
    /// commands and panes). Missing -> caller skips silently.
    static func uiBin() -> String? {
        Env.getNonEmpty("HERDR_BIN_PATH")
    }

    /// Pane id for report-metadata: HERDR_PANE_ID, else the pane/focused_pane
    /// inside HERDR_PLUGIN_CONTEXT_JSON.
    static func resolvePaneID() -> String? {
        if let paneID = Env.getNonEmpty("HERDR_PANE_ID") {
            return paneID
        }
        guard let raw = Env.getNonEmpty("HERDR_PLUGIN_CONTEXT_JSON"),
              let data = raw.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let context = parsed as? [String: Any] else {
            return nil
        }
        if let pane = context["pane"] as? [String: Any],
           let id = pane["id"] as? String, !id.isEmpty {
            return id
        }
        if let focused = context["focused_pane"] as? [String: Any],
           let id = focused["id"] as? String, !id.isEmpty {
            return id
        }
        if let id = context["pane_id"] as? String, !id.isEmpty {
            return id
        }
        return nil
    }

    /// `herdr notification show TITLE --body BODY` (best-effort).
    @discardableResult
    static func notify(title: String, body: String?) -> Bool {
        guard let bin = uiBin() else { return false }
        var argv = [bin, "notification", "show", title]
        if let body, !body.isEmpty {
            argv += ["--body", body]
        }
        return ProcRunner.capture(argv, timeout: 10) != nil
    }

    /// `herdr pane report-metadata <pane> --source dopa-macos ...`
    /// (best-effort; skipped when no pane id resolves). A TTL keeps stale
    /// guard metadata from lingering if the daemon dies.
    @discardableResult
    static func reportMetadata(paneID: String? = nil,
                               title: String? = nil,
                               tokens: [(name: String, value: String)],
                               ttlMs: Int = 600_000) -> Bool {
        guard let bin = uiBin() else { return false }
        let pane = paneID ?? resolvePaneID() ?? ""
        guard !pane.isEmpty else { return false }
        var argv = [bin, "pane", "report-metadata", pane, "--source", sourceID]
        if let title, !title.isEmpty {
            argv += ["--title", title]
        }
        for token in tokens {
            argv += ["--token", "\(token.name)=\(token.value)"]
        }
        argv += ["--ttl-ms", String(ttlMs)]
        return ProcRunner.capture(argv, timeout: 10) != nil
    }

    // MARK: - Daemon events -> notification + pane metadata

    /// Push a monitor transition into the herdr UI. Called from the daemon
    /// loop; never throws and never blocks for long.
    static func emitDaemonEvent(_ event: MonitorUiEvent, ctx: MonitorCtx, armed: Bool) {
        guard uiBin() != nil else { return }
        let guardToken = armed ? "armed" : "paused"
        switch event {
        case .started:
            notify(title: "dopa guard started",
                   body: "Monitor running (poll \(fmtSeconds(DEFAULT_POLL_SECONDS))s).")
        case .guardStarted(let pid):
            notify(title: "dopa guard: keeping Mac awake",
                   body: pid.map { "Agents working; owned dopa session pid \($0)." }
                       ?? "Agents working; owned dopa session started.")
        case .guardEnded:
            notify(title: "dopa guard: idle",
                   body: "Agents idle; owned dopa session ended.")
        case .errored(let reason):
            notify(title: "dopa guard: error",
                   body: reason ?? "see logs")
        case .stopped:
            notify(title: "dopa guard stopped", body: nil)
        }
        let state: String
        switch event {
        case .started: state = "starting"
        case .guardStarted: state = "guarding"
        case .guardEnded: state = "idle"
        case .errored: state = "error"
        case .stopped: state = "off"
        }
        reportMetadata(
            title: "dopa sleep guard",
            tokens: [
                ("guard", guardToken),
                ("dopa", state),
                ("agents", ctx.agentCount >= 0 ? String(ctx.agentCount) : "?"),
            ])
    }
}
