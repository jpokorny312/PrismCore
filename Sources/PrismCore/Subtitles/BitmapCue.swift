import Foundation
import CoreGraphics

/// One bitmap subtitle picture of an embedded PGS, DVB or DVD stream, handed to
/// the host as the demux produces it — the disc's own picture, not a reading of
/// it. The host-facing counterpart of `TimedTextCue` for subtitles that are
/// pixels.
///
/// Exists because the OCR rendition (a WebVTT track Vision wrote from the
/// bitmaps) is the wrong delivery whenever the host can draw: recognition errs,
/// and what it keeps is the words — the typeface, the colour, the place on the
/// picture and the forced flag all die on the way. A host that lays this image
/// over the video shows what the disc authored. The OCR rendition stays for the
/// cases a host cannot draw (an external display, Picture in Picture, AirPlay):
/// it is the fallback, not the thing this replaces.
///
/// **Drawing it.** The picture is the rectangle's own pixels, premultiplied
/// BGRA in sRGB, transparent wherever the disc says so (glyph edges, shadows,
/// the whole background) — draw it as it is; do not put a colour behind it.
/// `frame` says where it goes inside `referenceSize`, both in the pixels of
/// the frame the stream was authored for, origin top left, y down. Map that
/// frame onto the picture the video actually occupies on screen:
///
/// ```swift
/// // `video`: the rect the video picture covers in the overlay's coordinates (y down).
/// let sx = video.width / cue.referenceSize.width
/// let sy = video.height / cue.referenceSize.height
/// let target = CGRect(
///     x: video.minX + cue.frame.minX * sx, y: video.minY + cue.frame.minY * sy,
///     width: cue.frame.width * sx, height: cue.frame.height * sy
/// )
/// ```
///
/// Two axes, not one scale, on purpose: a DVD frame is 720 pixels wide whatever
/// the picture's aspect, and the video is stretched to its display aspect by
/// the same two factors.
///
/// **One composition, several cues.** A disc composition can hold several
/// rectangles (a line each, or a sign at the top and dialogue at the bottom).
/// Each arrives as its own cue with the same `start` and `end` — they are
/// positioned in the same frame, so showing all that are active at the player's
/// time is the whole drawing rule, and a forced rectangle among ordinary ones
/// keeps its own `isForced`.
///
/// Times are **seconds on the producer's playback clock**, the same clock
/// `TimedTextCue` uses: for the remux path the source's presentation origin is
/// subtracted, so they compare directly with `AVPlayerItem.currentTime()`, and
/// the session's subtitle delay is applied. `end` is always known — a cue is
/// handed over once something ended it (the disc's clear, the next composition,
/// an explicit end) or the latest it can stand has passed, never as an
/// open-ended picture the host would have to take down itself. See
/// `PrismCoreSession.setBitmapCueHandler` for the rest of the delivery contract.
public struct BitmapCue: @unchecked Sendable {
    /// The source stream this cue came from — the same index
    /// `SubtitleTrackInfo.streamIndex` reports (and `TimedTextCue.streamIndex`
    /// carries), so a host can route cues to the track the viewer selected.
    public let streamIndex: Int32
    /// Seconds on the producing pipeline's playback clock (see above).
    public let start: Double
    public let end: Double
    /// The rectangle's pixels: premultiplied BGRA, sRGB, `frame.size` pixels
    /// large, transparent where the disc is. Immutable, so it may be kept and
    /// drawn from any thread.
    public let image: CGImage
    /// Where `image` sits inside `referenceSize`, in that frame's pixels
    /// (origin top left). Its size is the image's size.
    public let frame: CGRect
    /// The frame `frame` is measured in: the size the stream was authored for.
    /// PGS states it in every composition (the video size of the disc), DVD in
    /// its index (`720×480`, `720×576`). Where the codec says nothing — a DVB
    /// stream without a display definition — it is the video's size, which is
    /// a guess a host can check against what it knows of the source.
    public let referenceSize: CGSize
    /// The disc marked this rectangle as forced: shown even when the viewer
    /// turned subtitles off, because it translates what the film itself does
    /// not (foreign dialogue, a sign, a letter). A track of only forced
    /// rectangles is the usual "Forced" subtitle track; a full track may carry
    /// a few among its ordinary ones.
    public let isForced: Bool

    public init(
        streamIndex: Int32, start: Double, end: Double,
        image: CGImage, frame: CGRect, referenceSize: CGSize, isForced: Bool = false
    ) {
        self.streamIndex = streamIndex
        self.start = start
        self.end = end
        self.image = image
        self.frame = frame
        self.referenceSize = referenceSize
        self.isForced = isForced
    }
}

extension BitmapCue {
    /// What makes a delivery *the same cue* as an earlier one.
    ///
    /// The engine does not remember what it handed out, so a region the
    /// producer reads again — after a re-anchor, a replay the host asked for
    /// (`PrismCoreSession.setBitmapCueStreams(_:replayingFrom:)`) — delivers its
    /// cues again, as new images with the same identity. A host that keeps
    /// cues keys them by this and replaces; one that clears its list before
    /// asking for a replay never sees the difference.
    public struct ID: Hashable, Sendable {
        public let streamIndex: Int32
        public let start: Double
        public let end: Double
        public let frame: CGRect
    }

    public var id: ID { ID(streamIndex: streamIndex, start: start, end: end, frame: frame) }
}

extension BitmapCue {
    /// The cue as the viewer should see it under `delay`, or `nil` when the
    /// shift pushes it wholly before zero. Same rule as
    /// `TimedTextCue.delayed(by:)`: the start is clamped rather than allowed
    /// negative, since every consumer compares against a clock that never goes
    /// below zero.
    func delayed(by delay: Double) -> BitmapCue? {
        guard delay != 0 else { return self }
        let start = Swift.max(0, self.start + delay)
        let end = self.end + delay
        guard end > start else { return nil }
        return BitmapCue(
            streamIndex: streamIndex, start: start, end: end,
            image: image, frame: frame, referenceSize: referenceSize, isForced: isForced
        )
    }
}
