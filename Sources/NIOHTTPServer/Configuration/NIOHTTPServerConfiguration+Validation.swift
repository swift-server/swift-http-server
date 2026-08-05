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

import NIOSSL

#if HTTP3
import NIOQUIC
#endif

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration {
    /// The context required to serve a secure upgrade channel.
    struct ValidatedSecureUpgradeContext {
        let http2Configuration: NIOHTTPServerConfiguration.HTTP2?
        let sslContext: NIOSSLContext
    }

    /// Validates the server configuration and creates the TLS contexts and configurations required to set up the server
    /// channels.
    static func makeValidatedSecureUpgradeConfiguration(
        supportedHTTPVersions: Set<HTTPVersion>,
        transportSecurity: TransportSecurity
    ) throws -> ValidatedSecureUpgradeContext? {
        #if HTTP3
        if supportedHTTPVersions.http3ConfigIfSupported != nil, supportedHTTPVersions.count == 1 {
            // Only HTTP/3 was specified. As such, we do not create a secure upgrade channel.
            return nil
        }
        #endif

        switch transportSecurity.backing {
        case .plaintext:
            // Only HTTP/1.1 can be served over plaintext. To serve HTTP/2, `transportSecurity` must be set to `.tls` or
            // `.mTLS`.
            guard supportedHTTPVersions == [.http1_1] else {
                throw NIOHTTPServerConfigurationError.incompatibleTransportSecurity
            }
            return nil

        case .tls, .mTLS:
            return ValidatedSecureUpgradeContext(
                http2Configuration: supportedHTTPVersions.http2ConfigIfSupported,
                sslContext: try .makeServerContext(
                    transportSecurity: transportSecurity,
                    alpnIdentifiers: supportedHTTPVersions.alpnIdentifiers
                )
            )
        }
    }

    #if HTTP3
    /// The context required to serve an HTTP/3 channel.
    struct ValidatedHTTP3Context {
        let configuration: NIOHTTPServerConfiguration.HTTP3
        let quicAuthConfiguration: NIOQUIC.AuthenticationConfiguration
        let quicAuthenticator: NIOQUIC.Authenticator?
    }

    /// Validates the server configuration and creates the TLS contexts and configurations required to set up the server
    /// channels.
    static func makeValidatedHTTP3Configuration(
        supportedHTTPVersions: Set<HTTPVersion>,
        transportSecurity: TransportSecurity
    ) throws -> ValidatedHTTP3Context? {
        guard let http3Config = supportedHTTPVersions.http3ConfigIfSupported else { return nil }

        switch transportSecurity.backing {
        case .plaintext:
            // Only HTTP/1.1 can be served over plaintext. To serve HTTP/3, `transportSecurity` must be set to `.tls`.
            guard supportedHTTPVersions == [.http1_1] else {
                throw NIOHTTPServerConfigurationError.incompatibleTransportSecurity
            }
            return nil

        case .tls(let tlsCredentials):
            // We unfortunately need to pass forward both an `AuthenticationConfiguration` and an `Authenticator`:
            //
            // - RPK credentials are read from `AuthenticationConfiguration`;
            // - X509 certificates (in-memory or PEM files on disk) are read from `Authenticator`.
            //
            // The problem is that `QUICConfiguration` requires the `AuthenticationConfiguration` argument, *even*
            // when the TLS credentials are X509 certificates. Moreover, `AuthenticationConfiguration` can only be
            // created with *PEM-file backed X509 credentials* (or RPKs), *even though* `Authenticator` supports
            // `swift-certificates` objects as the source.
            let authConfig = try NIOQUIC.AuthenticationConfiguration(tlsCredentials)
            let authenticator = try NIOQUIC.Authenticator(tlsCredentials)

            return ValidatedHTTP3Context(
                configuration: http3Config,
                quicAuthConfiguration: authConfig,
                quicAuthenticator: authenticator
            )

        case .mTLS:
            throw NIOHTTPServerConfigurationError.mTLSNotCurrentlySupportedOverHTTP3
        }
    }
    #endif  // HTTP3
}
