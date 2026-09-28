import Foundation


public struct TestClock: Clock {
    public var date: Date

    public init(date: Date = Date(timeIntervalSince1970: 0)) {
        self.date = date
    }

    public func now() -> Date {
        date
    }
}

public struct AdvancingTestClock: Clock {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var dates: [Date]
        private var fallback: Date

        init(dates: [Date]) {
            self.dates = dates
            self.fallback = dates.last ?? Date(timeIntervalSince1970: 0)
        }

        func next() -> Date {
            lock.lock()
            defer { lock.unlock() }
            guard !dates.isEmpty else {
                return fallback
            }
            let value = dates.removeFirst()
            fallback = value
            return value
        }
    }

    private let storage: Storage

    public init(dates: [Date]) {
        storage = Storage(dates: dates)
    }

    public func now() -> Date {
        storage.next()
    }
}
