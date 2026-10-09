/// The playback side the engine drives. An AVFoundation implementation maps
/// `prepare` to creating an `AVPlayerItem` with `preferredPeakBitRate` set
/// from the rendition and `preferredForwardBufferDuration` kept short, then
/// waiting for `.readyToPlay`; `release` tears the player down.
///
/// Contract the engine guarantees. `SimulatedPlayer` counts violations of the
/// parts marked *(checked)*. The rest follow from how the engine is built
/// (every prepare gets a fresh, generation-stamped lease; `play`, `pause`
/// and `release` all go through one FIFO chain) and the simulated port does
/// not count them.
/// - *(checked)* `release` is only ever called for a lease whose `prepare`
///   has finished (successfully or not). The engine, not the port, handles
///   "the user swiped away while this was still preparing", so a port never
///   has to cope with a release racing its own prepare.
/// - A lease is never prepared twice.
/// - `play`, `pause` and `release` are delivered **in the order the engine
///   issued them**, one at a time, never concurrently with each other. So a
///   `pause(B)` can never overtake the `play(B)` it follows, and nothing is
///   sent for a lease after its `release`. *(checked: `play` or `pause` for a
///   lease that is not live)*
/// - *(checked)* `play` is only sent for a lease whose `prepare` succeeded.
///   At most one lease is playing at a time: on a hand-off the engine sends
///   `pause(old)` before `play(new)`, and the previous clip is paused as soon
///   as the user leaves it, even if the next clip is not ready yet.
public protocol PlayerPort: Sendable {
    func prepare(_ item: FeedItem, rendition: Rendition, lease: DecoderLease) async throws
    func play(_ lease: DecoderLease) async
    func pause(_ lease: DecoderLease) async
    func release(_ lease: DecoderLease) async
}

/// The download side. Fetch bytes `[fromByte, toByte)` of `key` into the
/// app's cache, returning when they are on disk. Should honour task
/// cancellation (the engine cancels fetches that leave the window); a fetch
/// that ignores it is still safe, because the engine discards completions
/// whose token is no longer current.
public protocol PrefetchTransport: Sendable {
    func fetch(_ key: CacheKey, fromByte: Int64, toByte: Int64) async throws
}
