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

#if HTTP3
import NIOQUIC

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP3 {
    /// QUIC transport configuration for an HTTP/3 server.
    public struct QUICConfiguration: Sendable, Hashable {
        /// Configuration for writing qlog files, which capture QUIC and HTTP/3 events for debugging and analysis.
        ///
        /// - SeeAlso: https://www.ietf.org/archive/id/draft-ietf-quic-qlog-main-schema-13.html
        public struct QLogConfiguration: Sendable, Hashable {
            /// The directory to where the qlog files are written to.
            public var path: String

            /// The title to use when logging.
            public var topic: String

            /// The description to use when logging.
            public var description: String

            /// Creates a qlog configuration with the given directory, topic, and description.
            ///
            /// - Parameters:
            ///   - path: The directory to write qlog files to.
            ///   - topic: The title to use when logging.
            ///   - description: The description to use when logging.
            public init(path: String, topic: String, description: String) {
                self.path = path
                self.topic = topic
                self.description = description
            }
        }

        /// The TLS 1.3 key exchange named group.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc8446#section-4.2.7 and
        ///   https://www.iana.org/assignments/tls-parameters/tls-parameters.xhtml#tls-parameters-8
        public struct KeyExchangeGroup: Sendable, Hashable {
            enum Backing: UInt16 {
                case secp256 = 0x0017
                case secp384 = 0x0018
                case x25519 = 0x001D
                case x25519MLKEM768 = 0x11EC
            }

            let backing: Backing

            /// The NIST P-256 elliptic curve.
            public static var secp256: Self {
                .init(backing: .secp256)
            }

            /// The NIST P-384 elliptic curve.
            public static var secp384: Self {
                .init(backing: .secp384)
            }

            /// The X25519 elliptic curve (Curve25519).
            public static var x25519: Self {
                .init(backing: .x25519)
            }

            /// A post-quantum hybrid group that combines X25519 with the ML-KEM-768 key encapsulation mechanism.
            public static var x25519MLKEM768: Self {
                .init(backing: .x25519MLKEM768)
            }
        }

        /// The server's hostname for the TLS handshake.
        ///
        /// - Important: SwiftTLS currently just ignores the server name sent in the ClientHello. See
        ///   https://github.com/apple/swift-nio-quic/issues/4.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc6066#section-3
        public var serverName: String

        /// The named group to use for the TLS 1.3 key exchange.
        public var keyExchangeGroup: KeyExchangeGroup

        /// The idle timeout advertised to the client. A connection may time out sooner than this value if the client
        /// advertises a shorter idle timeout.
        ///
        /// - Important: The effective idle timeout enforced on a connection is the minimum of both endpoints'
        ///   advertised values.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc9000#section-18.2-4.4.1 and
        ///   https://datatracker.ietf.org/doc/html/rfc9000#name-idle-timeout
        public var maxIdleTimeout: Duration

        /// The initial value for the maximum amount of data (in bytes) that can be sent on the connection.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc9000#section-18.2-4.14.1
        public var initialMaxData: Int

        /// The initial flow control limit for locally initiated bidirectional streams.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc9000#section-18.2-4.16.1
        public var initialMaxStreamDataBidirectionalLocal: Int

        /// The initial flow control limit for client-initiated bidirectional streams.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc9000#section-18.2-4.18.1
        public var initialMaxStreamDataBidirectionalRemote: Int

        /// The initial flow control limit for unidirectional streams.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc9000#section-18.2-4.20.1
        public var initialMaxStreamDataUnidirectional: Int

        /// The initial maximum number of bidirectional streams the server is permitted to initiate.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc9000#section-18.2-4.22.1
        public var initialMaxStreamsBidirectional: Int

        /// The initial maximum number of unidirectional streams the server is permitted to initiate.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc9000#section-18.2-4.24.1
        public var initialMaxStreamsUnidirectional: Int

        /// The interval at which the server sends keep-alive PING frames.
        ///
        /// Each PING restarts both endpoints' idle timers. The server's idle timer is restarted when the PING is sent,
        /// and the peer's idle timer is restarted when the PING is received. This prevents the connection from being
        /// closed by ``maxIdleTimeout``.
        ///
        /// - Important: For keep-alive pings to be effective, the interval must be shorter than the negotiated idle
        ///   timeout.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc9000#section-10.1.2
        public var keepAliveInterval: Duration?

        /// Whether the server sends a Retry packet before accepting a new connection.
        ///
        /// - SeeAlso: https://datatracker.ietf.org/doc/html/rfc9000#section-8.1.2
        public var sendRetry: Bool

        /// The path to a file where TLS session keys are logged in NSS Key Log format.
        ///
        /// When set, tools such as Wireshark can use this file to decrypt captured QUIC traffic.
        public var keyLogPath: String?

        /// Optional qlog configuration.
        ///
        /// When set, QUIC and HTTP/3 events are written to qlog files in the specified directory, which is useful for
        /// debugging and analysis.
        public var qLogConfiguration: QLogConfiguration?

        /// The default QUIC transport configuration.
        ///
        /// Uses the following default values:
        /// - `keyExchangeGroup`: ``KeyExchangeGroup/x25519``.
        /// - `maxIdleTimeout`: 30 seconds.
        /// - `initialMaxData`: 1 MiB.
        /// - `initialMaxStreamDataBidirectionalLocal`: 1 MiB.
        /// - `initialMaxStreamDataBidirectionalRemote`: 1 MiB.
        /// - `initialMaxStreamDataUnidirectional`: 1 MiB.
        /// - `initialMaxStreamsBidirectional`: 100 streams.
        /// - `initialMaxStreamsUnidirectional`: 100 streams.
        /// - `keepAliveInterval`: `nil` (no keep-alive PINGs are sent).
        /// - `sendRetry`: `false`.
        /// - `keyLogPath`: `nil` (TLS session keys are not logged).
        /// - `qLogConfiguration`: `nil` (qlog is not enabled).
        public static var defaults: Self {
            Self(
                // SwiftTLS currently just ignores the `serverName` sent in the ClientHello. This default configuration
                // just sets `serverName` to an empty string. See https://github.com/apple/swift-nio-quic/issues/4.
                serverName: "",
                keyExchangeGroup: .x25519,
                maxIdleTimeout: .seconds(30),
                initialMaxData: 1024 * 1024,
                initialMaxStreamDataBidirectionalLocal: 1024 * 1024,
                initialMaxStreamDataBidirectionalRemote: 1024 * 1024,
                initialMaxStreamDataUnidirectional: 1024 * 1024,
                initialMaxStreamsBidirectional: 100,
                initialMaxStreamsUnidirectional: 100,
                keepAliveInterval: nil,
                sendRetry: false,
                keyLogPath: nil,
                qLogConfiguration: nil
            )
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOQUIC.QUICConfiguration.QLogConfiguration {
    fileprivate init(_ configuration: NIOHTTPServerConfiguration.HTTP3.QUICConfiguration.QLogConfiguration) {
        self.init(
            path: configuration.path,
            topic: configuration.topic,
            description: configuration.description
        )
    }
}

@available(anyAppleOS 26.0, *)
extension NIOQUIC.KeyExchangeGroup {
    fileprivate init(_ configuration: NIOHTTPServerConfiguration.HTTP3.QUICConfiguration.KeyExchangeGroup) {
        switch configuration.backing {
        case .secp256:
            self = .secp256

        case .secp384:
            self = .secp384

        case .x25519:
            self = .x25519

        case .x25519MLKEM768:
            self = .x25519MLKEM768
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOQUIC.AuthenticationConfiguration {
    init(_ tlsCredentials: NIOHTTPServerConfiguration.TransportSecurity.TLSCredentials) throws {
        switch tlsCredentials.backing {
        case .x509(let x509Credentials):
            switch x509Credentials.backing {
            case .serialized(.file(let certificateChain, let privateKey, format: .pem)):
                self = .x509Certificates(certificateChainFilePath: certificateChain, privateKeyFilePath: privateKey)

            case .certificates, .reloading, .serialized(.file(_, _, .der)), .serialized(.bytes):
                throw NIOHTTPServerConfigurationError.onlyPEMFileX509CredentialsCurrentlySupportedOverHTTP3
            }

        case .rawPublicKey(let rawPublicKeyCredentials):
            switch rawPublicKeyCredentials.backing {
            case .file(let publicKey, let privateKey, .der):
                self = .rawPublicKeys(publicKeyFilePath: publicKey, privateKeyFilePath: privateKey)

            case .file(_, _, .pem):
                throw NIOHTTPServerConfigurationError.pemRawPublicKeysNotCurrentlySupported
            }
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOQUIC.QUICConfiguration {
    /// Creates a `NIOQUIC.QUICConfiguration` from a `NIOHTTPServerConfiguration.HTTP3.QUICConfiguration` instance.
    init(
        _ config: NIOHTTPServerConfiguration.HTTP3.QUICConfiguration,
        authenticationConfiguration: NIOQUIC.AuthenticationConfiguration
    ) {
        self = .server(
            // SwiftTLS currently just ignores the `serverName` sent in the ClientHello. See
            // https://github.com/apple/swift-nio-quic/issues/4.
            serverName: config.serverName,
            authenticationConfiguration: authenticationConfiguration,
            keyExchangeGroup: .init(config.keyExchangeGroup),
            applicationProtocols: ["h3"],
            maxIdleTimeout: config.maxIdleTimeout,
            initialMaxData: config.initialMaxData,
            initialMaxStreamDataBidiLocal: config.initialMaxStreamDataBidirectionalLocal,
            initialMaxStreamDataBidiRemote: config.initialMaxStreamDataBidirectionalRemote,
            initialMaxStreamDataUni: config.initialMaxStreamDataUnidirectional,
            initialMaxStreamsBidi: config.initialMaxStreamsBidirectional,
            initialMaxStreamsUni: config.initialMaxStreamsUnidirectional,
            keepAliveInterval: config.keepAliveInterval,
            sendRetry: config.sendRetry,
            keyLogPath: config.keyLogPath,
            qLogConfiguration: config.qLogConfiguration.map { .init($0) }
        )
    }
}

@available(anyAppleOS 26.0, *)
extension NIOQUIC.Authenticator {
    /// Creates an `Authenticator` instance from X.509 TLS credentials.
    ///
    /// Returns `nil` for raw public key credentials, because NIOQUIC reads the public/private key paths directly from
    /// `QUICConfiguration.authenticationConfiguration` (no `Authenticator` instance is required in that case).
    ///
    /// - Parameter tlsCredentials: The server's TLS credentials.
    ///
    /// - Throws:
    ///   - ``NIOHTTPServerConfigurationError/onlyPEMFileCredentialsCurrentlySupportedOverHTTP3`` if X.509 credentials
    ///     are not provided as a PEM-encoded certificate chain and private key on disk.
    ///   - An underlying error from `Authenticator`'s initializer if the certificate chain or private key cannot be
    ///     loaded.
    convenience init?(_ tlsCredentials: NIOHTTPServerConfiguration.TransportSecurity.TLSCredentials) throws {
        switch tlsCredentials.backing {
        case .rawPublicKey:
            // Public/private key paths are read directly from `QUICConfiguration.authenticationConfiguration`, so we
            // return `nil` here.
            return nil

        case .x509(let x509Credentials):
            switch x509Credentials.backing {
            case .reloading, .serialized(.bytes), .serialized(.file(_, _, .der)), .certificates:
                throw NIOHTTPServerConfigurationError.onlyPEMFileX509CredentialsCurrentlySupportedOverHTTP3

            case .serialized(.file(let certificateChain, let privateKey, .pem)):
                try self.init(certificateFilePath: certificateChain, privateKeyFilePath: privateKey)
            }
        }
    }
}
#endif  // HTTP3
