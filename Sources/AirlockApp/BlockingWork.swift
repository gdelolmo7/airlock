import Foundation

/// Run genuinely blocking work off the cooperative thread pool.
///
/// **`Task.detached` does not do this, and that is the trap.** "Detached" means
/// no parent task, no inherited priority or task-locals — it does NOT mean a
/// different executor. A detached task runs on the same cooperative pool, which
/// is sized to the core count, so a body that blocks in a syscall parks a worker
/// no other task in the process can use. Do that on a five-second repeat, as the
/// liveness scan did with `/bin/ps`, and the pool is permanently one worker
/// short; do it for every session's transcript at once and it is several.
///
/// A `DispatchQueue` owns threads it is allowed to block, and grows its pool
/// when they are. That is the whole difference.
///
/// **Not a general "do this in the background" helper.** Work that merely
/// `await`s belongs in structured concurrency, where it keeps cancellation and
/// its place in the task tree; routing it through here buys nothing and loses
/// both. Reach for this only when the body genuinely blocks — a subprocess, a
/// synchronous file walk, a POSIX call with no async form.
enum BlockingWork {
    static func run<T: Sendable>(
        qos: DispatchQoS.QoSClass = .utility,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: qos).async {
                continuation.resume(returning: body())
            }
        }
    }
}
