import Foundation
import Darwin

/// Small shared utilities: live environment access (getenv/setenv so tests can
/// mutate it), TTY/ANSI detection, atomic JSON writes, PATH lookup, SHA-1
/// (pure Swift; no CryptoKit dependency), and plugin-root discovery.

enum Env {
    /// getenv-backed read: reflects setenv/unsetenv calls in this process
    /// (ProcessInfo.environment is cached and would not).
    static func get(_ key: String) -> String? {
        guard let raw = getenv(key) else { return nil }
        return String(cString: raw)
    }

    /// Python's "set and non-empty" idiom used for env overrides.
    static func getNonEmpty(_ key: String) -> String? {
        guard let raw = getenv(key) else { return nil }
        let value = String(cString: raw)
        return value.isEmpty ? nil : value
    }

    static func set(_ key: String, _ value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }

    /// setdefault semantics: only set when currently unset.
    @discardableResult
    static func setDefault(_ key: String, _ value: String) -> String {
        if let existing = get(key), !existing.isEmpty {
            return existing
        }
        setenv(key, value, 1)
        return value
    }
}

enum Term {
    /// True when stdout may carry ANSI (TTY, no NO_COLOR, TERM != dumb).
    static func styled() -> Bool {
        guard isatty(STDOUT_FILENO) == 1 else { return false }
        if Env.get("NO_COLOR") != nil { return false }
        if Env.get("TERM") == "dumb" { return false }
        return true
    }
}

struct Style {
    let on: Bool

    func wrap(_ code: String, _ text: String) -> String {
        on ? "\u{1b}[\(code)m\(text)\u{1b}[0m" : text
    }

    func bold(_ text: String) -> String { wrap("1", text) }
    func dim(_ text: String) -> String { wrap("2", text) }
    func green(_ text: String) -> String { wrap("32", text) }
    func yellow(_ text: String) -> String { wrap("33", text) }
    func red(_ text: String) -> String { wrap("31", text) }
    func cyan(_ text: String) -> String { wrap("36", text) }
}

enum FsUtil {
    static func realPath(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        guard realpath(path, &buffer) != nil else { return nil }
        return String(cString: buffer)
    }

    static func isFile(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFREG
    }

    static func isExecutableFile(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }

    static func mkdirp(_ path: String) {
        try? FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
    }

    /// Atomic JSON write: temp file in the same directory, then rename(2).
    static func atomicWriteJSON(path: String, object: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let dir = (path as NSString).deletingLastPathComponent
        if !dir.isEmpty { mkdirp(dir) }
        let tmp = path + ".tmp"
        try data.write(to: URL(fileURLWithPath: tmp))
        if rename(tmp, path) != 0 {
            throw NSError(
                domain: "herdr-dopa", code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey:
                    "rename(\(tmp), \(path)) failed: \(String(cString: strerror(errno)))"])
        }
    }

    static func readTextFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }
}

/// `shutil.which` equivalent: search PATH for an executable regular file.
func which(_ name: String) -> String? {
    if name.contains("/") {
        return FsUtil.isExecutableFile(name) ? name : nil
    }
    let pathEnv = Env.get("PATH") ?? ""
    let dirs = pathEnv.split(separator: ":", omittingEmptySubsequences: false)
    for dir in dirs {
        let candidate = dir.isEmpty ? name : "\(dir)/\(name)"
        if FsUtil.isExecutableFile(candidate) {
            return candidate
        }
    }
    return nil
}

// MARK: - Plugin root

/// The plugin checkout root: HERDR_PLUGIN_ROOT when injected by herdr, else the
/// nearest ancestor directory (of the running binary, then cwd) that contains
/// herdr-plugin.toml.
func pluginRoot() -> String {
    if let injected = Env.get("HERDR_PLUGIN_ROOT"), !injected.isEmpty {
        return injected
    }
    let exe = FsUtil.realPath(
        Bundle.main.executableURL?.path ?? CommandLine.arguments.first ?? ".")
    if var dir = exe.map({ exePath -> String in
        URL(fileURLWithPath: exePath).deletingLastPathComponent().path
    }) {
        for _ in 0..<10 {
            if FsUtil.isFile(dir + "/herdr-plugin.toml") { return dir }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
    }
    let cwd = FileManager.default.currentDirectoryPath
    if FileManager.default.fileExists(atPath: cwd + "/herdr-plugin.toml") {
        return cwd
    }
    return cwd
}

// MARK: - SHA-1 (pure Swift)

/// Minimal SHA-1 used for short session-slug hashes. Not used for anything
/// security-sensitive (only as a stable non-cryptographic fingerprint).
enum SHA1 {
    static func hex(_ message: String) -> String {
        var h: (UInt32, UInt32, UInt32, UInt32, UInt32) =
            (0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0)
        var data = Array(message.utf8)
        let bitLength = UInt64(data.count) * 8
        data.append(0x80)
        while data.count % 64 != 56 { data.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((bitLength >> UInt64(shift)) & 0xFF))
        }

        var w = [UInt32](repeating: 0, count: 80)
        for chunkStart in stride(from: 0, to: data.count, by: 64) {
            for i in 0..<16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(data[base]) << 24) | (UInt32(data[base + 1]) << 16)
                    | (UInt32(data[base + 2]) << 8) | UInt32(data[base + 3])
            }
            for i in 16..<80 {
                let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (x << 1) | (x >> 31)
            }

            var (a, b, c, d, e) = h
            for i in 0..<80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0..<20:
                    f = (b & c) | ((~b) & d); k = 0x5A827999
                case 20..<40:
                    f = b ^ c ^ d; k = 0x6ED9EBA1
                case 40..<60:
                    f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d; k = 0xCA62C1D6
                }
                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = temp
            }
            h.0 = h.0 &+ a; h.1 = h.1 &+ b; h.2 = h.2 &+ c
            h.3 = h.3 &+ d; h.4 = h.4 &+ e
        }

        func pad(_ v: UInt32) -> String {
            let hex = String(v, radix: 16)
            return String(repeating: "0", count: 8 - hex.count) + hex
        }
        return pad(h.0) + pad(h.1) + pad(h.2) + pad(h.3) + pad(h.4)
    }
}
