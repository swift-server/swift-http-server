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

import NIOCertificateReloading
import NIOSSL
import X509

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOSSL.TLSConfiguration {
    /// Creates a `NIOSSL.TLSConfiguration` from the server's TLS credentials and mTLS trust configuration.
    static func makeServerConfiguration(
        tlsCredentials: NIOHTTPServerConfiguration.TransportSecurity.TLSCredentials,
        mTLSConfiguration: NIOHTTPServerConfiguration.TransportSecurity.MTLSTrustConfiguration?
    ) throws -> Self {
        var config: Self

        switch tlsCredentials.backing {
        case .inMemory(let certificateChain, let privateKey):
            config = .makeServerConfiguration(
                certificateChain: try certificateChain.map { try NIOSSLCertificateSource($0) },
                privateKey: try NIOSSLPrivateKeySource(privateKey)
            )

        case .reloading(let certificateReloader):
            config = try .makeServerConfiguration(certificateReloader: certificateReloader)

        case .pemFile(let certificateChainPath, let privateKeyPath):
            config = try .makeServerConfiguration(
                certificateChain: NIOSSLCertificate.fromPEMFile(certificateChainPath).map { .certificate($0) },
                privateKey: .privateKey(.init(file: privateKeyPath, format: .pem))
            )
        }

        if let mTLSConfiguration {
            switch mTLSConfiguration.backing {
            case .systemDefaults:
                config.trustRoots = .default

            case .inMemory(let trustRoots):
                config.trustRoots = .certificates(try trustRoots.map { try NIOSSLCertificate($0) })

            case .pemFile(let path):
                config.trustRoots = .file(path)

            case .customCertificateVerificationCallback:
                // There are no trust roots when a custom certificate verification callback is specified: the callback
                // itself is responsible for establishing trust.
                ()
            }

            config.certificateVerification = .init(mTLSConfiguration.certificateVerification)
        }

        return config
    }
}
