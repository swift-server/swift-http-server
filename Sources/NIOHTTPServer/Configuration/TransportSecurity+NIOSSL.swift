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

@available(anyAppleOS 26.0, *)
extension NIOSSLContext {
    /// Creates a `NIOSSL.NIOSSLContext` from the server's transport security configuration.
    static func makeServerContext(
        transportSecurity: NIOHTTPServerConfiguration.TransportSecurity,
        alpnIdentifiers: [String]
    ) throws -> Self {
        var configuration: TLSConfiguration

        switch transportSecurity.backing {
        case .plaintext:
            throw NIOHTTPServerConfigurationError.incompatibleTransportSecurity

        case .tls(let tlsCredentials), .mTLS(let tlsCredentials, _):
            switch tlsCredentials.backing {
            case .inMemory(let certificateChain, let privateKey):
                configuration = .makeServerConfiguration(
                    certificateChain: try certificateChain.map { try NIOSSLCertificateSource($0) },
                    privateKey: try NIOSSLPrivateKeySource(privateKey)
                )

            case .reloading(let certificateReloader):
                configuration = try .makeServerConfiguration(certificateReloader: certificateReloader)

            case .pemFile(let certificateChainPath, let privateKeyPath):
                configuration = try .makeServerConfiguration(
                    certificateChain: NIOSSLCertificate.fromPEMFile(certificateChainPath).map { .certificate($0) },
                    privateKey: .privateKey(.init(file: privateKeyPath, format: .pem))
                )
            }
        }

        if case .mTLS(_, let mTLSConfiguration) = transportSecurity.backing {
            switch mTLSConfiguration.backing {
            case .systemDefaults:
                configuration.trustRoots = .default

            case .inMemory(let trustRoots):
                configuration.trustRoots = .certificates(try trustRoots.map { try NIOSSLCertificate($0) })

            case .pemFile(let path):
                configuration.trustRoots = .file(path)

            case .customCertificateVerificationCallback:
                // There are no trust roots when a custom certificate verification callback is specified: the callback
                // itself is responsible for establishing trust.
                ()
            }

            configuration.certificateVerification = .init(mTLSConfiguration.certificateVerification)
        }

        configuration.applicationProtocols = alpnIdentifiers

        return try Self(configuration: configuration)
    }
}
