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
    /// Validates the compatibility of the `supportedHTTPVersions` and `transportSecurity` configurations, and stores
    /// the TLS resources required to set up the server channels.
    mutating func validateTransportConfiguration() throws {
        #if HTTP3
        (self.quicAuthenticationConfiguration, self.quicAuthenticator) = try self.makeQUICAuthentication()
        #endif

        self.sslContext = try self.makeSSLContext()
    }

    /// Creates the `NIOSSLContext` used by the secure upgrade channel(s), or `nil` if the configuration does not
    /// specify a secure upgrade channel.
    private func makeSSLContext() throws -> NIOSSLContext? {
        #if HTTP3
        if self.supportedHTTPVersions.http3ConfigIfSupported != nil, self.supportedHTTPVersions.count == 1 {
            // Only HTTP/3 was specified. As such, `NIOSSLContext` is not needed because a secure upgrade channel won't
            // be set up. We can just return `nil` here.
            return nil
        }
        #endif

        switch self.transportSecurity.backing {
        case .plaintext:
            // Only HTTP/1.1 can be served over plaintext. To serve HTTP/2, `transportSecurity` must be set to `.tls` or
            // `.mTLS`.
            guard self.supportedHTTPVersions == [.http1_1] else {
                throw NIOHTTPServerConfigurationError.incompatibleTransportSecurity
            }
            return nil

        case .tls, .mTLS:
            return try .makeServerContext(
                transportSecurity: self.transportSecurity,
                alpnIdentifiers: self.supportedHTTPVersions.alpnIdentifiers
            )
        }
    }

    #if HTTP3
    /// Creates the QUIC authentication resources used by the HTTP/3 channel(s).
    ///
    /// Both are `nil` if HTTP/3 is not among ``supportedHTTPVersions``.
    private func makeQUICAuthentication() throws -> (
        configuration: NIOQUIC.AuthenticationConfiguration?,
        authenticator: NIOQUIC.Authenticator?
    ) {
        guard self.supportedHTTPVersions.http3ConfigIfSupported != nil else { return (nil, nil) }

        switch self.transportSecurity.backing {
        case .plaintext:
            // Only HTTP/1.1 can be served over plaintext. To serve HTTP/3, `transportSecurity` must be set to `.tls`.
            throw NIOHTTPServerConfigurationError.incompatibleTransportSecurity

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
            return (configuration: try .init(tlsCredentials), authenticator: try .init(tlsCredentials))

        case .mTLS:
            throw NIOHTTPServerConfigurationError.mTLSNotCurrentlySupportedOverHTTP3
        }
    }
    #endif  // HTTP3
}
