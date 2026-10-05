#if os(macOS)
import Foundation
import Testing
@testable import SwiftMoonlight

@Test
func asyncProcessCompletesWithoutBlockingCaller() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try await process.runUntilExit()
    #expect(process.terminationStatus == 0)
}

@Test
func asyncProcessReportsLaunchFailure() async {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/nonexistent-vvmoon-test-command")
    await #expect(throws: (any Error).self) {
        try await process.runUntilExit()
    }
}

@Test
func asyncProcessCancellationStopsChild() async throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = ["5"]
    let task = Task { try await process.runUntilExit() }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(!process.isRunning)
}
#endif
