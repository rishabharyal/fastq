import Foundation

/// Exponential backoff with jitter for websocket reconnection.
///
/// A pure value type: the delay is a function of the attempt count alone, so the
/// reconnect strategy can be reasoned about and tested without a live socket.
struct ReconnectPolicy {
    let baseDelay: TimeInterval
    let maxDelay: TimeInterval
    /// Fraction of the computed delay applied as random jitter. Without it, a
    /// server restart would have every client reconnect in lockstep.
    let jitterFraction: Double

    private(set) var attempt: Int = 0

    init(baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30, jitterFraction: Double = 0.3) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.jitterFraction = jitterFraction
    }

    /// Delay before the next attempt, advancing the backoff.
    mutating func nextDelay() -> TimeInterval {
        // Cap the exponent before computing the power: with enough failures
        // `pow` would overflow to infinity, and `min` cannot rescue a NaN.
        let exponent = Double(min(attempt, 16))
        let uncapped = baseDelay * pow(2, exponent)
        let capped = min(uncapped, maxDelay)
        attempt += 1

        let jitter = capped * jitterFraction
        return max(0, capped - jitter + Double.random(in: 0...(jitter * 2)))
    }

    /// Called after a successful subscribe so the next outage restarts fast.
    mutating func reset() {
        attempt = 0
    }
}
