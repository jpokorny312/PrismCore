import Foundation

/// Shared by opt-in HTTP readers, including independent sessions to the same
/// origin. Admission waits before occupying a connection slot.
final class HTTPOriginCoordinator: @unchecked Sendable {
    static let shared = HTTPOriginCoordinator()
    private struct State {
        var active = 0
        var refusals = 0
        var nextAdmission: TimeInterval = 0
        var lastRefusal: TimeInterval = 0
    }
    private let condition = NSCondition()
    private var states: [String: State] = [:]

    static func origin(_ url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
    }

    func acquire(_ origin: String, cancelled: () -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let now = ProcessInfo.processInfo.systemUptime
        states = states.filter { _, state in
            state.active > 0 || state.nextAdmission > now || now - state.lastRefusal <= 60
        }
        while !cancelled() {
            let now = ProcessInfo.processInfo.systemUptime
            var state = states[origin] ?? State()
            if state.refusals > 0, now - state.lastRefusal > 60, now >= state.nextAdmission {
                state.refusals = 0
            }
            if state.active < 2, now >= state.nextAdmission {
                state.active += 1
                if state.refusals > 0 { state.nextAdmission = now + 2 }
                states[origin] = state
                return true
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        return false
    }

    /// Admission for work nobody is waiting on — the source prewarm.
    ///
    /// Two differences from `acquire`, both so that optional work can never
    /// cost a playback anything. It is admitted only while the origin has
    /// NO request in flight, so the second of the two slots is always left
    /// for a reader that a user is watching; and an origin that has refused
    /// anyone in the last minute is not waited out but declined outright —
    /// an origin that is shedding load is the last one to spend a speculative
    /// request on, and waiting would only park a prewarm ahead of the
    /// playback that eventually needs the slot.
    func acquireYielding(_ origin: String, cancelled: () -> Bool) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        while !cancelled() {
            let now = ProcessInfo.processInfo.systemUptime
            var state = states[origin] ?? State()
            if state.refusals > 0, now - state.lastRefusal <= 60 { return false }
            if state.refusals > 0, now >= state.nextAdmission { state.refusals = 0 }
            if state.active == 0, now >= state.nextAdmission {
                state.active = 1
                states[origin] = state
                return true
            }
            _ = condition.wait(until: Date(timeIntervalSinceNow: 0.05))
        }
        return false
    }

    func release(_ origin: String) {
        condition.lock()
        if var state = states[origin] {
            state.active = max(0, state.active - 1)
            if state.active == 0 && state.refusals == 0 { states.removeValue(forKey: origin) }
            else { states[origin] = state }
        }
        condition.broadcast()
        condition.unlock()
    }

    func refuse(_ origin: String, retryAfter: String?) {
        condition.lock()
        var state = states[origin] ?? State()
        state.refusals = min(4, state.refusals + 1)
        state.lastRefusal = ProcessInfo.processInfo.systemUptime
        let fallback = min(15, pow(2, Double(state.refusals)))
        state.nextAdmission = max(state.nextAdmission,
            state.lastRefusal + (Self.retryDelay(retryAfter) ?? fallback))
        states[origin] = state
        condition.broadcast()
        condition.unlock()
    }

    static func retryDelay(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return seconds }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return parser.date(from: header).map { max(0, $0.timeIntervalSince(now)) }
    }
}
