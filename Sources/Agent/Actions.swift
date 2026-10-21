import Foundation

// Actions: saved one-tap commands per Mac ("Restart Ollama", "git pull and build"). They are defined on
// the Mac itself with `vitals-agent action add NAME COMMAND`, and the page can only run one by its id:
// it never sends a command line, so a stolen page or a forged request can at most run what you saved.
// Each request passes Control.gate (running or stopping is a change), so app control must be on and the
// device named. A run is `/bin/zsh -lc COMMAND` as you, in your home folder, with no input, in its own
// process group so Stop reaches whatever it started; one run per action at a time, ten minutes at most
// unless the action says otherwise. Its output is kept (the last 64 KB) for the page, never logged:
// the log says only who ran what, the exit code and how long it took.

enum Actions {
    static let file = supportDir.appendingPathComponent("actions.json")
    /// The last run of each action, so the result is still there after the server has gone idle and exited.
    static let lastFile = supportDir.appendingPathComponent("actions-last.json")
    static let defaultTimeout = 600.0
    static let outputCap = 65536
    /// What the list sends of an output it isn't showing in full: enough to glance at, cheap to poll.
    static let glance = 4096

    struct Action: Codable {
        var id: String, name: String, command: String
        var timeout: Double? = nil          // seconds; nil for the default ten minutes
    }

    struct Result: Codable {
        var t: Double                       // when it finished
        var exit: Int32                     // 128 + the signal when one ended it, as a shell reports it
        var seconds: Double
        var outputTail: String
        var why: String? = nil              // "stopped from iPhone", "timed out after 10 min"
        var device: String? = nil
    }

    static func load() -> [Action] { (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Action].self, from: $0) } ?? [] }

    static func save(_ list: [Action]) -> Bool { write(list, to: file) }

    private static func write<T: Encodable>(_ v: T, to url: URL) -> Bool {
        try? FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(v),
              FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        chmod(url.path, 0o600)              // createFile keeps an existing file's mode
        return true
    }

    /// "restart-ollama" from "Restart Ollama": stable, so a page open across an edit still means the same one.
    static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber) ? String($0) : "-" }.joined()
        return s.split(separator: "-").joined(separator: "-")
    }

    // MARK: runs (main queue only)

    private static var runs: [String: Run] = [:]
    private static var last: [String: Result] = (try? Data(contentsOf: lastFile)).flatMap { try? JSONDecoder().decode([String: Result].self, from: $0) } ?? [:]

    /// Keeps the server from exiting while something runs (WebServer.housekeeping).
    static var busy: Bool { !runs.isEmpty }

    // MARK: HTTP: GET /actions, POST /actions/run and /actions/stop with an id as the body

    private static var refusals: [String: Date] = [:]

    /// Status and JSON body. Called by WebServer.route; the gate is checked here on every call.
    static func handle(_ r: Request) -> (Int, String) {
        let device: String
        switch Control.gate(r, change: r.method == "POST") {
        case .off: return (404, #"{"error":"off"}"#)
        case .refused(let why):
            // Once per address and reason every ten minutes, so a polling page doesn't flood the log.
            let from = r.headers["x-forwarded-for"] ?? "this Mac", key = from + why
            if refusals[key].map({ Date().timeIntervalSince($0) > 600 }) ?? true {
                refusals[key] = Date()
                Control.record("Blocked an action request from \(from) (\(r.headers["tailscale-user-login"] ?? "no account")): \(why)", "refused")
            }
            return (403, json(["error": "This device isn't allowed to run actions on this Mac."]))
        case .allowed(let d): device = d
        }
        let list = load()
        if r.path == "/actions" {
            let full = r.query["output"]
            return (200, json(list.map { row($0, full: $0.id == full) }))
        }
        let id = r.body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let a = list.first(where: { $0.id == id }) else { return (404, json(["error": "There's no such action on this Mac."])) }
        if r.path == "/actions/stop" {
            guard let run = runs[id] else { return (409, json(["error": "\(a.name) isn't running."])) }
            run.stop("stopped from \(device)")
            return (200, json(row(a, full: false)))
        }
        guard runs[id] == nil else { return (409, json(["error": "\(a.name) is already running."])) }
        if let err = start(a, device: device) { return (409, json(["error": err])) }
        return (200, json(row(a, full: false)))
    }

    struct Row: Encodable {
        var id: String, name: String
        var running: Bool
        var seconds: Double?                // so far, while running (the Mac's clock, not the phone's)
        var output: String?                 // so far, while running
        var last: Result?
    }

    private static func row(_ a: Action, full: Bool) -> Row {
        func cut(_ s: String) -> String { full || s.utf8.count <= glance ? s : String(decoding: s.utf8.suffix(glance), as: UTF8.self) }
        let run = runs[a.id]
        var l = last[a.id]
        if let tail = l?.outputTail { l?.outputTail = cut(tail) }
        return Row(id: a.id, name: a.name, running: run != nil, seconds: run.map { Date().timeIntervalSince($0.started) },
                   output: run.map { cut($0.text) }, last: l)
    }

    private static func start(_ a: Action, device: String) -> String? {
        let run = Run(a, device: device)
        guard run.spawn() else { return "macOS could not start \(a.name)." }
        runs[a.id] = run
        Control.record("Ran \(a.name) from \(device)")
        run.onExit = { exit, why in
            let seconds = Date().timeIntervalSince(run.started)
            runs[a.id] = nil
            last[a.id] = Result(t: Date().timeIntervalSince1970, exit: exit, seconds: seconds, outputTail: run.text, why: why, device: device)
            _ = write(last, to: lastFile)
            // The exit code and the time only: the output may hold secrets, so it never goes to the log.
            let how = why.map { "\($0), " } ?? ""
            Control.record("\(a.name) \(exit == 0 && why == nil ? "finished" : "failed"): \(how)exit \(exit) after \(F.duration(seconds))",
                           exit == 0 && why == nil ? "done" : "failed")
        }
        return nil
    }
}

/// One run of an action: zsh in a process group of its own, its output (stdout and stderr together)
/// read into a ring of the last 64 KB, a timer for the timeout, and SIGKILL 5 s after a SIGTERM it ignored.
final class Run {
    let action: Actions.Action, device: String
    let started = Date()
    var onExit: ((Int32, String?) -> Void)?
    private var pid: pid_t = 0
    private var out = Data()
    private var reader: DispatchSourceRead?
    private var exitWatch: DispatchSourceProcess?
    private var timer: DispatchSourceTimer?
    private var why: String?
    private var fd: Int32 = -1

    init(_ a: Actions.Action, device: String) { action = a; self.device = device }

    var text: String { String(decoding: out, as: UTF8.self) }

    func spawn() -> Bool {
        var pipe: [Int32] = [0, 0]
        guard Darwin.pipe(&pipe) == 0 else { return false }
        var fa: posix_spawn_file_actions_t?, attr: posix_spawnattr_t?
        posix_spawn_file_actions_init(&fa); posix_spawnattr_init(&attr)
        defer { posix_spawn_file_actions_destroy(&fa); posix_spawnattr_destroy(&attr) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, pipe[1], 1)
        posix_spawn_file_actions_adddup2(&fa, pipe[1], 2)
        posix_spawn_file_actions_addchdir_np(&fa, NSHomeDirectory())
        // CLOEXEC_DEFAULT: the child gets only stdin, stdout and stderr, never the dashboard's sockets.
        // SETPGROUP: a group of its own, so Stop reaches what the command started too. And the signals
        // back to normal: this process ignores SIGPIPE, which a child would otherwise inherit.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setsigmask(&attr, &none)
        let argv: [UnsafeMutablePointer<CChar>?] = ["/bin/zsh", "-lc", action.command].map { strdup($0) } + [nil]
        defer { for p in argv { free(p) } }
        let ok = posix_spawn(&pid, "/bin/zsh", &fa, &attr, argv, environ) == 0
        close(pipe[1])
        guard ok else { close(pipe[0]); return false }
        fd = pipe[0]
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let r = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        r.setEventHandler { [weak self] in self?.drain() }
        r.setCancelHandler { [fd] in close(fd) }
        r.resume()
        reader = r
        let x = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        x.setEventHandler { [weak self] in self?.exited() }
        x.resume()
        exitWatch = x
        let limit = action.timeout ?? Actions.defaultTimeout
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + limit)
        t.setEventHandler { [weak self] in self?.stop("timed out after \(F.duration(limit))") }
        t.resume()
        timer = t
        return true
    }

    /// Reads what is waiting, keeping only the last 64 KB.
    private func drain() {
        guard reader != nil else { return }         // closed: the number may already be someone else's
        var chunk = [UInt8](repeating: 0, count: 16384)
        while true {
            let n = read(fd, &chunk, chunk.count)
            if n > 0 {
                out.append(contentsOf: chunk[0..<n])
                if out.count > Actions.outputCap { out = Data(out.suffix(Actions.outputCap)) }
            } else {
                // End of output (or nothing more for now). At the end, stop watching: the run itself
                // finishes when zsh exits, even if something it left in the background holds the pipe.
                if n == 0 { reader?.cancel(); reader = nil }
                return
            }
        }
    }

    /// SIGTERM to the whole group, then SIGKILL 5 s later if it is still there.
    func stop(_ reason: String) {
        guard why == nil else { return }
        why = reason
        kill(-pid, SIGTERM)
        // Also after zsh is gone: something it started may have ignored the SIGTERM. The group's number
        // can't be given to a new process while any member of the group is left.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [pid] in kill(-pid, SIGKILL) }
    }

    private func exited() {
        var status: Int32 = 0
        guard waitpid(pid, &status, WNOHANG) == pid else { return }
        drain()
        reader?.cancel(); reader = nil
        exitWatch?.cancel(); exitWatch = nil
        timer?.cancel(); timer = nil
        // WIFEXITED / WTERMSIG, which Swift doesn't import: the low 7 bits are the signal, 0 for a normal exit.
        let sig = status & 0x7F
        let code = sig == 0 ? (status >> 8) & 0xFF : 128 + sig
        let done = onExit
        onExit = nil
        done?(code, why)
    }
}

// MARK: setup

/// `action add NAME COMMAND [--timeout 30m]`, `action remove NAME`, or `action` to list them.
func actionCommand() {
    var list = Actions.load()
    let words = Array(args.dropFirst())
    switch words.first {
    case "add":
        guard words.count >= 3 else { fail("vitals-agent action add \"Restart Ollama\" \"brew services restart ollama\" [--timeout 30m]") }
        let name = words[1].trimmingCharacters(in: .whitespaces), command = words[2]
        let id = Actions.slug(name)
        guard !id.isEmpty, name.count <= 60, !name.contains("\n") else { fail("Give it a short name with a letter or number in it.") }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { fail("The command is empty.") }
        var timeout: Double?
        if let t = option("--timeout") {
            guard let s = seconds(t), s >= 1, s <= 86400 else { fail("--timeout takes seconds, or minutes and hours: 90, 5m, 2h (at most a day)") }
            timeout = s
        }
        let new = Actions.Action(id: id, name: name, command: command, timeout: timeout)
        let replacing = list.contains { $0.id == id }
        if let i = list.firstIndex(where: { $0.id == id }) { list[i] = new } else { list.append(new) }      // keeps its place on the page
        guard Actions.save(list) else { fail("Could not write \(Actions.file.path)") }
        Control.record("Action \(replacing ? "changed" : "added"): \(name)")
        print("\(replacing ? "Changed" : "Added") \(name). It runs: /bin/zsh -lc \(quoted(command)), in your home folder, for at most \(F.duration(timeout ?? Actions.defaultTimeout)).")
        if Control.load() == nil { print("It shows on the dashboard once app control is on: vitals-agent control on --from iphone,macbook") }
    case "remove":
        guard words.count >= 2 else { fail("vitals-agent action remove \"Restart Ollama\"") }
        let key = words[1].lowercased()
        guard let a = list.first(where: { $0.name.lowercased() == key || $0.id == key || $0.id == Actions.slug(key) }) else {
            fail("No action called \(words[1]). Yours: " + (list.isEmpty ? "none yet" : list.map(\.name).joined(separator: ", ")))
        }
        list.removeAll { $0.id == a.id }
        guard Actions.save(list) else { fail("Could not write \(Actions.file.path)") }
        Control.record("Action removed: \(a.name)")
        print("Removed \(a.name).")
    case nil:
        if list.isEmpty { print("No actions yet. Add one: vitals-agent action add \"Restart Ollama\" \"brew services restart ollama\"") }
        for a in list {
            print("\(a.name)\(a.timeout.map { " (at most \(F.duration($0)))" } ?? "")\n    \(a.command)")
        }
        if !list.isEmpty, Control.load() == nil { print("App control is off, so the dashboard doesn't show them: vitals-agent control on --from iphone,macbook") }
    default:
        fail("vitals-agent action [add NAME COMMAND [--timeout 30m] | remove NAME]")
    }
}

/// "90" or "90s", "5m", "2h".
private func seconds(_ s: String) -> Double? {
    let unit: Double = s.hasSuffix("h") ? 3600 : s.hasSuffix("m") ? 60 : 1
    return Double(s.trimmingCharacters(in: CharacterSet(charactersIn: "hms"))).map { $0 * unit }
}

private func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
