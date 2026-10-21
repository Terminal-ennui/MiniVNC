import os

/// Connection diagnostics in the unified log, e.g.
/// `log show --last 1h --predicate 'subsystem == "io.github.terminal-ennui.MiniVNC"'`.
/// Never logs passwords or clipboard contents.
enum Log {
    static let transport = Logger(subsystem: "io.github.terminal-ennui.MiniVNC", category: "transport")
    static let session = Logger(subsystem: "io.github.terminal-ennui.MiniVNC", category: "session")
}
