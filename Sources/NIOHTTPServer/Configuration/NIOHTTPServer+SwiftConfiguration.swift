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
    /// - **`"http"`**: Supported HTTP versions and protocol settings. Supported keys are `"versions"`
    ///   (a string array of `"http1_1"` and/or `"http2"`) and, when HTTP/2 is enabled, `"http2"` (see
    ///   ``HTTP2/init(config:)``).
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
            ),
            backpressureStrategy: .init(config: snapshot.scoped(to: "backpressureStrategy"))
        )
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
        let hasSingular = singularHost != nil || singularPort != nil

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
    /// - `host` (string, required): The hostname or IP address the server will bind to (e.g., "localhost", "0.0.0.0").
    /// - `port` (int, required): The port number the server will listen on (e.g., 8080, 443).
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) throws {
        self.init(
            backing: .hostAndPort(
                host: try config.requiredString(forKey: "host"),
                port: try config.requiredInt(forKey: "port")
            )
        )
    }
}

private enum HTTPVersionKind: String {
    case http1_1
    case http2
}

@available(anyAppleOS 26.0, *)
extension Set where Element == NIOHTTPServerConfiguration.HTTPVersion {
    /// Initialize a supported HTTP versions configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `versions` (string array, required): A set of HTTP versions the server should support (permitted values:
    ///    `"http1_1"`, `"http2"`).
    ///    - If `"http2"` is contained in this array, then HTTP/2 configuration can be specified under the `"http2"`
    ///      key. See ``NIOHTTPServerConfiguration/HTTP2/init(config:)`` for the supported keys under `"http2"`.
    ///
    /// - Throws `NIOHTTPServerConfigurationError/noSupportedHTTPVersionsSpecified` if no supported HTTP versions are
    ///   specified under the "versions" key.
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
    ///   values: `"inline"`, `"file"`).
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
    /// ### Configuration keys for `mode: "mTLS"`:
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
    /// When `credentialSource` is `"inline"`, the certificate chain and private key are read as PEM strings from the
    /// configuration. When `"file"`, they are loaded from disk, optionally reloading at a configured interval.
    fileprivate init(config: ConfigSnapshotReader) throws {
        let credentialSource = try config.requiredString(
            forKey: "credentialSource",
            as: NIOHTTPServerConfiguration.TransportSecurity.CredentialSource.self
        )

        switch credentialSource {
        case .inline:
            let certificateChainPEMString = try config.requiredString(forKey: "certificateChainPEMString")
            let privateKeyPEMString = try config.requiredString(forKey: "privateKeyPEMString", isSecret: true)

            self = .inMemory(
                certificateChain: try PEMDocument.parseMultiple(pemString: certificateChainPEMString)
                    .map { try Certificate(pemEncoded: $0.pemString) },
                privateKey: try .init(pemEncoded: privateKeyPEMString)
            )

        case .file:
            let certificateChainPEMPath = try config.requiredString(forKey: "certificateChainPEMPath")
            let privateKeyPEMPath = try config.requiredString(forKey: "privateKeyPEMPath")
            let refreshInterval = config.int(forKey: "refreshInterval")

            if let refreshInterval {
                self = .reloading(
                    certificateReloader: TimedCertificateReloader(
                        refreshInterval: .seconds(refreshInterval),
                        certificateSource: .init(location: .file(path: certificateChainPEMPath), format: .pem),
                        privateKeySource: .init(location: .file(path: privateKeyPEMPath), format: .pem)
                    )
                )
            } else {
                self = .pemFile(
                    certificateChainPath: certificateChainPEMPath,
                    privateKeyPath: privateKeyPEMPath
                )
            }
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
            self = .inMemory(
                trustRoots: try PEMDocument.parseMultiple(pemString: trustRootsPEMString)
                    .map { try Certificate(pemEncoded: $0.pemString) },
                certificateVerification: .init(certificateVerificationMode)
            )

        case .file:
            let trustRootsPEMPath = try config.requiredString(forKey: "trustRootsPEMPath")
            self = .pemFile(
                path: trustRootsPEMPath,
                certificateVerification: .init(certificateVerificationMode)
            )

        case .systemDefaults:
            self = .systemDefaults(certificateVerification: .init(certificateVerificationMode))

        case .customCertificateVerificationCallback:
            guard let customCertificateVerificationCallback else {
                // No custom verification callback provided despite the "trustRootsSource" key being set to
                // "customCertificateVerificationCallback".
                throw NIOHTTPServerSwiftConfigurationError.trustRootsSourceAndVerificationCallbackMismatch
            }

            self = .customCertificateVerificationCallback(
                customCertificateVerificationCallback,
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
extension NIOHTTPServerConfiguration.HTTP2 {
    /// Initialize a HTTP/2 configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `maxFrameSize` (int, optional, default: 2^14): The maximum frame size to be used in an HTTP/2 connection.
    /// - `targetWindowSize` (int, optional, default: 2^16 - 1): The target window size to be used in an HTTP/2
    ///    connection.
    /// - `maxConcurrentStreams` (int, optional, default: 100): The maximum number of concurrent streams in an HTTP/2
    ///    connection.
    /// - `gracefulShutdown.maximumDuration` (int, optional, default: nil): The maximum amount of time (in seconds) that
    ///   the connection has to close gracefully.
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) {
        self.init(
            maxFrameSize: config.int(
                forKey: "maxFrameSize",
                default: NIOHTTPServerConfiguration.HTTP2.defaultMaxFrameSize
            ),
            targetWindowSize: config.int(
                forKey: "targetWindowSize",
                default: NIOHTTPServerConfiguration.HTTP2.defaultTargetWindowSize
            ),
            maxConcurrentStreams: config.int(forKey: "maxConcurrentStreams", default: 100),
            gracefulShutdown: .init(config: config.scoped(to: "gracefulShutdown"))
        )
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP2.GracefulShutdownConfiguration {
    /// Initialize a HTTP/2 graceful shutdown configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `maximumDuration` (int, optional, default: nil): The maximum amount of time (in seconds) that the connection
    ///   has to close gracefully.
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) {
        self.init(
            maximumGracefulShutdownDuration: config.int(forKey: "maximumDuration").map { .seconds($0) }
        )
    }
}

@available(anyAppleOS 26.0, *)
extension Set where Element == NIOHTTPServerConfiguration.HTTPVersion {
    fileprivate enum HTTPVersionKind: String {
        case http1_1
        case http2
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
#endif  // Configuration
