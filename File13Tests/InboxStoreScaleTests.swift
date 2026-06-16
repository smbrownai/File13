import File13Core
import Foundation
import Testing

/// Perf regression tests for the InboxStore aggregate-cache pattern,
/// which CLAUDE.md flags as load-bearing under scale. The aggregate
/// cache memoizes the result of grouping/clustering/bucketing the
/// inbox into senders, subject clusters, date buckets, etc., keyed off
/// a per-session `headersVersion` fingerprint. Without the cache, every
/// SwiftUI body render (e.g., every checkbox click) would re-walk the
/// full header list.
///
/// These tests don't try to measure absolute throughput — they assert
/// *generous* upper bounds (500 ms aggregate-cache build, 50 ms for a
/// post-build selection check) so they catch O(N²) regressions
/// without flaking on CI noise. If the bounds need tightening over
/// time, do that deliberately and document the reason here.
///
/// Fixture: ~50,000 synthetic headers across ~400 senders, produced by
/// `MockInbox.generateScaled(targetCount:)`. Generated once per test
/// run.
@Suite struct InboxStoreScaleTests {

    /// Canary on the fixture generator. The per-header cost is dominated
    /// by `MessageHeader.init`'s memoized transactional + disposable-domain
    /// detection (one substring scan + one Set lookup against ~5,400 domains),
    /// so 50k headers in Debug is realistically 2–4s on Apple Silicon.
    /// The bound here exists to catch *order-of-magnitude* regressions —
    /// e.g., someone accidentally turns the disposable-domain check from a
    /// Set lookup into a linear scan — not stylistic slowdowns.
    @Test func generateScaledIsLinear() {
        let target = 50_000
        let start = Date()
        let headers = MockInbox.generateScaled(targetCount: target)
        let elapsed = Date().timeIntervalSince(start)
        #expect(headers.count >= target, "generateScaled should reach at least \(target) headers, got \(headers.count)")
        #expect(elapsed < 8.0, "Fixture generation took \(elapsed)s for \(target) headers; bound is 8s as a regression canary, not a perf target")
    }

    /// First-time grouping cost on a 50k fixture. `groupedBySender()` is
    /// the operation `InboxStore.ensureAggregateCache` invokes when its
    /// fingerprint mismatches, so its wall-clock under load is the
    /// thing that decides whether a fresh refresh re-renders smoothly.
    ///
    /// Bound: 500 ms. Real measurements on an M-series Mac in Debug
    /// are well under 200 ms; the headroom is for CI / older hardware
    /// and to catch quadratic regressions, not stylistic slowdowns.
    @Test func aggregateGroupingStaysSubSecond() {
        let headers = MockInbox.generateScaled(targetCount: 50_000)
        let start = Date()
        let senders = headers.groupedBySender()
        let elapsed = Date().timeIntervalSince(start)
        #expect(!senders.isEmpty, "groupedBySender should produce a non-empty result")
        #expect(elapsed < 0.5, "groupedBySender on \(headers.count) headers took \(elapsed)s; aggregate-cache rebuild target is < 500ms")
    }

    /// Per-sender membership lookups must be O(1) — they fire from
    /// SwiftUI row bodies on every observable tick. With ~400 senders
    /// and a 50k inbox, a quadratic regression here would show up as
    /// noticeable scrolling lag.
    @Test func senderHeadersByIdLookupIsFast() {
        let headers = MockInbox.generateScaled(targetCount: 50_000)
        // Build the by-id dictionary the same way `InboxStore` does. The
        // test isn't asserting parity with the production code path —
        // it's checking that the underlying primitive (Dictionary build
        // from an array's lazy id-map) stays sub-100 ms even on a 50k
        // fixture, since that's the cold-cache cost we eat on a scope
        // switch or full refresh.
        let start = Date()
        let byId = Dictionary(uniqueKeysWithValues: headers.map { ($0.id, $0) })
        let elapsed = Date().timeIntervalSince(start)
        #expect(byId.count == headers.count, "headersById should index every header")
        #expect(elapsed < 0.1, "Building headersById for \(headers.count) headers took \(elapsed)s; expected < 100ms")
    }
}
