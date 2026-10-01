import Libavutil

/// libav*'s own stderr chatter, for a process that owns its terminal.
///
/// A host never touches this — its stderr goes nowhere a user sees. The CLI
/// does, and there the muxer's per-session warnings ("Timestamps are unset",
/// "codec frame size is not set") bury the one line a user ran it for, while
/// saying nothing the engine does not already account for. Errors still
/// print; `verbose` restores everything.
package enum LibraryLogLevel {
    package static func set(verbose: Bool) {
        av_log_set_level(verbose ? AV_LOG_INFO : AV_LOG_ERROR)
    }
}
