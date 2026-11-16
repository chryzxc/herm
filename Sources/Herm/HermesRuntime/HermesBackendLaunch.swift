import Foundation

/// Launches `hermes serve` under a small `/bin/sh` supervisor tied to Herm's lifetime.
///
/// macOS has no parent-death signal, so Herm keeps the write end of the supervisor's
/// stdin. The kernel closes it whenever Herm exits, a crash or SIGKILL included, and the
/// supervisor then ends the backend's process group (the backend and its MCP servers).
enum HermesBackendLaunch {
    static let serveCommand = ["/usr/bin/env", "hermes", "serve", "--host", "127.0.0.1", "--port", "0"]

    /// `stop` is trapped before anything starts: a TERM from the watcher (Herm already gone)
    /// or from `terminate()` during startup must never hit the default action, which would
    /// kill this shell and orphan the backend's process group.
    static let supervisor = """
        exec 3<&0 </dev/null
        stop() {
            trap : TERM INT HUP
            backend=${backend:-$!}
            [ -n "$backend" ] || exit "${1:-143}"
            kill "$watcher" 2>/dev/null
            kill -TERM -- "-$backend" 2>/dev/null
            { sleep 5; kill -KILL -- "-$backend"; } >/dev/null 2>&1 &
            timer=$!
            wait "$backend" 2>/dev/null
            attempt=0
            while kill -0 -- "-$backend" 2>/dev/null && [ "$attempt" -lt 50 ]; do
                sleep 0.1
                attempt=$((attempt + 1))
            done
            kill -KILL -- "-$backend" 2>/dev/null
            kill "$timer" 2>/dev/null
            exit "${1:-143}"
        }
        trap stop TERM INT HUP
        set -m
        "$@" 3<&- &
        backend=$!
        set +m
        { while read -r _; do :; done; kill -TERM $$; } <&3 >/dev/null 2>&1 &
        watcher=$!
        exec 3<&-
        wait "$backend"
        stop "$?"
        """

    static func process(command: [String] = serveCommand) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", supervisor, "herm-backend"] + command
        process.standardInput = Pipe()
        return process
    }
}
