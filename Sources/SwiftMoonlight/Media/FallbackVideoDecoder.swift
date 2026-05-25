import Foundation

public actor FallbackVideoDecoder: VideoDecoder {
    public enum ActiveDecoder: Sendable, Equatable {
        case primary
        case fallback
    }

    private let primary: any VideoDecoder
    private let fallback: any VideoDecoder
    private var configuredFormat: VideoFormat?
    private var activeDecoder: ActiveDecoder = .primary
    private var fallbackConfigured = false

    public init(primary: any VideoDecoder, fallback: any VideoDecoder) {
        self.primary = primary
        self.fallback = fallback
    }

    public func configure(format: VideoFormat) async throws {
        configuredFormat = format
        activeDecoder = .primary
        fallbackConfigured = false

        do {
            try await primary.configure(format: format)
        } catch {
            try await fallback.configure(format: format)
            fallbackConfigured = true
            activeDecoder = .fallback
        }
    }

    public func decode(_ frame: EncodedVideoFrame) async throws -> [DecodedVideoFrame] {
        switch activeDecoder {
        case .primary:
            do {
                return try await primary.decode(frame)
            } catch {
                return try await promoteFallbackAndDecode(frame, cause: error)
            }
        case .fallback:
            return try await fallback.decode(frame)
        }
    }

    public func flush() async throws -> [DecodedVideoFrame] {
        switch activeDecoder {
        case .primary:
            return try await primary.flush()
        case .fallback:
            return try await fallback.flush()
        }
    }

    public func currentDecoder() -> ActiveDecoder {
        activeDecoder
    }

    private func promoteFallbackAndDecode(
        _ frame: EncodedVideoFrame,
        cause _: Error
    ) async throws -> [DecodedVideoFrame] {
        guard let configuredFormat else {
            throw MoonlightError(.unsupportedOperation, message: "Fallback decoder requires a configured format")
        }

        if !fallbackConfigured {
            try await fallback.configure(format: configuredFormat)
            fallbackConfigured = true
        }

        activeDecoder = .fallback
        return try await fallback.decode(frame)
    }
}
