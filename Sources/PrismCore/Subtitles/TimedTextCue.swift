import Foundation

/// One timed text cue of an embedded subtitle stream, handed to the host as
/// the demux produces it — the host-facing twin of the internal `SubtitleCue`.
///
/// Exists because the WebVTT renditions are not always the right delivery for
/// text: AVPlayer times a `SUBTITLES` rendition on its own segment schedule,
/// which is where the late-cue drift class of bugs lives, while a host that
/// draws captions itself wants the cue list on the player's own clock. Plex's
/// subtitle-only transcode turned out to answer empty documents for embedded
/// tracks (Aether#1533), so "ask the server for the text" is not a route — the
/// demux this engine already runs is the one honest source of embedded cues.
///
/// Times are **seconds on the producer's playback clock**. Remux callbacks
/// subtract the source's presentation origin for comparison with
/// `AVPlayerItem.currentTime()`. `SoftwarePlaybackPipeline.activeSubtitleCues`
/// keeps source timestamps, matching that pipeline's `currentTime`.
public struct TimedTextCue: Sendable, Equatable {
    /// The source stream this cue came from — the same index
    /// `SubtitleTrackInfo.streamIndex` reports, so a host can route cues to
    /// the track the viewer selected.
    public let streamIndex: Int32
    /// Seconds on the producing pipeline's playback clock (see above).
    public let start: Double
    public let end: Double
    /// Cue payload as the converter produced it — WebVTT-safe plain text,
    /// possibly carrying simple inline tags (`<i>`, `<b>`, `<u>`) the source
    /// had, including ones translated from ASS `{\i1}`-style overrides.
    public let text: String
    /// Where the source asked for the cue to be drawn (an ASS `\an8`, a
    /// WebVTT `line:`), or `nil` for the host's default placement — which is
    /// what nearly every cue wants. A host that ignores it draws exactly what
    /// it drew before.
    public let placement: TextCuePlacement?

    public init(
        streamIndex: Int32, start: Double, end: Double, text: String,
        placement: TextCuePlacement? = nil
    ) {
        self.streamIndex = streamIndex
        self.start = start
        self.end = end
        self.text = text
        self.placement = placement
    }
}

enum SubtitleDelay {
    /// Wider than audio's +/-2 s: a lip-sync error is a few frames, while a
    /// subtitle file cut for another release (PAL speed-up, a different
    /// intro) is routinely several seconds out.
    static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(10, max(-10, value)) : 0
    }
}

extension TimedTextCue {
    /// The cue as the viewer should see it under `delay`, or `nil` when the
    /// shift pushes it wholly before zero. The start is clamped rather than
    /// allowed negative: a negative cue time is the same trap an unsigned
    /// timestamp is on the audio side, and every consumer compares against a
    /// clock that never goes below zero anyway.
    func delayed(by delay: Double) -> TimedTextCue? {
        guard delay != 0 else { return self }
        let start = Swift.max(0, self.start + delay)
        let end = self.end + delay
        guard end > start else { return nil }
        return TimedTextCue(streamIndex: streamIndex, start: start, end: end, text: text, placement: placement)
    }
}
