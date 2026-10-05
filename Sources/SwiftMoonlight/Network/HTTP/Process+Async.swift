#if os(macOS)
import Foundation

extension Process {
    /// Wait without blocking a Swift worker, and stop the child on cancellation.
    func runUntilExit() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                terminationHandler = { _ in continuation.resume() }
                do {
                    try run()
                    if Task.isCancelled, isRunning { terminate() }
                } catch {
                    // No termination callback follows a failed launch.
                    terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if self.isRunning { self.terminate() }
        }
        try Task.checkCancellation()
    }
}
#endif
