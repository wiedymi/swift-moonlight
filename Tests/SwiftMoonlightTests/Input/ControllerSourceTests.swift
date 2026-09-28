import Foundation
import simd
import Testing
@testable import SwiftMoonlight

private actor FixtureControllerSnapshotProvider: ControllerSnapshotProvider {
    private let snapshotsPerPoll: [[ControllerSnapshot]]
    private var index = 0

    init(snapshotsPerPoll: [[ControllerSnapshot]]) {
        self.snapshotsPerPoll = snapshotsPerPoll
    }

    func snapshots() async -> [ControllerSnapshot] {
        guard !snapshotsPerPoll.isEmpty else {
            return []
        }

        let current = snapshotsPerPoll[min(index, snapshotsPerPoll.count - 1)]
        if index < snapshotsPerPoll.count - 1 {
            index += 1
        }
        return current
    }
}

@Test
func pollingControllerSourceEmitsConnectedStateAndDisconnectedEvents() async throws {
    let descriptor = ControllerDescriptor(
        id: .init(rawValue: 7),
        kind: .xbox,
        supportsRumble: true,
        supportsTriggerRumble: true,
        supportsMotion: false,
        supportsTouchpad: false
    )
    let initial = ControllerSnapshot(
        descriptor: descriptor,
        state: ControllerState(
            id: descriptor.id,
            buttons: [.a],
            leftStick: SIMD2<Float>(0, 0),
            rightStick: SIMD2<Float>(0, 0),
            leftTrigger: 0,
            rightTrigger: 0
        )
    )
    let changed = ControllerSnapshot(
        descriptor: descriptor,
        state: ControllerState(
            id: descriptor.id,
            buttons: [.a, .b],
            leftStick: SIMD2<Float>(0.5, 0),
            rightStick: SIMD2<Float>(0, 0),
            leftTrigger: 0.25,
            rightTrigger: 0
        )
    )
    let source = PollingControllerSource(
        provider: FixtureControllerSnapshotProvider(
            snapshotsPerPoll: [
                [initial],
                [changed],
                [],
            ]
        ),
        pollInterval: .milliseconds(5)
    )

    await source.start()
    let received = await collectControllerEvents(from: source.events, count: 4)
    await source.stop()

    try #require(received.count == 4)
    #expect(received[0] == .connected(descriptor))
    #expect(received[1] == .stateChanged(initial.state))
    #expect(received[2] == .stateChanged(changed.state))
    #expect(received[3] == .disconnected(descriptor.id))
}

@Test
func pollingControllerSourceEmitsBatteryMotionAndTouchpadEvents() async throws {
    let descriptor = ControllerDescriptor(
        id: .init(rawValue: 9),
        kind: .dualSense,
        supportedButtons: [.standardGamepad, .touchpad],
        supportsRumble: true,
        supportsTriggerRumble: true,
        supportsMotion: true,
        supportsTouchpad: true,
        supportsBatteryState: true,
        supportsRGBLED: true
    )
    let state = ControllerState(
        id: descriptor.id,
        buttons: [.touchpad],
        leftStick: SIMD2<Float>(0, 0),
        rightStick: SIMD2<Float>(0, 0),
        leftTrigger: 0,
        rightTrigger: 0
    )
    let battery = ControllerBattery(id: descriptor.id, state: .charging, percentage: 87)
    let accelerometer = ControllerMotion(
        id: descriptor.id,
        motionType: .accelerometer,
        x: 0.1,
        y: 0.2,
        z: 0.3
    )
    let gyroscope = ControllerMotion(
        id: descriptor.id,
        motionType: .gyroscope,
        x: 1.1,
        y: 1.2,
        z: 1.3
    )
    let touchpad = ControllerTouchpadEvent(
        id: descriptor.id,
        phase: .moved,
        pointerID: 1,
        x: 0.5,
        y: 0.25,
        pressure: 0.75
    )
    let source = PollingControllerSource(
        provider: FixtureControllerSnapshotProvider(
            snapshotsPerPoll: [[
                ControllerSnapshot(
                    descriptor: descriptor,
                    state: state,
                    battery: battery,
                    motion: [accelerometer, gyroscope],
                    touchpad: touchpad
                )
            ]]
        ),
        pollInterval: .milliseconds(5)
    )

    await source.start()
    let received = await collectControllerEvents(from: source.events, count: 6)
    await source.stop()

    try #require(received.count == 6)
    #expect(received[0] == .connected(descriptor))
    #expect(received[1] == .stateChanged(state))
    #expect(received[2] == .battery(battery))
    #expect(received[3] == .motion(accelerometer))
    #expect(received[4] == .motion(gyroscope))
    #expect(received[5] == .touchpad(touchpad))
}

@Test
func controllerSessionBridgeForwardsControllerEventsToSessionInput() async throws {
    let descriptor = ControllerDescriptor(
        id: .init(rawValue: 3),
        kind: .dualSense,
        supportsRumble: true,
        supportsTriggerRumble: true,
        supportsMotion: true,
        supportsTouchpad: true
    )
    let source = PollingControllerSource(
        provider: FixtureControllerSnapshotProvider(
            snapshotsPerPoll: [[
                ControllerSnapshot(
                    descriptor: descriptor,
                    state: ControllerState(
                        id: descriptor.id,
                        buttons: [.x, .y],
                        leftStick: SIMD2<Float>(0.1, -0.2),
                        rightStick: SIMD2<Float>(0.3, -0.4),
                        leftTrigger: 0.5,
                        rightTrigger: 0.6
                    )
                )
            ]]
        ),
        pollInterval: .milliseconds(5)
    )

    let session = MoonlightSession()
    let transport = RecordingInputTransport()
    await session.attachInputSender(
        InputSender(
            context: InputEncodingContext(hostKind: .sunshine),
            transport: transport
        )
    )

    let bridge = ControllerSessionBridge(source: source, session: session)
    await bridge.start()
    try await Task.sleep(for: .milliseconds(20))
    await bridge.stop()

    let packets = await transport.recordedPackets()
    #expect(packets.count >= 2)
}

private func collectControllerEvents(
    from stream: AsyncStream<ControllerEvent>,
    count: Int,
    timeout: Duration = .seconds(1)
) async -> [ControllerEvent] {
    await withTaskGroup(of: [ControllerEvent].self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            var received: [ControllerEvent] = []
            while received.count < count, let event = await iterator.next() {
                received.append(event)
            }
            return received
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return []
        }

        let result = await group.next() ?? []
        group.cancelAll()
        return result
    }
}
