import Foundation

/// Rate limits (docs/api.md "Rate limits"): fixed windows per key, minimum intervals per key,
/// and counted slots (concurrent downloads, WebSocket connections).
public actor RateLimiter {
    public struct Decision: Sendable, Equatable {
        public var allowed: Bool
        public var limit: Int
        public var remaining: Int
        /// Whole seconds until the window resets (only meaningful when not allowed).
        public var retryAfter: Int
    }

    private struct Window {
        var start: Date
        var count: Int
    }

    private let clock: any GatewayClock
    private var windows: [String: Window] = [:]
    private var lastSeen: [String: Date] = [:]
    private var slots: [String: Int] = [:]

    public init(clock: any GatewayClock = SystemClock()) {
        self.clock = clock
    }

    /// Consumes `cost` units (one by default) of `limit` per `window` seconds for `key`, all
    /// or nothing: a call that would go over the limit consumes none.
    public func hit(_ key: String, limit: Int, window: TimeInterval = 60, cost: Int = 1) -> Decision {
        let now = clock.now
        var w = windows[key] ?? Window(start: now, count: 0)
        if now.timeIntervalSince(w.start) >= window { w = Window(start: now, count: 0) }
        let cost = max(cost, 1)
        if w.count + cost > limit {
            windows[key] = w
            let reset = w.start.addingTimeInterval(window).timeIntervalSince(now)
            return Decision(allowed: false, limit: limit, remaining: 0, retryAfter: max(1, Int(reset.rounded(.up))))
        }
        w.count += cost
        windows[key] = w
        return Decision(allowed: true, limit: limit, remaining: limit - w.count, retryAfter: 0)
    }

    /// Allows one call per `interval` seconds for `key`.
    public func throttle(_ key: String, interval: TimeInterval) -> Decision {
        let now = clock.now
        if let last = lastSeen[key], now.timeIntervalSince(last) < interval {
            let wait = interval - now.timeIntervalSince(last)
            return Decision(allowed: false, limit: 1, remaining: 0, retryAfter: max(1, Int(wait.rounded(.up))))
        }
        lastSeen[key] = now
        return Decision(allowed: true, limit: 1, remaining: 0, retryAfter: 0)
    }

    /// Takes one of `max` slots for `key`; false when all are in use.
    public func acquire(_ key: String, max: Int) -> Bool {
        let used = slots[key] ?? 0
        guard used < max else { return false }
        slots[key] = used + 1
        return true
    }

    public func release(_ key: String) {
        let used = slots[key] ?? 0
        slots[key] = max(0, used - 1)
    }

    public func slotsInUse(_ key: String) -> Int {
        slots[key] ?? 0
    }

    /// Drops windows and throttles older than an hour (housekeeping).
    public func sweep() {
        let cutoff = clock.now.addingTimeInterval(-3600)
        windows = windows.filter { $0.value.start > cutoff }
        lastSeen = lastSeen.filter { $0.value > cutoff }
    }
}
