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
    public struct TLSConfiguration: Sendable {
        enum Backing {
            case insecure
            case certificateChainAndPrivateKey(
                certificateChain: [Certificate],
                privateKey: Certificate.PrivateKey
            )
        }

        let backing: Backing

        public static func insecure() -> Self {
            Self(backing: .insecure)
        }

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

    /// Network binding configuration
    public var bindTarget: BindTarget

    public var tlSConfiguration: TLSConfiguration

    public init(
        bindTarget: BindTarget,
        tlsConfiguration: TLSConfiguration = .insecure()
    ) {
        self.bindTarget = bindTarget
        self.tlSConfiguration = tlsConfiguration
    }
}
