//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOSSL
public import X509

/// Configuration settings for ``NIOHTTPServer``.
///
/// This structure contains all the necessary configuration options for setting up
/// and running ``NIOHTTPServer``, including network binding and TLS settings.
@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
public struct NIOHTTPServerConfiguration: Sendable {
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
            case tls(credentials: TLSCredentials)
            case mTLS(
                credentials: TLSCredentials,
                trustConfiguration: MTLSTrustConfiguration
            )
        }

        let backing: Backing

        /// Configures the server for plaintext HTTP without TLS encryption.
        public static let plaintext: Self = Self(backing: .plaintext)

        /// Configures the server for TLS with the provided credentials.
        ///
        /// - Parameter credentials: The TLS credentials containing the certificate chain and private key
        ///   to present during the TLS handshake.
        public static func tls(credentials: TLSCredentials) -> Self {
            Self(backing: .tls(credentials: credentials))
        }

        /// Configures the server for mTLS with the provided credentials and trust configuration.
        ///
        /// - Parameters:
        ///   - credentials: The TLS credentials containing the certificate chain and private key
        ///     to present during the TLS handshake.
        ///   - trustConfiguration: The trust roots and certificate verification mode to use when
        ///     validating client certificates.
        public static func mTLS(
            credentials: TLSCredentials,
            trustConfiguration: MTLSTrustConfiguration
        ) -> Self {
            Self(
                backing: .mTLS(
                    credentials: credentials,
                    trustConfiguration: trustConfiguration
                )
            )
        }

        /// The custom mTLS certificate verification callback, if one was configured.
        ///
        /// Returns the callback when the transport security is configured for mTLS with a
        /// ``MTLSTrustConfiguration/customCertificateVerificationCallback(_:certificateVerification:)``,
        /// or `nil` otherwise.
        var customVerificationCallback: (@Sendable ([X509.Certificate]) async throws -> CertificateVerificationResult)?
        {
            switch self.backing {
            case .tls, .plaintext:
                // A custom certificate verification callback is an mTLS concept (the callback verifies the certificates
                // presented by the client); it doesn't apply for plaintext and TLS.
                return nil

            case .mTLS(_, let trustRoots):
                switch trustRoots.backing {
                case .customCertificateVerificationCallback(let callback):
                    return callback

                case .systemDefaults, .inMemory, .pemFile:
                    return nil
                }
            }
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

        /// The graceful shutdown configuration.
        public var gracefulShutdown: GracefulShutdownConfiguration

        /// Configuration options for HTTP/2 graceful shutdown behavior.
        public struct GracefulShutdownConfiguration: Sendable, Hashable {
            /// The maximum amount of time that the connection has to close gracefully.
            /// If set to `nil`, no time limit is enforced on the graceful shutdown process.
            public var maximumGracefulShutdownDuration: Duration?

            /// Creates a graceful shutdown configuration with the specified timeout value.
            ///
            /// - Parameters:
            ///   - maximumGracefulShutdownDuration: The maximum amount of time that the connection has to close
            ///     gracefully. When `nil`, no time limit is enforced for active streams to finish during graceful
            ///     shutdown.
            public init(maximumGracefulShutdownDuration: Duration? = nil) {
                self.maximumGracefulShutdownDuration = maximumGracefulShutdownDuration
            }
        }

        /// - Parameters:
        ///   - maxFrameSize: The maximum frame size to be used in connections.
        ///   - targetWindowSize: The target window size for connections. This will also be set as the initial window
        ///     size.
        ///   - maxConcurrentStreams: The maximum number of concurrent streams permitted on connections.
        ///   - gracefulShutdown: The graceful shutdown configuration.
        public init(
            maxFrameSize: Int = Self.defaultMaxFrameSize,
            targetWindowSize: Int = Self.defaultTargetWindowSize,
            maxConcurrentStreams: Int? = Self.defaultMaxConcurrentStreams,
            gracefulShutdown: GracefulShutdownConfiguration = .init()
        ) {
            self.maxFrameSize = maxFrameSize
            self.targetWindowSize = targetWindowSize
            self.maxConcurrentStreams = maxConcurrentStreams
            self.gracefulShutdown = gracefulShutdown
        }

        @inlinable
        static var defaultMaxFrameSize: Int { 1 << 14 }

        @inlinable
        static var defaultTargetWindowSize: Int { (1 << 16) - 1 }

        @inlinable
        static var defaultMaxConcurrentStreams: Int? { nil }

        /// Default values. The max frame size defaults to 2^14, the target window size defaults to 2^16-1, and
        /// the max concurrent streams default to infinite.
        public static var defaults: Self {
            Self(
                maxFrameSize: Self.defaultMaxFrameSize,
                targetWindowSize: Self.defaultTargetWindowSize,
                maxConcurrentStreams: Self.defaultMaxConcurrentStreams,
                gracefulShutdown: GracefulShutdownConfiguration()
            )
        }
    }

    /// Configuration for the backpressure strategy to use when reading requests and writing back responses.
    public struct BackPressureStrategy: Sendable {
        enum Backing {
            case watermark(low: Int, high: Int)
        }

        internal let backing: Backing

        init(backing: Backing) {
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

        @inlinable
        static var defaultWatermarkLow: Int { 2 }

        @inlinable
        static var defaultWatermarkHigh: Int { 10 }

        /// Default values. The watermark low value defaults to 2, and the watermark high value default to 10.
        public static var defaults: Self {
            Self.init(
                backing: .watermark(
                    low: Self.defaultWatermarkLow,
                    high: Self.defaultWatermarkHigh
                )
            )
        }
    }

    /// Network binding configuration specifying all addresses where the server should listen.
    public var bindTargets: [BindTarget]

    /// TLS configuration for the server.
    public var transportSecurity: TransportSecurity

    /// The HTTP protocol versions the server advertises and accepts connections for.
    public var supportedHTTPVersions: Set<HTTPVersion>

    /// Backpressure strategy to use in the server.
    public var backpressureStrategy: BackPressureStrategy

    /// Create a new configuration with multiple bind targets.
    /// - Parameters:
    ///   - bindTargets: An array of ``BindTarget`` values specifying where the server should listen.
    ///   - supportedHTTPVersions: The HTTP protocol versions the server should support.
    ///   - transportSecurity: The transport security mode (plaintext, TLS, or mTLS).
    ///   - backpressureStrategy: A ``BackPressureStrategy``.
    ///   Defaults to ``BackPressureStrategy/watermark(low:high:)`` with a low watermark of 2 and a high of 10.
    public init(
        bindTargets: [BindTarget],
        supportedHTTPVersions: Set<HTTPVersion>,
        transportSecurity: TransportSecurity,
        backpressureStrategy: BackPressureStrategy = .defaults
    ) throws {
        if bindTargets.isEmpty {
            throw NIOHTTPServerConfigurationError.noBindTargetsSpecified
        }

        // If `transportSecurity`` is set to `.plaintext`, the server can only support HTTP/1.1.
        // To support HTTP/2, `transportSecurity` must be set to `.tls` or `.mTLS`.
        if case .plaintext = transportSecurity.backing {
            guard supportedHTTPVersions == [.http1_1] else {
                throw NIOHTTPServerConfigurationError.incompatibleTransportSecurity
            }
        }

        if supportedHTTPVersions.isEmpty {
            throw NIOHTTPServerConfigurationError.noSupportedHTTPVersionsSpecified
        }

        self.bindTargets = bindTargets
        self.supportedHTTPVersions = supportedHTTPVersions
        self.transportSecurity = transportSecurity
        self.backpressureStrategy = backpressureStrategy
    }

    /// Create a new configuration with a single bind target.
    /// - Parameters:
    ///   - bindTarget: A ``BindTarget``.
    ///   - supportedHTTPVersions: The HTTP protocol versions the server should support.
    ///   - transportSecurity: The transport security mode (plaintext, TLS, or mTLS).
    ///   - backpressureStrategy: A ``BackPressureStrategy``.
    ///   Defaults to ``BackPressureStrategy/watermark(low:high:)`` with a low watermark of 2 and a high of 10.
    public init(
        bindTarget: BindTarget,
        supportedHTTPVersions: Set<HTTPVersion>,
        transportSecurity: TransportSecurity,
        backpressureStrategy: BackPressureStrategy = .defaults
    ) throws {
        try self.init(
            bindTargets: [bindTarget],
            supportedHTTPVersions: supportedHTTPVersions,
            transportSecurity: transportSecurity,
            backpressureStrategy: backpressureStrategy
        )
    }
}

/// Represents the outcome of certificate verification.
///
/// Indicates whether certificate verification succeeded or failed, and provides associated metadata when verification
/// is successful.
@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
public enum CertificateVerificationResult: Sendable, Hashable {
    /// Metadata resulting from successful certificate verification.
    public struct VerificationMetadata: Sendable, Hashable {
        /// A container for the validated certificate chain: an array of certificates forming a verified and ordered
        /// chain of trust, starting from the peer's leaf certificate to a trusted root certificate.
        public var validatedCertificateChain: X509.ValidatedCertificateChain?

        /// Creates an instance with the peer's *validated* certificate chain.
        ///
        /// - Parameter validatedCertificateChain: An optional *validated* certificate chain. If provided, it must
        ///   **only** contain the **validated** chain of trust that was built and verified from the certificates
        ///   presented by the peer.
        public init(_ validatedCertificateChain: X509.ValidatedCertificateChain?) {
            self.validatedCertificateChain = validatedCertificateChain
        }
    }

    /// An error representing certificate verification failure.
    public struct VerificationError: Swift.Error, Hashable {
        public let reason: String

        /// Creates a verification error with the reason why verification failed.
        /// - Parameter reason: The reason of why certificate verification failed.
        public init(reason: String) {
            self.reason = reason
        }
    }

    /// Certificate verification succeeded.
    ///
    /// The associated metadata contains information captured during verification.
    case certificateVerified(VerificationMetadata)

    /// Certificate verification failed.
    case failed(VerificationError)
}

/// Represents the certificate verification behavior.
public struct CertificateVerificationMode: Sendable {
    enum VerificationMode {
        case optionalVerification
        case noHostnameVerification
    }

    let mode: VerificationMode

    /// Allows peers to connect without presenting any certificates. However, if the peer *does* present
    /// certificates, they are validated like normal (exactly like with ``noHostnameVerification``), and the TLS
    /// handshake will fail if verification fails.
    ///
    /// - Warning: With this mode, a peer can successfully connect even without presenting any certificates. As such,
    ///   this mode must be used with great caution.
    public static var optionalVerification: Self {
        Self(mode: .optionalVerification)
    }

    /// Validates the certificates presented by the peer but skips hostname verification as it cannot succeed in
    /// a server context.
    public static var noHostnameVerification: Self {
        Self(mode: .noHostnameVerification)
    }
}

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOSSL.CertificateVerification {
    /// Maps ``CertificateVerificationMode`` to the NIOSSL representation.
    init(_ verificationMode: CertificateVerificationMode) {
        switch verificationMode.mode {
        case .noHostnameVerification:
            self = .noHostnameVerification
        case .optionalVerification:
            self = .optionalVerification
        }
    }
}

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOHTTPServerConfiguration {
    /// Represents an HTTP version.
    public struct HTTPVersion: Sendable, Hashable {
        enum Version {
            case http1_1
            case http2(config: HTTP2)

            /// The HTTP/2 configuration if this version is HTTP/2, or `nil` if it is HTTP/1.1.
            var http2Config: HTTP2? {
                switch self {
                case .http1_1:
                    return nil
                case .http2(let config):
                    return config
                }
            }
        }

        let version: Version

        /// The HTTP/1.1 protocol version.
        public static var http1_1: Self {
            Self(version: .http1_1)
        }

        /// The HTTP/2 protocol version.
        ///
        /// - Parameter config: The configuration to use for HTTP/2.
        public static func http2(config: HTTP2) -> Self {
            Self(version: .http2(config: config))
        }

        /// Two values are equal if they represent the same protocol version, regardless of any differences in HTTP/2
        /// configuration.
        public static func == (lhs: Self, rhs: Self) -> Bool {
            switch (lhs.version, rhs.version) {
            case (.http1_1, .http1_1), (.http2, .http2):
                return true

            default:
                return false
            }
        }

        /// Hashes by protocol version only. Consistent with the `Equatable` conformance.
        public func hash(into hasher: inout Hasher) {
            switch self.version {
            case .http1_1:
                hasher.combine(1)

            case .http2:
                hasher.combine(2)
            }
        }
    }
}

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOAsyncSequenceProducerBackPressureStrategies.HighLowWatermark {
    init(_ backpressureStrategy: NIOHTTPServerConfiguration.BackPressureStrategy) {
        switch backpressureStrategy.backing {
        case .watermark(let low, let high):
            self.init(lowWatermark: low, highWatermark: high)
        }
    }
}

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension Set where Element == NIOHTTPServerConfiguration.HTTPVersion {
    /// The ALPN protocol identifiers to advertise during the TLS handshake, derived from the supported HTTP versions.
    ///
    /// Returns `"h2"` if HTTP/2 is supported, and `"http/1.1"` if HTTP/1.1 is supported, in that order of preference.
    var alpnIdentifiers: [String] {
        var identifiers = [String]()

        if self.http2ConfigIfSupported != nil {
            identifiers.append("h2")
        }

        if self.contains(.http1_1) {
            identifiers.append("http/1.1")
        }

        return identifiers
    }

    /// The HTTP/2 configuration if HTTP/2 is among the supported versions, or `nil` if only HTTP/1.1 is supported.
    var http2ConfigIfSupported: NIOHTTPServerConfiguration.HTTP2? {
        self.compactMap({ $0.version.http2Config }).first
    }
}
