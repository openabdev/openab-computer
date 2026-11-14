import Foundation
import Darwin

/// Termination signals that end the app through a normal `exit()`, so the managed-child sweep
/// runs. The handler runs on a dispatch queue, never inside the signal handler itself, so it may
/// block and take locks.
public enum ShutdownSignals {
    public static let defaults: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    /// The caller keeps the returned sources alive for the life of the process.
    public static func install(_ signals: [Int32] = defaults, queue: DispatchQueue = .main,
                               handler: @escaping @Sendable (Int32) -> Void) -> [DispatchSourceSignal] {
        signals.map { sig in
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            src.setEventHandler { handler(sig) }
            src.resume()
            return src
        }
    }
}
