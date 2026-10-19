import Foundation
import CoreGraphics

/// The host's `BitmapCue` sink for one remux session: takes the decoder's
/// events for the bitmap streams the host asked for, closes each composition
/// once something ended it, and hands the host its rectangles as pictures on
/// the played timeline.
///
/// Separate from `SubtitleRenditionSet`'s text tap on purpose. The text tap
/// remembers every cue it ever produced, because a cue is a few dozen bytes; a
/// bitmap cue is a picture of up to hundreds of kilobytes, a two-hour film has
/// two thousand of them, and a disc has up to thirty tracks. This tap remembers
/// nothing it has delivered. What it holds is the one composition per stream
/// whose end is not known yet, kept as palette indices.
///
/// Thread contract: `process`, `advance`, `reanchor`, `finish` and `setOrigin`
/// run on the producer thread, in packet order; the setters come from the
/// host's. Cues are delivered **on the producer thread**, outside the lock.
final class BitmapCueTap: @unchecked Sendable {

    /// A composition shown but not yet ended. PGS says the end with the next
    /// event (usually a clear), so this is a normal state, not a fault.
    private struct Standing {
        let start: Double
        /// The latest it can still be standing: the longest a picture stands
        /// (`maximumCueSeconds`), or the page's time-out where the codec states
        /// one and it is shorter. Past it nothing is shown even if no event
        /// says so, and `advance(to:)` acts on it.
        let latestEnd: Double
        let rects: [BitmapSubtitleDecoder.Rect]
        let frameSize: CGSize
    }

    /// A composition with its end, still on the source's axis and still
    /// palette indices.
    private struct Ended {
        let streamIndex: Int32
        let start: Double
        let end: Double
        let rects: [BitmapSubtitleDecoder.Rect]
        let frameSize: CGSize
    }

    /// How long a composition may stand when the stream never says otherwise.
    /// The OCR rendition's cap, so the picture and the recognized text of one
    /// composition are on screen for the same time. Set, not measured: a clear
    /// that never comes is a damaged stream, and ten seconds is longer than any
    /// subtitle a disc carries except a title card.
    static var maximumCueSeconds: Double { SubtitleRenditionSet.BitmapRenditionTrack.maximumCueSeconds }

    /// Compositions that ended before the presentation origin was known. The
    /// origin comes with the first video packet (planned sessions know it
    /// before the first read), so this is a handful at most; the bound only
    /// keeps a stream that never gets an origin from growing.
    private static let maximumBeforeOrigin = 32

    private let lock = NSLock()
    private var handler: (@Sendable (BitmapCue) -> Void)?
    private var wanted: Set<Int32> = []
    private var standing: [Int32: Standing] = [:]
    /// Streams chosen (again) whose decoders sat idle while the demux moved on.
    /// The producer flushes each before its next packet - not the host thread,
    /// which would race the producer's decode.
    private var needsFlush: Set<Int32> = []
    private var origin: Double?
    private var delay: Double = 0
    private var beforeOrigin: [Ended] = []

    // MARK: - Host side

    /// Register (or clear) the sink. Nothing already produced is replayed:
    /// this tap does not keep it.
    func setHandler(_ handler: (@Sendable (BitmapCue) -> Void)?) {
        lock.withLock { self.handler = handler }
    }

    /// Choose the streams cues are produced for; returns the ones that were not
    /// wanted before. A stream dropped here loses its standing composition at
    /// once — the viewer who switched away must not get a picture from it a
    /// moment later.
    @discardableResult
    func setWanted(_ streams: Set<Int32>) -> Set<Int32> {
        lock.withLock {
            let added = streams.subtracting(wanted)
            wanted = streams
            needsFlush.formUnion(added)
            for stream in standing.keys where !streams.contains(stream) {
                standing.removeValue(forKey: stream)
            }
            return added
        }
    }

    var wantedStreams: Set<Int32> { lock.withLock { wanted } }

    /// Whether a packet of this stream is worth decoding for the host: someone
    /// to hand the cue to, and a viewer who chose the stream.
    func wants(_ streamIndex: Int32) -> Bool {
        lock.withLock { handler != nil && wanted.contains(streamIndex) }
    }

    func setDelay(_ seconds: Double) {
        lock.withLock { delay = SubtitleDelay.normalized(seconds) }
    }

    /// Whether the decoder of a stream the host has just chosen must be flushed
    /// before its next packet, once. A decoder that was not fed while the
    /// demux went on holds an epoch from before the gap, and a display set that
    /// continues it would show a picture from back then at the time it is now.
    func takeFlush(_ streamIndex: Int32) -> Bool {
        lock.withLock { needsFlush.remove(streamIndex) != nil }
    }

    // MARK: - Producer side

    func setOrigin(seconds: Double) {
        var held: [Ended] = []
        lock.withLock {
            guard origin == nil else { return }
            origin = max(0, seconds)
            held = beforeOrigin
            beforeOrigin = []
        }
        deliver(held)
    }

    /// Fold decoder events of one stream into cues. What ends a composition is
    /// the OCR track's rule (`BitmapRenditionTrack.process`) on purpose — the
    /// picture and the recognized text of one composition have to stand for the
    /// same time: whatever event follows ends the standing one (a clear, the
    /// next composition), and an explicit end (DVD) is believed, so nothing
    /// stands.
    ///
    /// A DVB page's time-out is not an explicit end. The standard makes it the
    /// time a page stays valid *unless redefined*, and the next page redefines
    /// it, usually sooner — believed as an end, two subtitles would be on
    /// screen at once, stacked. It is a ceiling on how long the composition
    /// stands, like the cap for a clear that never comes.
    func process(_ events: [BitmapSubtitleDecoder.Event], streamIndex: Int32) {
        var ended: [Ended] = []
        lock.withLock {
            for event in events {
                if let open = standing.removeValue(forKey: streamIndex) {
                    let end = min(event.startSeconds, open.latestEnd)
                    if end > open.start {
                        ended.append(Ended(
                            streamIndex: streamIndex, start: open.start, end: end,
                            rects: open.rects, frameSize: open.frameSize
                        ))
                    }
                }
                // A clear, or an event that carries no rectangle at all.
                guard !event.rects.isEmpty else { continue }
                if let end = event.endSeconds, !event.endIsTimeOut {
                    ended.append(Ended(
                        streamIndex: streamIndex, start: event.startSeconds, end: end,
                        rects: event.rects, frameSize: event.frameSize
                    ))
                } else {
                    let ceiling = event.startSeconds + Self.maximumCueSeconds
                    standing[streamIndex] = Standing(
                        start: event.startSeconds,
                        latestEnd: event.endSeconds.map { min($0, ceiling) } ?? ceiling,
                        rects: event.rects, frameSize: event.frameSize
                    )
                }
            }
        }
        deliver(ended)
    }

    /// The demux has read everything up to `seconds` (a segment was cut there,
    /// source axis): no event of a standing composition's stream that comes
    /// before this is still to arrive, so whatever has passed its latest end
    /// ends there. Without this a picture nothing followed — the last
    /// subtitle before a long silence — would wait for the next one, and a
    /// player that is already past it would never see it.
    func advance(to seconds: Double) {
        var ended: [Ended] = []
        lock.withLock {
            for (stream, open) in standing where open.latestEnd <= seconds {
                ended.append(Ended(
                    streamIndex: stream, start: open.start, end: open.latestEnd,
                    rects: open.rects, frameSize: open.frameSize
                ))
                standing.removeValue(forKey: stream)
            }
        }
        deliver(ended.sorted { $0.start < $1.start })
    }

    /// A seek. The standing compositions die unseen, with the decoders' epoch
    /// state (the caller flushes those): a picture decoded before the jump must
    /// never be handed over after it, and its clear — which is how it would
    /// have ended — is on the other side of the jump.
    func reanchor() {
        lock.withLock { standing.removeAll() }
    }

    /// End of stream: whatever still stands has no event coming, and ends at
    /// the latest it could.
    func finish() {
        var ended: [Ended] = []
        lock.withLock {
            ended = standing.map { stream, open in
                Ended(
                    streamIndex: stream, start: open.start, end: open.latestEnd,
                    rects: open.rects, frameSize: open.frameSize
                )
            }.sorted { $0.start < $1.start }
            standing.removeAll()
        }
        deliver(ended)
    }

    // MARK: - Delivery

    /// Rebase onto the played timeline, apply the viewer's delay, build the
    /// pictures and call the handler — or hold the composition until the
    /// origin exists, since without it the times mean nothing.
    private func deliver(_ ended: [Ended]) {
        guard !ended.isEmpty else { return }
        var ready: (origin: Double, delay: Double, handler: @Sendable (BitmapCue) -> Void)?
        lock.withLock {
            guard let origin else {
                beforeOrigin.append(contentsOf: ended)
                if beforeOrigin.count > Self.maximumBeforeOrigin {
                    beforeOrigin.removeFirst(beforeOrigin.count - Self.maximumBeforeOrigin)
                }
                return
            }
            // No sink (the host cleared it): nothing to build pictures for.
            if let handler { ready = (origin, delay, handler) }
        }
        guard let ready else { return }
        for composition in ended {
            for cue in Self.cues(of: composition, origin: ready.origin, delay: ready.delay) {
                ready.handler(cue)
            }
        }
    }

    private static func cues(of composition: Ended, origin: Double, delay: Double) -> [BitmapCue] {
        // A picture without a frame to be placed in cannot be drawn, and a host
        // dividing by a zero reference size would draw garbage; the codec, the
        // container and the video all have to be silent for this to happen.
        guard composition.frameSize.width > 0, composition.frameSize.height > 0 else { return [] }
        let start = max(0, composition.start - origin)
        let end = composition.end - origin
        guard end > start else { return [] }
        return composition.rects.compactMap { rect in
            guard let image = BitmapSubtitleDecoder.picture(of: rect) else { return nil }
            return BitmapCue(
                streamIndex: composition.streamIndex, start: start, end: end, image: image,
                frame: CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height),
                referenceSize: composition.frameSize, isForced: rect.isForced
            ).delayed(by: delay)
        }
    }
}
