# FeedReadiness

**A resource-budgeted readiness engine for a vertical short-video feed. It decides which clips hold a hardware decoder, which have bytes on disk, and at what quality. It keeps those decisions right when the user flings, the network drops, the phone overheats or Low Power Mode turns on.**

[![CI](https://github.com/rajatslakhina/video-feed-readiness-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/rajatslakhina/video-feed-readiness-kit/actions/workflows/ci.yml)
![Swift 6](https://img.shields.io/badge/Swift-6.0%2B-orange) ![Platforms](https://img.shields.io/badge/platforms-iOS%2017%20%7C%20macOS%2014%20%7C%20Linux-blue) ![License: MIT](https://img.shields.io/badge/license-MIT-green)

Demo app: **[video-feed-readiness-kit-demo-app](https://github.com/rajatslakhina/video-feed-readiness-kit-demo-app)**, a SwiftUI console that consumes this package as a remote dependency pinned to the `1.0.0` release. Its README has screenshots from an iOS Simulator run in CI.

---

## The problem

"Design the TikTok / Reels feed" is a standard staff-level mobile system design question. The usual whiteboard answer is "prefetch the next N videos", and on a real phone it breaks in five ways:

1. **Decoders are a hard budget that iOS does not publish.** Each prepared `AVPlayer` holds a hardware decoder. If you ask for too many, you get item failures or black frames rather than a clean error. "Prepare the next 5" is not a plan.
2. **Flings race your own cleanup.** A user who swipes ten times in a second leaves each clip while its player is still being created. If you free that decoder slot early, the pool reports it as free while the hardware is still allocating. The next prepare then over-commits, and the port is told to tear down a player it has not finished building, so that player leaks.
3. **Playback commands race each other.** `pause(previous)` and `play(next)` sent from independent tasks can arrive out of order, and two clips play over each other.
4. **The right window depends on the device right now.** Cellular, Low Data Mode, offline, Low Power Mode, thermal state and memory pressure each argue for a smaller window, and they combine. Hand-written `if` ladders for these drift into contradictions, such as an *offline* phone preparing more than a *constrained* one.
5. **Prefetch depth is a bet on attention.** Six seconds of prefetch is wasted on someone who skips 90% of clips, and is too little for someone who watches to the end.

FeedReadiness turns each of these into an explicit component, and each component has a property that is checked by tests.

## Why this matters (the lead-level part)

The hard decisions here are not about how to call AVFoundation. They are the ones a lead has to defend across teams:

- **Budgets are first-class inputs.** Decoder count, disk bytes and bitrate cap are explicit parameters with audits. A product request like "prefetch more on Wi-Fi" changes one number, and an audit in CI checks that the policy is still monotone: no worse device state gets a bigger window than a better one.
- **A pure planner and a thin actor.** What should be playing, prepared and prefetched is a pure function of plain values (`PlannerInput → ReadinessPlan`), fuzzed with 5,000 random inputs. The actor only *applies* a plan. The few decisions it makes itself are about getting there safely: which decoder to pre-empt during a quality switch, when to fall back to break-before-make, which download to keep, and which failing key to stop retrying. That split lets a platform team own the policy while a feature team owns the UI.
- **Monotonicity is a contract.** A window policy must never grow when conditions get worse. `PolicyAudit` checks all 96 combinations of discrete conditions, so the property survives future edits by people who never read this README.
- **Failure modes are designed, not discovered.** These are handled explicitly and tested: flings, out-of-order completions, a port that always fails, a download that finishes after it was cancelled, a quality switch on the clip on screen, and losing the network mid-download.
- **On-device learning where it pays.** A four-weight online model sets prefetch depth per user and per session. There is no server and no stored profile, and inputs are sanitised so NaN or infinity cannot poison it.

## Architecture

```
 DeviceConditions ─┬─► WindowPolicy (monotone, audited) ──► WindowShape ─┐
                   └─► QualityLadder (hysteresis) ──► bitrate cap ───────┤
 SkipPredictor (online logistic regression) ──► P(skip next) ────────────┤
 RenditionCache (delivered bytes) + prepared decoders ───────────────────┤
                                                                          ▼
                             ReadinessPlanner (pure) ──► ReadinessPlan
                                                          │ playing / prepared / prefetch / window
                                                          ▼
                     FeedEngine (actor): diff plan vs held state, drive ports
                        ├─ DecoderPool (fixed slots, generation-stamped leases)
                        ├─ RenditionCache (byte budget, LRU + per-rendition pinning, reserve-before-fetch)
                        ├─ PlayerPort  ◄── prepare: concurrent · play/pause/release: one FIFO chain
                        └─ PrefetchTransport ◄── token-checked completions
```

| Type | Responsibility | Property it guarantees |
|---|---|---|
| `DefaultWindowPolicy` | Conditions → how many clips are prepared ahead/behind, how many are prefetched ahead, and how many seconds each | **Monotone**: worse conditions never yield a larger window. Every rule is a cap, and every rule for a condition also applies to all worse values of it |
| `PolicyAudit` | Exhaustive check over all 96 discrete condition combinations | Finds any (better, worse) pair where the worse one gets more, and any shape that needs more decoders than exist |
| `QualityLadder` | Throughput + device state → bitrate cap (600 / 1,200 / 2,500 / 5,000 kbps) | Down-switches are immediate. Up-switches need throughput ≥ level × 1.5 × 1.25 held **continuously for 4 s**, and move one level at a time. Thermal and Low Power ceilings override the network |
| `SkipPredictor` | Watch fraction + swipe velocity history → P(skip next) | Exactly 0.5 untrained; one SGD step per clip; weights bounded to ±8; non-finite inputs neutralised |
| `ReadinessPlanner` | All of the above → desired state around the cursor | Never plans more than `capacity − 1` prepared decoders (one is always reserved for playback), never an out-of-range index, never two decoders for one clip. Offline, only clips that can start without the network (prepared player or cached first segment) get a slot, and the quality cap never refuses one that can |
| `DecoderPool` | Fixed decoder slots (capacity bounded to 64) | A stale lease can never free a slot that was handed to someone else (generation-stamped) |
| `RenditionCache` | Byte budget per (clip, rendition) | Total ≤ budget at all times, including while fetches are in flight (space is reserved first). Pinned keys are never evicted. A refused reservation evicts nothing |
| `FeedEngine` | Applies plans through ports | Ordered control commands, whoever-finishes-last releases, make-before-break quality switches (pre-empting a prepared decoder when the pool is full), token-checked downloads, no retry loop on a failing port (details below) |

## Design decisions and the alternatives I rejected

**1. Whoever finishes last releases (rather than cancelling the prepare).**
Sometimes the user swipes away from a clip whose decoder is still preparing. The lease is then marked `releaseWhenPrepared`, and its slot stays occupied until the prepare completes and `PlayerPort.release` returns.
*Rejected:* releasing at once, or cancelling the prepare `Task`. `AVPlayerItem` loading does not reliably stop on Swift task cancellation, and a slot freed before the hardware frees it is exactly the over-commit bug.
The cost is that a fling can briefly delay the next clip's decoder by one prepare latency, which shows up as `decoderBusy` in the stats.

**2. One FIFO chain for `play` / `pause` / `release`; prepares stay concurrent.**
The port sees control commands in the order the engine decided them, one at a time. A `pause(B)` can therefore never overtake its `play(B)`, and nothing is sent to a player after its `release`. The clip the user leaves is paused at once, even when the next clip cannot play yet (a broken manifest, or a decoder still preparing).
*Rejected:* one task per command, which is how two clips end up playing over each other. Also rejected: serialising *everything*, including prepares, which would turn a fling into a queue of 100 ms waits.

**3. Make before break on a quality switch.**
A thermal or bandwidth downgrade changes the rendition of the clip on screen. The old decoder keeps playing until the new rendition's decoder is ready. Then the engine pauses the old one, plays the new one and releases the old one.
A hand-off needs a second decoder for a moment. If the pool is full, the engine pre-empts the lowest-priority *ready* prepared decoder and re-prepares it once the hand-off completes. If the other decoders are still preparing, the hand-off waits for one of them to become ready rather than blanking the screen. With a one-decoder budget there is nothing to pre-empt, so the engine falls back to break-before-make rather than stalling on the old rendition forever. In that one case, if the new rendition's prepare then fails, nothing plays until the next swipe or condition change: failure suppression stops an immediate retry, and the old rendition is not restored.
*Rejected:* release-then-prepare everywhere, which blanks the screen for one prepare on every quality change. That contradicts the whole point of downgrading, which is that a blurry frame costs less than a stall.

**4. A slot returns to the pool only after `release` completes.**
`decodersInUse` is then what the hardware holds, not what the bookkeeping hopes it holds.
*Rejected:* optimistic release, which makes the pool's number wrong for the length of every teardown.

**5. A pure planner and a diffing actor (rather than an imperative state machine inside the actor).**
A plan is plain data, so it can be fuzzed, checked by `ReadinessInvariants`, logged and replayed.
*Rejected:* letting the actor decide inline. That couples every policy change to concurrency code and makes "what *should* be prepared here?" impossible to unit test.

**6. LRU plus per-rendition pinning (rather than distance-from-cursor eviction).**
The plan pins the exact (clip, rendition) pairs its window will use. Fully cached window positions are pinned too, even though they need no request. Everything else is plain LRU. After a downgrade, the old rendition's bytes are *not* pinned, so they become evictable: 1080p bytes cannot feed a 360p decoder.
*Rejected:* scoring eviction by distance from the cursor. That needs the cache to know the cursor and the feed order, which couples storage to UI state.

**7. Reserve before fetching, and match completions by token.**
Space is reserved up front, so the budget holds with ten fetches in flight. A cancelled or failed fetch shrinks back to what was delivered. Each fetch carries a token, so a download that completes after it was cancelled and re-requested cannot touch the new request. The clip the user lands on keeps its in-flight download, because those bytes are exactly what it needs next. Offline, every download is cancelled.
*Rejected:* counting bytes as they arrive, which overshoots the budget by everything in flight, and that is worst during a fling.

**8. Hysteresis with a time-based dwell (rather than pure throughput-based ABR).**
Throughput that oscillates around a level boundary makes a naive ladder switch on almost every sample, and each switch re-prepares a decoder and orphans cached bytes. The test feeds a 3.6/4.8 Mbps oscillation, one sample a second, for 60 samples. The shipped ladder steps down once and stays there; a ladder with no headroom and no dwell switches at least 50 times.
The dwell is measured in *time* (an injected `FeedClock`), not in observations. The engine re-checks it on every `update(conditions:)`, every swipe and every completed download, so after thermal pressure clears, quality climbs back one level per 4 s while the feed is in use.
An earlier version counted observations. A review caught that re-counting the same sample on every swipe met the dwell, and the engine flapped quality even though the ladder on its own was stable. An engine-level oscillation test now guards that.

**9. A tiny online model (rather than a heuristic or a server model).**
A constant prefetch depth is wrong for both a skipper and a watcher. A server-side model adds latency, and a privacy question, to a decision that has to be made on every swipe. Four weights trained on-device tell the two apart within about ten clips, and they reset with the session. It is a logistic regression, not a neural network.

**10. Ports, not an AVFoundation dependency.**
`PlayerPort` and `PrefetchTransport` keep the core building and fully tested on Linux. The doc comment on `PlayerPort` spells out what an `AVPlayer` adapter must do: set `preferredPeakBitRate` from the rendition, keep `preferredForwardBufferDuration` short, and wait for `.readyToPlay`.
*Honest gap:* this package does **not** ship that AVFoundation adapter. The demo uses `SimulatedPlayer` and `SimulatedTransport`. The simulated player also counts violations of the main clauses of the port contract; the doc comment on `PlayerPort` marks which clauses it checks.

## Usage

```swift
// Package.swift
.package(url: "https://github.com/rajatslakhina/video-feed-readiness-kit.git", from: "1.0.0")
```

```swift
import FeedReadiness

let engine = FeedEngine(
    items: feedItems,                                  // [FeedItem] with their renditions
    conditions: DeviceConditions(network: .wifi, throughputKbps: 12_000),
    configuration: .init(decoderCapacity: 4, cacheBudgetBytes: 48 << 20),
    player: myAVPlayerAdapter,                         // conforms to PlayerPort
    transport: myURLSessionPrefetcher                  // conforms to PrefetchTransport
)
await engine.start()

// On every swipe: tell it what you learned about the clip being left.
await engine.move(by: 1, leaving: .init(watchFraction: 0.12, swipeVelocity: 2_400))

// On NWPathMonitor / thermal / Low Power notifications, and on each
// new throughput estimate from your network layer:
await engine.update(conditions: current)

// Debug builds: check the books balance.
let problems = await engine.invariantViolations()
assert(problems.isEmpty, "\(problems)")
```

The planner can also be used on its own, for example in a server-driven experiment, because it is a pure function:

```swift
let plan = ReadinessPlanner().plan(input)
assert(ReadinessInvariants.violations(of: plan, for: input).isEmpty)
```

Both snippets are compiled and run as written by `ReadmeUsageTests`, so they cannot silently drift from the API.

A new engine starts on the lowest quality level unless `Configuration(startLevel:)` says otherwise, and climbs one level per 4 s of sustained headroom. Pass your own `FeedClock` to control time in tests.

Run the tests with `swift test` (macOS or Linux, Swift 6.0+).

## Verification

- **98 XCTest tests** across policy, ladder, predictor, pool, cache, planner, engine, fault injection, engine guards, the simulated ports' own contract checks and the README snippets.
- **Each of the eight fault switches has a test that runs without its guard.** `FeedEngine` has eight internal fault switches, reachable only through `@testable import`. Each one disables exactly one safeguard, and `EngineFaultTests` asserts that the guarding check then **fails**:
  - release-while-preparing: the port sees releases mid-prepare, decoders leak, and the hardware peak exceeds the budget;
  - unordered port commands: two clips play at once;
  - stale fetch completions accepted: late cancellations discard the re-requested downloads;
  - break-before-make: the screen goes blank during a quality switch;
  - no hand-off pre-emption: the switch stalls on the old rendition, and `invariantViolations()` reports it;
  - forgotten pool release: the books stop balancing, and `invariantViolations()` reports it;
  - no failure suppression: the engine never settles;
  - cancelling the landing clip's download: its bytes are gone.
- **Four more safeguards have tests that a one-line mutation breaks** (`EngineGuardTests`). The final independent review found that the rest of the suite let these four mutations through:
  - a hand-off pre-empts the lowest-priority prepared decoder, not the next clip;
  - while the other decoders are still preparing, a hand-off waits instead of breaking playback;
  - a cancelled top-up keeps the bytes already on disk;
  - a failed top-up keeps them too.
- **The checkers are tested too.**
  - `SimulatedPortTests` drives the simulated player with contract violations (commands to released, never-prepared and failed players; a release during prepare; two clips playing) and asserts each counter counts. The engine tests' `== 0` assertions on those counters therefore mean something.
  - The two fault tests above show `invariantViolations()` can report.
- **Outside the engine:**
  - two broken window policies (offline forgets the constrained-network caps; "behind" grows when "ahead" shrinks) and a decoder-greedy policy, all caught by `PolicyAudit`;
  - a naive ladder that flaps at least 50 times on the oscillation trace;
  - a sign-flipped learning rule that fails both of the predictor's thresholds;
  - ten hand-broken plans that `ReadinessInvariants` must reject, plus two offline ones.
- **The orderings that matter most are gated, not timed.** The simulated player can hold prepares and the test transport holds fetches at a gate, so "the old rendition plays until the new one is ready" and "a late completion arrives after the re-request" are exact orderings, not races. Time-based behaviour uses a manual clock. Other engine tests still rely on short simulated latencies (30–80 ms) to land a swipe inside a prepare or a release. Those were stress-tested on a saturated CPU (below) and did not flake.
- **The cache is checked against a reference model**: 3,000 random reserve/touch/shrink/remove/pin operations, comparing victims and entry sets, not just the budget.
- **40 hand-made source mutations, all killed by the final suite.** Ten of them first survived or hung, and each got the test that now kills it:
  - planner ignoring spare decoders;
  - a re-wanted lease still being released;
  - a releasing slot being handed out again;
  - missing failure suppression (it hung the suite);
  - cached window positions left unpinned;
  - completed downloads not checking the dwell timer;
  - a hand-off pre-empting the next clip instead of the lowest-priority one;
  - break-before-make while the other decoders were only preparing;
  - a cancelled top-up shrinking to zero;
  - a failed top-up shrinking to zero.
- **No crash paths through the public API.**
  - No force-unwraps, `try!` or `as!`.
  - Every subscript is bounds-guarded or provably in range, with a comment where it matters.
  - Byte math and index arithmetic go through saturating or overflow-checked helpers.
  - `Double → Int64` handles NaN, ±infinity and the 2^63 boundary; non-finite clock readings are neutralised.
  - Hostile configurations (`Int.min` / `Int.max` capacities, NaN thresholds, `.max` window shapes) are tested end to end.

CI runs on pushes to `main` and on pull requests ([Actions](https://github.com/rajatslakhina/video-feed-readiness-kit/actions)):

| Job | What it does |
|---|---|
| Linux (`swift:6.1` container) | `rm -rf .build`, then a clean `swift build --build-tests -Xswiftc -warnings-as-errors`, then `swift test` |
| macOS (`macos-15`) | The same clean warnings-as-errors build and `swift test`, then `xcodebuild` of the package for `generic/platform=iOS Simulator` with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` |

Every push to `main` has been green on both jobs. On the current code: Linux **98/98 tests**, and macOS (Xcode 16.4, Swift 6.1.2) **98/98 tests plus the iOS Simulator build**. The `v1.0.0` tag ran the first 94; `EngineGuardTests` and a doc-comment correction in `Ports.swift` came after it, with no change to library behaviour.

Before the first push, locally on Linux with Swift 6.1.2:

- clean build with warnings as errors: 0 warnings;
- 94/94 tests passing, repeated five times, including twice with both CPU cores saturated;
- the engine, fault and port tests repeated another 40 times, 15 of them with three busy loops on two cores, with no flakes.

After the final review, locally:

- each of the four `EngineGuardTests` passes on the shipped code and fails on the mutation it was written for;
- the engine, fault and guard tests repeated 15 more times with three busy loops on two cores, with no flakes.

**What has not been verified:**

- No real `AVPlayer` has been driven by this engine; there is no AVFoundation adapter in the package.
- The decoder budget of 4 is an illustrative default, not a measured device limit.
- The demo app has run on an iOS Simulator only in CI: a GitHub-hosted `macos-15` runner builds it against this package's `1.0.0` tag, launches it in six scenarios, checks that it is still running after each one, and takes the screenshots shown in its README. It has not been run on a physical device, or on a Simulator on the author's own Mac. That local run was planned and skipped: Xcode and the Simulator on that Mac already had unrelated work open, and running the demo there would have meant clicking through it. The CI run replaces it.

## Layout

```
Sources/FeedReadiness/
  Model.swift            FeedItem, Rendition, CacheKey, DeviceConditions
  WindowPolicy.swift     WindowShape, DefaultWindowPolicy, PolicyAudit
  QualityLadder.swift    hysteresis ladder, LadderAudit
  SkipPredictor.swift    online logistic regression
  DecoderPool.swift      fixed slots, generation-stamped leases
  RenditionCache.swift   byte budget, LRU + pinning, reserve-before-fetch
  ReadinessPlanner.swift pure planner, ReadinessInvariants
  FeedEngine.swift       the actor that applies plans
  Ports.swift            PlayerPort, PrefetchTransport (and their contract)
  Simulation.swift       SimulatedPlayer / SimulatedTransport (contract-checking doubles)
  Clock.swift            FeedClock (injected time for the ladder's dwell)
  Arithmetic.swift       saturating helpers
Tests/FeedReadinessTests/  98 tests
```

MIT licensed.
