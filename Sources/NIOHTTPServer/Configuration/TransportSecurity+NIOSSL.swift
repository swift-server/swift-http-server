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
            case .x509(let x509Credentials):
                configuration = try .makeServerConfiguration(x509Credentials)

            #if HTTP3
            case .rawPublicKey:
                throw NIOHTTPServerConfigurationError.rawPublicKeyTLSCredentialsNotCurrentlySupportedOverHTTP1OrHTTP2
            #endif
            }
        }

        if case .mTLS(_, let mTLSConfiguration) = transportSecurity.backing {
            switch mTLSConfiguration.source.backing {
            case .systemDefaults:
                configuration.trustRoots = .default

            case .certificates(let trustRoots):
                configuration.trustRoots = .certificates(try trustRoots.map { try NIOSSLCertificate($0) })

            case .serialized(let serialized):
                configuration.trustRoots = try .init(serialized)

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

@available(anyAppleOS 26.0, *)
extension TLSConfiguration {
    /// Creates a server `TLSConfiguration` from the provided X.509 credentials.
    fileprivate static func makeServerConfiguration(
        _ x509Credentials: NIOHTTPServerConfiguration.TransportSecurity.X509Credentials
    ) throws -> TLSConfiguration {
        switch x509Credentials.backing {
        case .certificates(let chain, let privateKey):
            return .makeServerConfiguration(
                certificateChain: try chain.map { try NIOSSLCertificateSource($0) },
                privateKey: try NIOSSLPrivateKeySource(privateKey)
            )

        case .reloading(let certificateReloader):
            return try .makeServerConfiguration(certificateReloader: certificateReloader)

        case .serialized(let serialized):
            return .makeServerConfiguration(certificateChain: try .init(serialized), privateKey: try .init(serialized))
        }
    }
}

@available(anyAppleOS 26.0, *)
extension [NIOSSLCertificateSource] {
    fileprivate init(
        _ serialized: NIOHTTPServerConfiguration.TransportSecurity.X509Credentials.SerializedCredentials
    ) throws {
        switch serialized {
        case .file(let certificateChain, _, .pem):
            self.init(try NIOSSLCertificate.fromPEMFile(certificateChain).map { .certificate($0) })

        case .file(let certificate, _, .der):
            self.init([.certificate(try NIOSSLCertificate.fromDERFile(certificate))])

        case .bytes(let certificateChain, _, .pem):
            self.init(try NIOSSLCertificate.fromPEMBytes(certificateChain).map { .certificate($0) })

        case .bytes(let certificate, _, .der):
            self.init([.certificate(try NIOSSLCertificate(bytes: certificate, format: .der))])
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOSSLPrivateKeySource {
    fileprivate init(
        _ serialized: NIOHTTPServerConfiguration.TransportSecurity.X509Credentials.SerializedCredentials
    ) throws {
        switch serialized {
        case .file(_, let privateKey, let format):
            self = .privateKey(try .init(file: privateKey, format: .init(format)))

        case .bytes(_, let privateKey, let format):
            self = .privateKey(try .init(bytes: privateKey, format: .init(format)))
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOSSLTrustRoots {
    fileprivate init(
        _ serialized: NIOHTTPServerConfiguration.TransportSecurity.MTLSTrustConfiguration.SerializedTrustRoots
    ) throws {
        switch serialized {
        case .file(let trustRoots, .pem):
            self = .file(trustRoots)

        case .file(let trustRoot, .der):
            self = .certificates([try NIOSSLCertificate.fromDERFile(trustRoot)])

        case .bytes(let trustRoots, .pem):
            self = .certificates(try NIOSSLCertificate.fromPEMBytes(trustRoots))

        case .bytes(let trustRoot, .der):
            self = .certificates([try NIOSSLCertificate(bytes: trustRoot, format: .der)])
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOSSLSerializationFormats {
    fileprivate init(_ format: NIOHTTPServerConfiguration.TransportSecurity.Encoding) {
        switch format {
        case .pem:
            self = .pem

        case .der:
            self = .der
        }
    }
}
