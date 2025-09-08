public import X509

/// Configuration settings for the HTTP server.
///
/// This structure contains all the necessary configuration options for setting up
/// and running an HTTP server, including network binding and TLS settings.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct HTTPServerConfiguration: Sendable {
    /// Specifies where the server should bind and listen for incoming connections.
    ///
    /// Currently supports binding to a specific host and port combination.
    /// Additional binding targets may be added in the future.
    public struct BindTarget: Sendable {
        enum Backing {
            case hostAndPort(host: String, port: Int)
        }

        let backing: Backing

        /// Creates a bind target for a specific host and port.
        ///
        /// - Parameters:
        ///   - host: The hostname or IP address to bind to (e.g., "localhost", "0.0.0.0")
        ///   - port: The port number to listen on (e.g., 8080, 443)
        /// - Returns: A configured `BindTarget` instance
        ///
        /// ## Example
        /// ```swift
        /// let target = BindTarget.hostAndPort(host: "localhost", port: 8080)
        /// ```
        public static func hostAndPort(host: String, port: Int) -> Self {
            Self(backing: .hostAndPort(host: host, port: port))
        }
    }

    /// Configuration for TLS/SSL encryption settings.
    ///
    /// Provides options for running the server with or without TLS encryption.
    /// When using TLS, you must provide a certificate chain and private key.
    public struct TLS: Sendable {
        enum Backing {
            case insecure
            case certificateChainAndPrivateKey(
                certificateChain: [Certificate],
                privateKey: Certificate.PrivateKey
            )
        }

        let backing: Backing

        public static let insecure: Self = Self(backing: .insecure)

        public static func certificateChainAndPrivateKey(
            certificateChain: [Certificate],
            privateKey: Certificate.PrivateKey
        ) -> Self {
            Self(
                backing: .certificateChainAndPrivateKey(
                    certificateChain: certificateChain,
                    privateKey: privateKey
                )
            )
        }
    }

    /// HTTP/2 specific configuration.
    public struct HTTP2: Sendable, Hashable {
        /// The maximum frame size to be used in an HTTP/2 connection.
        public var maxFrameSize: Int

        /// The target window size for this connection.
        ///
        /// - Note: This will also be set as the initial window size for the connection.
        public var targetWindowSize: Int

        /// The number of concurrent streams on the HTTP/2 connection.
        public var maxConcurrentStreams: Int?

        public init(
            maxFrameSize: Int,
            targetWindowSize: Int,
            maxConcurrentStreams: Int?
        ) {
            self.maxFrameSize = maxFrameSize
            self.targetWindowSize = targetWindowSize
            self.maxConcurrentStreams = maxConcurrentStreams
        }

        /// Default values. The max frame size defaults to 2^14, the target window size defaults to 2^16-1, and
        /// the max concurrent streams default to infinite.
        public static var defaults: Self {
            Self(
                maxFrameSize: 1 << 14,
                targetWindowSize: (1 << 16) - 1,
                maxConcurrentStreams: nil
            )
        }
     }

    /// Configuration for the backpressure strategy to use when reading requests and writing back responses.
    public struct BackPressureStrategy: Sendable {
        enum Backing {
            case watermark(low: Int, high: Int)
        }

        internal let backing: Backing

        private init(backing: Backing) {
            self.backing = backing
        }

        /// A low/high watermark will be applied when reading requests and writing responses.
        /// - Parameters:
        ///   - low: The threshold below which the consumer will ask the producer to produce more elements.
        ///   - high: The threshold above which the producer will stop producing elements.
        /// - Returns: A low/high watermark strategy with the configured thresholds.
        public static func watermark(low: Int, high: Int) -> Self {
            .init(backing: .watermark(low: low, high: high))
        }
    }

    /// Network binding configuration
    public var bindTarget: BindTarget

    /// TLS configuration for the server.
    public var tlSConfiguration: TLS

    /// Backpressure strategy to use in the server.
    public var backpressureStrategy: BackPressureStrategy

    /// Backpressure strategy to use in the server.
    public var http2: HTTP2

    /// Create a new configuration.
    /// - Parameters:
    ///   - bindTarget: A ``BindTarget``.
    ///   - tlsConfiguration: A ``TLSConfiguration``. Defaults to ``TLSConfiguration/insecure``.
    ///   - backpressureStrategy: A ``BackPressureStrategy``.
    ///   Defaults to ``BackPressureStrategy/watermark(low:high:)`` with a low watermark of 2 and a high of 10.
    ///   - http2: A ``HTTP2``. Defaults to ``HTTP2/defaults``.
    public init(
        bindTarget: BindTarget,
        tlsConfiguration: TLS = .insecure,
        backpressureStrategy: BackPressureStrategy = .watermark(low: 2, high: 10),
        http2: HTTP2 = .defaults
    ) {
        self.bindTarget = bindTarget
        self.tlSConfiguration = tlsConfiguration
        self.backpressureStrategy = backpressureStrategy
        self.http2 = http2
    }
}
