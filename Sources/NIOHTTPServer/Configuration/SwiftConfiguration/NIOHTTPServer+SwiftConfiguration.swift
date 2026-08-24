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

#if Configuration
public import Configuration
import NIOCore
import NIOCertificateReloading
import NIOHTTP2
import SwiftASN1
public import X509
import System

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration {
    /// Initialize the server configuration from a config reader.
    ///
    /// ## Configuration keys:
    ///
    /// ``NIOHTTPServerConfiguration`` is comprised of four types. Provide configuration for each type under the
    /// specified key:
    ///
    /// - **`"bindTarget"`**: A single address and port to bind to (see ``BindTarget/init(config:)``). Use this when
    ///   binding to exactly one address.
    ///
    /// - **`"bindTargets"`**: Multiple addresses to bind to, provided as parallel string and int arrays under
    ///   `bindTargets.hosts` and `bindTargets.ports`. Exactly one of `"bindTarget"` or `"bindTargets"` must be
    ///   provided.
    ///
    /// - **`"http"`**: Supported HTTP versions and per-version settings:
    ///   - `"versions"` (required string array): the HTTP versions to support (permitted values: `"http1_1"`,
    ///      `"http2"`, `"http3"`).
    ///   - `"http2"`: HTTP/2 settings, read when `"http2"` is contained in `"versions"` (see ``HTTP2/init(config:)``).
    ///   - `"http3"`: HTTP/3 settings, read when `"http3"` is contained in `"versions"` (see ``HTTP3/init(config:)``).
    ///
    /// - **`"transportSecurity"`**: The transport security mode: plaintext, TLS, or mTLS (see
    ///   ``TransportSecurity/init(config:customCertificateVerificationCallback:)``).
    ///
    /// - **`"backpressureStrategy"`**: The backpressure strategy (see ``BackPressureStrategy/init(config:)``).
    ///
    /// - Parameters:
    ///   - config: The configuration reader to read configuration values from.
    ///   - customCertificateVerificationCallback: A custom client certificate verification callback. This must be
    ///     provided when `transportSecurity.trustRootsSource` is `"customCertificateVerificationCallback"`, and must be
    ///     `nil` otherwise.
    ///     - Throws `NIOHTTPServerConfigurationError/customVerificationCallbackProvidedWhenNotUsingMTLS` if provided
    ///       when `transportSecurity.mode` is not `"mTLS"`.
    ///     - Throws `NIOHTTPServerSwiftConfigurationError/trustRootsSourceAndVerificationCallbackMismatch` if there
    ///       is a mismatch between `transportSecurity.trustRootsSource` and whether a custom certificate verification
    ///       callback is provided.
    ///     - Throws `NIOHTTPServerSwiftConfigurationError/singularAndPluralBindTargetsProvided` if both
    ///       `"bindTarget"` and `"bindTargets"` are provided.
    ///     - Throws `NIOHTTPServerSwiftConfigurationError/bindTargetsHostsAndPortsLengthMismatch` if
    ///       `bindTargets.hosts` and `bindTargets.ports` have different lengths.
    public init(
        config: ConfigReader,
        customCertificateVerificationCallback: (
            @Sendable ([Certificate]) async throws -> CertificateVerificationResult
        )? = nil
    ) throws {
        let snapshot = config.snapshot()

        try self.init(
            bindTargets: try Self.readBindTargets(from: snapshot),
            supportedHTTPVersions: try .init(config: snapshot.scoped(to: "http")),
            transportSecurity: try .init(
                config: snapshot.scoped(to: "transportSecurity"),
                customCertificateVerificationCallback: customCertificateVerificationCallback
            )
        )
        self.backpressureStrategy = .init(config: snapshot.scoped(to: "backpressureStrategy"))
        self.maxConnections = snapshot.int(forKey: "maxConnections")
        self.connectionTimeouts = .init(config: snapshot.scoped(to: "connectionTimeouts"))
    }

    /// Reads bind targets from either the singular `bindTarget` scope or the plural `bindTargets` scope.
    /// Exactly one of the two must be provided.
    private static func readBindTargets(
        from snapshot: ConfigSnapshotReader
    ) throws -> [BindTarget] {
        let bindTargetsScope = snapshot.scoped(to: "bindTargets")
        let hosts = bindTargetsScope.stringArray(forKey: "hosts")
        let ports = bindTargetsScope.intArray(forKey: "ports")
        let hasPlural = hosts != nil || ports != nil

        let bindTargetScope = snapshot.scoped(to: "bindTarget")
        let singularHost = bindTargetScope.string(forKey: "host")
        let singularPort = bindTargetScope.int(forKey: "port")
        let singularSocketPath = bindTargetScope.string(forKey: "socketPath")
        let hasSingular = singularHost != nil || singularPort != nil || singularSocketPath != nil

        if hasSingular && hasPlural {
            throw NIOHTTPServerSwiftConfigurationError.singularAndPluralBindTargetsProvided
        }

        if hasPlural {
            let hosts = hosts ?? []
            let ports = ports ?? []
            guard hosts.count == ports.count else {
                throw NIOHTTPServerSwiftConfigurationError.bindTargetsHostsAndPortsLengthMismatch
            }
            return zip(hosts, ports).map { .hostAndPort(host: $0, port: $1) }
        }

        return [try BindTarget(config: bindTargetScope)]
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.BindTarget {
    /// Initialize a bind target configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `host` (string): The hostname or IP address to bind to. Required unless `socketPath` is given.
    /// - `port` (int): The port to listen on. Required unless `socketPath` is given.
    /// - `socketPath` (string): A unix domain socket path to bind to. Mutually exclusive with `host`/`port`.
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) throws {
        let host = config.string(forKey: "host")
        let port = config.int(forKey: "port")
        let socketPath = config.string(forKey: "socketPath")

        let backing: Backing
        if let socketPath {
            guard host == nil, port == nil else {
                throw NIOHTTPServerSwiftConfigurationError.hostPortAndSocketPathProvided
            }
            let filePath = FilePath(socketPath)
            backing = .unixDomainSocket(path: filePath)
        } else {
            backing = .hostAndPort(
                host: try config.requiredString(forKey: "host"),
                port: try config.requiredInt(forKey: "port")
            )
        }

        self.init(backing: backing)
    }
}

@available(anyAppleOS 26.0, *)
extension Set where Element == NIOHTTPServerConfiguration.HTTPVersion {
    /// Initialize a supported HTTP versions configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `versions` (string array, required): A set of HTTP versions the server should support (permitted values:
    ///    `"http1_1"`, `"http2"`, `"http3"`).
    ///    - If `"http2"` and/or `"http3"` are contained in this array, the corresponding protocol configuration can be
    ///      specified under the `"http2"` or `"http3"` key respectively. See
    ///      ``NIOHTTPServerConfiguration/HTTP2/init(config:)`` and ``NIOHTTPServerConfiguration/HTTP3/init(config:)``
    ///      for the supported keys.
    ///
    /// - Throws `NIOHTTPServerConfigurationError/noSupportedHTTPVersionsSpecified` if no supported HTTP versions are
    ///   specified under the "versions" key.
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) throws {
        self = .init()

        let versions = Set<HTTPVersionKind>(
            try config.requiredStringArray(forKey: "versions", as: HTTPVersionKind.self)
        )

        if versions.isEmpty {
            throw NIOHTTPServerConfigurationError.noSupportedHTTPVersionsSpecified
        }

        for version in versions {
            switch version {
            case .http1_1:
                self.insert(.http1_1)

            case .http2:
                let h2Config = NIOHTTPServerConfiguration.HTTP2(config: config.scoped(to: "http2"))
                self.insert(.http2(config: h2Config))

            #if HTTP3
            case .http3:
                let h3Config = try NIOHTTPServerConfiguration.HTTP3(config: config.scoped(to: "http3"))
                self.insert(.http3(config: h3Config))
            #endif
            }
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity {
    /// Initialize a transport security configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `mode` (string, required): The transport security mode for the server (permitted values: `"plaintext"`,
    ///   `"tls"`, `"mTLS"`).
    /// - `credentialSource` (string, required for `"tls"` and `"mTLS"`): How TLS credentials are provided (permitted
    ///   values: `"inline"`, `"file"`, `"rawPublicKey"`).
    ///
    /// ### Configuration keys for `credentialSource: "inline"`:
    /// - `certificateChainPEMString` (string, required): PEM-formatted certificate chain content.
    /// - `privateKeyPEMString` (string, required, secret): PEM-formatted private key content.
    ///
    /// ### Configuration keys for `credentialSource: "file"`:
    /// - `certificateChainPEMPath` (string, required): Path to the certificate chain PEM file.
    /// - `privateKeyPEMPath` (string, required): Path to the private key PEM file.
    /// - `refreshInterval` (int, optional): The interval (in seconds) at which the certificate chain and private key
    ///    will be reloaded. If omitted, credentials are loaded from the file only once at startup.
    ///
    /// ### Configuration keys for `credentialSource: "rawPublicKey"` (only supported over HTTP/3):
    /// - `publicKeyDERPath` (string, required): Path to the DER-encoded public key file.
    /// - `privateKeyDERPath` (string, required): Path to the DER-encoded private key file.
    ///
    /// ### Configuration keys for `mode: "mTLS"` (not supported over HTTP/3):
    /// - `trustRootsSource` (string, required): How trust roots are provided (permitted values: `"inline"`, `"file"`,
    ///    `"systemDefaults"`, `"customCertificateVerificationCallback"`).
    /// - `trustRootsPEMString` (string, required for `trustRootsSource: "inline"`): The root certificates as a
    ///    PEM-encoded string.
    /// - `trustRootsPEMPath` (string, required for `trustRootsSource: "file"`): Path to a PEM file containing root
    ///    certificates.
    /// - `certificateVerificationMode` (string, required): The client certificate validation behavior (permitted
    ///    values: "optionalVerification" or "noHostnameVerification").
    ///
    /// - Parameters:
    ///   - config: The configuration reader.
    ///   - customCertificateVerificationCallback: A custom client certificate verification callback. This argument must
    ///     be provided when `trustRootsSource` is `"customCertificateVerificationCallback"`, and must be `nil`
    ///     otherwise.
    ///     - Throws `NIOHTTPServerConfigurationError/customVerificationCallbackProvidedWhenNotUsingMTLS` if the
    ///       callback is provided when `mode` is not `"mTLS"`.
    ///     - Throws `NIOHTTPServerConfigurationError/trustRootsSourceAndVerificationCallbackMismatch` if there is a
    ///       mismatch between `trustRootsSource` and whether the callback is provided.
    public init(
        config: ConfigSnapshotReader,
        customCertificateVerificationCallback: (
            @Sendable ([Certificate]) async throws -> CertificateVerificationResult
        )? = nil
    ) throws {
        let mode = try config.requiredString(forKey: "mode", as: TransportSecurityMode.self)

        // A custom verification callback can only be used when the server is configured for mTLS.
        if let _ = customCertificateVerificationCallback, mode != .mTLS {
            throw NIOHTTPServerSwiftConfigurationError.customVerificationCallbackProvidedWhenNotUsingMTLS
        }

        switch mode {
        case .plaintext:
            self = .plaintext

        case .tls:
            self = .tls(credentials: try .init(config: config))

        case .mTLS:
            self = .mTLS(
                credentials: try .init(config: config),
                trustConfiguration: try .init(
                    config: config,
                    customCertificateVerificationCallback: customCertificateVerificationCallback
                )
            )
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity.TLSCredentials {
    /// Initialize TLS credentials (certificate chain and private key) from a config reader.
    ///
    /// - When `credentialSource` is `"inline"`, the certificate chain and private key are read as PEM strings.
    /// - When `credentialSource` is `"file"`, the certificate chain and private key are loaded from disk, and
    ///   optionally reloaded at a configured interval.
    /// - When `credentialSource` is `"rawPublicKey"` (only supported over HTTP/3), DER-encoded public and private key
    ///   file paths are read.
    fileprivate init(config: ConfigSnapshotReader) throws {
        let credentialSource = try config.requiredString(
            forKey: "credentialSource",
            as: NIOHTTPServerConfiguration.TransportSecurity.CredentialSource.self
        )

        switch credentialSource {
        case .inline:
            let certificateChainPEMString = try config.requiredString(forKey: "certificateChainPEMString")
            let privateKeyPEMString = try config.requiredString(forKey: "privateKeyPEMString", isSecret: true)

            self = .x509(
                .certificates(
                    chain: try PEMDocument.parseMultiple(pemString: certificateChainPEMString)
                        .map { try Certificate(pemEncoded: $0.pemString) },
                    privateKey: try .init(pemEncoded: privateKeyPEMString)
                )
            )

        case .file:
            let certificateChainPEMPath = try config.requiredString(forKey: "certificateChainPEMPath")
            let privateKeyPEMPath = try config.requiredString(forKey: "privateKeyPEMPath")
            let refreshInterval = config.int(forKey: "refreshInterval")

            if let refreshInterval {
                self = .x509(
                    .reloading(
                        TimedCertificateReloader(
                            refreshInterval: .seconds(refreshInterval),
                            certificateSource: .init(location: .file(path: certificateChainPEMPath), format: .pem),
                            privateKeySource: .init(location: .file(path: privateKeyPEMPath), format: .pem)
                        )
                    )
                )
            } else {
                self = .x509(.pemFile(certificateChainPath: certificateChainPEMPath, privateKeyPath: privateKeyPEMPath))
            }

        #if HTTP3
        case .rawPublicKey:
            self = .rawPublicKey(
                .derFile(
                    publicKeyPath: try config.requiredString(forKey: "publicKeyDERPath"),
                    privateKeyPath: try config.requiredString(forKey: "privateKeyDERPath")
                )
            )
        #endif
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity.MTLSTrustConfiguration {
    /// Initialize an mTLS trust configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `trustRootsSource` (string, required): How trust roots are provided (permitted values: `"inline"`, `"file"`,
    ///    `"systemDefaults"`, `"customCertificateVerificationCallback"`).
    /// - `trustRootsPEMString` (string, required for `trustRootsSource: "inline"`): The trusted root certificates as a
    ///    PEM-encoded string.
    /// - `trustRootsPEMPath` (string, required for `trustRootsSource: "file"`): Path to a PEM file containing trusted
    ///    root certificates.
    /// - `certificateVerificationMode` (string, required): The client certificate validation behavior (permitted
    ///    values: "optionalVerification" or "noHostnameVerification")
    ///
    /// - Parameters:
    ///   - config: The configuration reader.
    ///   - customCertificateVerificationCallback: A client certificate verification callback. Must be provided when
    ///     `trustRootsSource` is `"customCertificateVerificationCallback"`, and must be `nil` otherwise.
    ///
    /// - Throws: `NIOHTTPServerSwiftConfigurationError/trustRootsSourceAndVerificationCallbackMismatch` if:
    ///   - A verification callback is provided when `trustRootsSource != "customCertificateVerificationCallback"`, or;
    ///   - A verification callback is *not* provided when `trustRootsSource == "customCertificateVerificationCallback"`.
    public init(
        config: ConfigSnapshotReader,
        customCertificateVerificationCallback: (
            @Sendable ([X509.Certificate]) async throws -> CertificateVerificationResult
        )?
    ) throws {
        let trustRootsSource = try config.requiredString(forKey: "trustRootsSource", as: TrustRootsSource.self)
        let certificateVerificationMode = try config.requiredString(
            forKey: "certificateVerificationMode",
            as: VerificationMode.self
        )

        if let _ = customCertificateVerificationCallback, trustRootsSource != .customCertificateVerificationCallback {
            throw NIOHTTPServerSwiftConfigurationError.trustRootsSourceAndVerificationCallbackMismatch
        }

        switch trustRootsSource {
        case .inline:
            let trustRootsPEMString = try config.requiredString(forKey: "trustRootsPEMString")
            self.init(
                .certificates(
                    trustRoots: try PEMDocument.parseMultiple(pemString: trustRootsPEMString)
                        .map { try Certificate(pemEncoded: $0.pemString) }
                ),
                certificateVerification: .init(certificateVerificationMode)
            )

        case .file:
            let trustRootsPEMPath = try config.requiredString(forKey: "trustRootsPEMPath")
            self.init(
                .pemFile(trustRootsPath: trustRootsPEMPath),
                certificateVerification: .init(certificateVerificationMode)
            )

        case .systemDefaults:
            self.init(.systemDefaults, certificateVerification: .init(certificateVerificationMode))

        case .customCertificateVerificationCallback:
            guard let customCertificateVerificationCallback else {
                // No custom verification callback provided despite the "trustRootsSource" key being set to
                // "customCertificateVerificationCallback".
                throw NIOHTTPServerSwiftConfigurationError.trustRootsSourceAndVerificationCallbackMismatch
            }

            self.init(
                .customCertificateVerificationCallback(customCertificateVerificationCallback),
                certificateVerification: .init(certificateVerificationMode)
            )
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.BackPressureStrategy {
    /// Initialize the backpressure strategy configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `lowWatermark` (int, optional, default: 2): The threshold below which the consumer will ask the producer to
    ///    produce more elements.
    /// - `highWatermark` (int, optional, default: 10): The threshold above which the producer will stop producing
    ///    elements.
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) {
        self.init(
            backing: .watermark(
                low: config.int(
                    forKey: "lowWatermark",
                    default: NIOHTTPServerConfiguration.BackPressureStrategy.defaultWatermarkLow
                ),
                high: config.int(
                    forKey: "highWatermark",
                    default: NIOHTTPServerConfiguration.BackPressureStrategy.defaultWatermarkHigh
                )
            )
        )
    }
}

@available(anyAppleOS 26.0, *)
extension Set where Element == NIOHTTPServerConfiguration.HTTPVersion {
    fileprivate enum HTTPVersionKind: String {
        case http1_1
        case http2
        #if HTTP3
        case http3
        #endif
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity {
    fileprivate enum TransportSecurityMode: String {
        case plaintext
        case tls
        case mTLS
    }

    fileprivate enum CredentialSource: String {
        case inline
        case file
        #if HTTP3
        case rawPublicKey
        #endif
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity.MTLSTrustConfiguration {
    /// The supported sources for trust roots.
    fileprivate enum TrustRootsSource: String {
        case inline
        case file
        case systemDefaults
        case customCertificateVerificationCallback
    }

    /// A wrapper over ``CertificateVerificationMode``.
    fileprivate enum VerificationMode: String {
        case optionalVerification
        case noHostnameVerification
    }
}

@available(anyAppleOS 26.0, *)
extension CertificateVerificationMode {
    fileprivate init(_ mode: NIOHTTPServerConfiguration.TransportSecurity.MTLSTrustConfiguration.VerificationMode) {
        switch mode {
        case .optionalVerification:
            self.init(mode: .optionalVerification)
        case .noHostnameVerification:
            self.init(mode: .noHostnameVerification)
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.ConnectionTimeouts {
    /// Initialize connection timeouts configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `idle` (int, optional, default: nil): Maximum time in seconds a connection can remain idle.
    /// - `readHeader` (int, optional, default: nil): Maximum time in seconds to receive request headers
    /// after a connection is established.
    /// - `readBody` (int, optional, default: nil): Maximum time in seconds to receive the complete request
    /// body after headers have been received.
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) {
        self.init(
            idle: config.int(forKey: "idle").map { .seconds($0) },
            readHeader: config.int(forKey: "readHeader").map { .seconds($0) },
            readBody: config.int(forKey: "readBody").map { .seconds($0) }
        )
    }
}

#endif  // Configuration
