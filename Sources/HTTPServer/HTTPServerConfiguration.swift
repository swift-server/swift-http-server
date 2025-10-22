public import X509
public import NIOCertificateReloading
import NIOSSL

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

    /// Configuration for transport security settings.
    ///
    /// Provides options for running the server with or without TLS encryption.
    /// When using TLS, you must either provide a certificate chain and private key, or a `CertificateReloader`.
    public struct TransportSecurity: Sendable {
        enum Backing {
            case plaintext
            case tls(
                certificateChain: [Certificate],
                privateKey: Certificate.PrivateKey
            )
            case reloadingTLS(certificateReloader: any CertificateReloader)
            case mTLS(
                certificateChain: [Certificate],
                privateKey: Certificate.PrivateKey,
                trustRoots: [Certificate]?
            )
            case reloadingMTLS(
                certificateReloader: any CertificateReloader,
                trustRoots: [Certificate]?
            )
        }

        let backing: Backing

        public static let plaintext: Self = Self(backing: .plaintext)

        public static func tls(
            certificateChain: [Certificate],
            privateKey: Certificate.PrivateKey
        ) -> Self {
            Self(
                backing: .tls(
                    certificateChain: certificateChain,
                    privateKey: privateKey
                )
            )
        }

        public static func tls(certificateReloader: any CertificateReloader) throws -> Self {
            Self(backing: .reloadingTLS(certificateReloader: certificateReloader))
        }

        public static func mTLS(
            certificateChain: [Certificate],
            privateKey: Certificate.PrivateKey,
            trustRoots: [Certificate]?
        ) -> Self {
            Self(
                backing: .mTLS(
                    certificateChain: certificateChain,
                    privateKey: privateKey,
                    trustRoots: trustRoots
                )
            )
        }

        public static func mTLS(
            certificateReloader: any CertificateReloader,
            trustRoots: [Certificate]?
        ) throws -> Self {
            Self(backing: .reloadingMTLS(
                certificateReloader: certificateReloader,
                trustRoots: trustRoots
            ))
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
    public var transportSecurity: TransportSecurity

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
        transportSecurity: TransportSecurity = .plaintext,
        backpressureStrategy: BackPressureStrategy = .watermark(low: 2, high: 10),
        http2: HTTP2 = .defaults
    ) {
        self.bindTarget = bindTarget
        self.transportSecurity = transportSecurity
        self.backpressureStrategy = backpressureStrategy
        self.http2 = http2
    }
}
