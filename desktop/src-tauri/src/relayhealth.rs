//! Per-relay health for graceful fallback. A relay that fails to connect / put / list is put
//! into exponential backoff so we stop hammering a dead relay and quietly use the others — and
//! we retry it later, so a relay that comes back is picked up again automatically. Redundancy
//! (writing to every configured relay) + this backoff = graceful degradation: posts still flow
//! as long as ONE relay (or the BYO S3 bucket, or a direct peer link) is reachable.

const BASE_BACKOFF_MS: u64 = 5_000; // first failure → 5s cool-off
const MAX_BACKOFF_MS: u64 = 300_000; // capped at 5 minutes

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct RelayHealth {
    pub fails: u32,
    /// Earliest time (epoch ms) we'll try this relay again; 0 = available now.
    pub next_retry_ms: u64,
}

impl RelayHealth {
    /// Is the relay usable right now (not in a backoff window)?
    pub fn available(&self, now_ms: u64) -> bool {
        now_ms >= self.next_retry_ms
    }

    /// A successful operation clears the backoff.
    pub fn record_success(&mut self) {
        self.fails = 0;
        self.next_retry_ms = 0;
    }

    /// A failure grows the backoff exponentially (5s, 10s, 20s … capped at 5m).
    pub fn record_failure(&mut self, now_ms: u64) {
        self.fails = self.fails.saturating_add(1);
        let shift = (self.fails - 1).min(6); // cap the exponent so the shift never overflows
        let backoff = BASE_BACKOFF_MS.saturating_mul(1u64 << shift).min(MAX_BACKOFF_MS);
        self.next_retry_ms = now_ms.saturating_add(backoff);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fresh_relay_is_available() {
        let h = RelayHealth::default();
        assert!(h.available(0));
        assert!(h.available(1_000_000));
    }

    #[test]
    fn failure_starts_backoff_then_recovers() {
        let mut h = RelayHealth::default();
        h.record_failure(1_000);
        assert!(!h.available(1_000));
        assert!(!h.available(1_000 + 4_999));
        assert!(h.available(1_000 + 5_000)); // 5s base backoff elapsed
    }

    #[test]
    fn backoff_grows_exponentially() {
        let mut h = RelayHealth::default();
        h.record_failure(0); // 5s
        assert_eq!(h.next_retry_ms, 5_000);
        h.record_failure(0); // 10s
        assert_eq!(h.next_retry_ms, 10_000);
        h.record_failure(0); // 20s
        assert_eq!(h.next_retry_ms, 20_000);
    }

    #[test]
    fn backoff_is_capped() {
        let mut h = RelayHealth::default();
        for _ in 0..30 {
            h.record_failure(0);
        }
        assert_eq!(h.next_retry_ms, MAX_BACKOFF_MS); // never grows past the cap (no overflow)
    }

    #[test]
    fn success_resets_backoff() {
        let mut h = RelayHealth::default();
        h.record_failure(1_000);
        h.record_success();
        assert_eq!(h.fails, 0);
        assert!(h.available(1_000));
    }
}
