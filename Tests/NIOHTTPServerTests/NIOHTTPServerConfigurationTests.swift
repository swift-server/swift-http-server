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

import Foundation
import NIOCertificateReloading
import NIOSSL
import Testing
import X509

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServerConfigurationTests {
    @Suite
    struct BindTarget {
        @available(anyAppleOS 26.0, *)
        @Test("Empty bindTargets throws error")
        func emptyBindTargetsThrows() throws {
            #expect(throws: NIOHTTPServerConfigurationError.noBindTargetsSpecified) {
                try NIOHTTPServerConfiguration(
                    bindTargets: [],
                    supportedHTTPVersions: [.http1_1],
                    transportSecurity: .plaintext
                )
            }
        }
    }

    @Suite
    struct SupportedHTTPVersions {
        @available(anyAppleOS 26.0, *)
        @Test("Empty supportedHTTPVersions throws error")
        func emptySupportedHTTPVersionsThrows() {
            #expect(throws: NIOHTTPServerConfigurationError.noSupportedHTTPVersionsSpecified) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [],
                    transportSecurity: .plaintext
                )
            }
        }

        @available(anyAppleOS 26.0, *)
        @Test("transport: plaintext, versions: {HTTP/1.1} -> valid")
        func plaintextTransportAndHTTP1_1IsValid() {
            #expect(throws: Never.self) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [.http1_1],
                    transportSecurity: .plaintext
                )
            }
        }

        #if HTTP3
        @available(anyAppleOS 26.0, *)
        @Test(
            "transport: plaintext, versions: HTTP/2 and/or HTTP/3 -> invalid",
            arguments: [
                [NIOHTTPServerConfiguration.HTTPVersion.http2],
                [.http3],
                [.http2, .http3],
                // Even when HTTP/1.1 is specified, the presence of HTTP/2 and/or HTTP/3 should make the config invalid.
                [.http1_1, .http2],
                [.http1_1, .http3],
                [.http1_1, .http2, .http3],
            ]
        )
        func plaintextNotSupportedForHTTP2OrHTTP3(supportedHTTPVersions: Set<NIOHTTPServerConfiguration.HTTPVersion>) {
            #expect(throws: NIOHTTPServerConfigurationError.incompatibleTransportSecurity) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: supportedHTTPVersions,
                    transportSecurity: .plaintext
                )
            }
        }
        #endif  // HTTP3
    }

    @Suite
    struct TransportSecurity {
        @available(anyAppleOS 26.0, *)
        @Test(
            "All X.509 credential sources produce a valid configuration",
            arguments: TestX509CredentialSource.allCases
        )
        func x509CredentialSourceProducesValidConfiguration(source: TestX509CredentialSource) throws {
            let chain = try TestCA.makeSelfSignedChain()
            let credentials = try source.makeCredentials(from: chain)

            #expect(throws: Never.self) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [.http1_1, .http2],
                    transportSecurity: .tls(credentials: .x509(credentials))
                )
            }
        }

        @available(anyAppleOS 26.0, *)
        @Test("All mTLS trust root sources produce a valid configuration", arguments: MTLSTrustSource.allCases)
        func mTLSTrustRootSourceProducesValidConfiguration(source: MTLSTrustSource) throws {
            let chain = try TestCA.makeSelfSignedChain()
            let trustConfiguration = try source.makeTrustConfiguration(from: chain)

            #expect(throws: Never.self) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [.http1_1, .http2],
                    transportSecurity: .mTLS(
                        credentials: .x509(.certificates(chain: chain.chain, privateKey: chain.privateKey)),
                        trustConfiguration: .init(trustConfiguration)
                    )
                )
            }
        }

        @available(anyAppleOS 26.0, *)
        @Test(
            "A non-existent X.509 certificate file path is rejected",
            arguments: [
                NIOHTTPServerConfiguration.TransportSecurity.X509Credentials.pemFile(
                    certificateChainPath: "/does/not/exist.pem",
                    privateKeyPath: "/does/not/exist.key"
                ),
                .derFile(certificatePath: "/does/not/exist.der", privateKeyPath: "/does/not/exist.der"),
            ]
        )
        func nonExistentX509FilePathRejected(
            credentials: NIOHTTPServerConfiguration.TransportSecurity.X509Credentials
        ) {
            #expect(throws: Error.self) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [.http1_1, .http2],
                    transportSecurity: .tls(credentials: .x509(credentials))
                )
            }
        }

        @available(anyAppleOS 26.0, *)
        @Test(
            "Malformed X.509 credential bytes are rejected",
            arguments: [
                NIOHTTPServerConfiguration.TransportSecurity.X509Credentials.pemBytes(
                    certificateChain: Array("not a valid PEM document".utf8),
                    privateKey: Array("not a valid PEM document".utf8)
                ),
                .derBytes(certificate: [0x00, 0x01, 0x02], privateKey: [0x03, 0x04, 0x05]),
            ]
        )
        func malformedX509BytesRejected(
            credentials: NIOHTTPServerConfiguration.TransportSecurity.X509Credentials
        ) throws {
            #expect(throws: NIOSSLError.failedToLoadCertificate) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [.http1_1, .http2],
                    transportSecurity: .tls(credentials: .x509(credentials))
                )
            }
        }

        #if HTTP3
        @available(anyAppleOS 26.0, *)
        @Test("PEM-file X.509 credentials over HTTP/3 produces a valid configuration")
        func pemFileX509ProducesValidHTTP3Configuration() throws {
            let chain = try TestCA.makeSelfSignedChain()
            let (leafPath, _, keyPath) = try chain.writeToDisk()

            #expect(throws: Never.self) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [.http3],
                    transportSecurity: .tls(
                        credentials: .x509(.pemFile(certificateChainPath: leafPath, privateKeyPath: keyPath))
                    )
                )
            }
        }

        @available(anyAppleOS 26.0, *)
        @Test(
            "Non-PEM-file X.509 credentials are rejected over HTTP/3",
            arguments: [TestX509CredentialSource.inMemory, .reloading, .pemBytes, .derFile, .derBytes]
        )
        func nonPEMFileX509RejectedOverHTTP3(source: TestX509CredentialSource) throws {
            let chain = try TestCA.makeSelfSignedChain()
            let credentials = try source.makeCredentials(from: chain)

            #expect(throws: NIOHTTPServerConfigurationError.onlyPEMFileX509CredentialsCurrentlySupportedOverHTTP3) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [.http3],
                    transportSecurity: .tls(credentials: .x509(credentials))
                )
            }
        }

        @available(anyAppleOS 26.0, *)
        @Test("DER-file RPK credentials produces a valid TLS configuration")
        func derFileRPKProducesValidConfiguration() throws {
            let chain = try TestCA.makeSelfSignedChain()

            #expect(throws: Never.self) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [.http3],
                    transportSecurity: .tls(credentials: .rawPublicKey(.makeTestCredentials(from: chain)))
                )
            }
        }

        @available(anyAppleOS 26.0, *)
        @Test("Raw public key credentials are rejected over HTTP/1.1 and HTTP/2")
        func rawPublicKeyRejectedOverHTTP1AndHTTP2() throws {
            #expect(
                throws: NIOHTTPServerConfigurationError.rawPublicKeyTLSCredentialsNotCurrentlySupportedOverHTTP1OrHTTP2
            ) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [.http1_1, .http2],
                    transportSecurity: .tls(
                        credentials: .rawPublicKey(.derFile(publicKeyPath: "public.der", privateKeyPath: "private.der"))
                    )
                )
            }
        }

        @available(anyAppleOS 26.0, *)
        @Test("mTLS is rejected over HTTP/3")
        func mTLSRejectedOverHTTP3() throws {
            let chain = try TestCA.makeSelfSignedChain()
            let (leafPath, _, keyPath) = try chain.writeToDisk()

            #expect(throws: NIOHTTPServerConfigurationError.mTLSNotCurrentlySupportedOverHTTP3) {
                try NIOHTTPServerConfiguration(
                    bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                    supportedHTTPVersions: [.http3],
                    transportSecurity: .mTLS(
                        credentials: .x509(.pemFile(certificateChainPath: leafPath, privateKeyPath: keyPath)),
                        trustConfiguration: .init(.systemDefaults)
                    )
                )
            }
        }
        #endif  // HTTP3
    }
}

@available(anyAppleOS 26.0, *)
enum TestX509CredentialSource: Sendable, CaseIterable {
    case inMemory
    case reloading
    case pemFile
    case pemBytes
    case derFile
    case derBytes

    /// Builds ``X509Credentials`` from `chain`.
    func makeCredentials(
        from chain: ChainPrivateKeyPair
    ) throws -> NIOHTTPServerConfiguration.TransportSecurity.X509Credentials {
        switch self {
        case .inMemory:
            return .certificates(chain: chain.chain, privateKey: chain.privateKey)

        case .reloading:
            let (leafPath, _, keyPath) = try chain.writeToDisk()

            let reloader = try TimedCertificateReloader.makeReloaderValidatingSources(
                configuration: .init(
                    refreshInterval: .seconds(60),
                    certificateSource: .init(location: .file(path: leafPath), format: .pem),
                    privateKeySource: .init(location: .file(path: keyPath), format: .pem)
                )
            )

            return .reloading(reloader)

        case .pemFile:
            let (leafPath, _, keyPath) = try chain.writeToDisk()
            return .pemFile(certificateChainPath: leafPath, privateKeyPath: keyPath)

        case .pemBytes:
            return .pemBytes(
                certificateChain: Array(try chain.chainPEMString.utf8),
                privateKey: Array(try chain.privateKey.serializeAsPEM().pemString.utf8)
            )

        case .derFile:
            let (leafPath, _, keyPath) = try chain.writeToDisk(encoding: .der)
            return .derFile(certificatePath: leafPath, privateKeyPath: keyPath)

        case .derBytes:
            return .derBytes(
                certificate: try chain.leaf.serializeAsPEM().derBytes,
                privateKey: try chain.privateKey.serializeAsPEM().derBytes
            )
        }
    }
}

#if HTTP3
@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.TransportSecurity.RawPublicKeyCredentials {
    /// Builds ``RawPublicKeyCredentials`` from `chain`.
    static func makeTestCredentials(
        from chain: ChainPrivateKeyPair
    ) throws -> Self {
        let publicKey = chain.leaf.publicKey
        let privateKey = chain.privateKey

        let uuid = UUID().uuidString
        let publicKeyPath = FileManager.default.temporaryDirectory.appendingPathComponent("leaf-\(uuid)")
        let privateKeyPath = FileManager.default.temporaryDirectory.appendingPathComponent("key-\(uuid)")

        try Data(try publicKey.serializeAsPEM().derBytes).write(to: publicKeyPath)
        try Data(try privateKey.serializeAsPEM().derBytes).write(to: privateKeyPath)

        return .derFile(publicKeyPath: publicKeyPath.path, privateKeyPath: privateKeyPath.path)
    }
}
#endif  // HTTP3

@available(anyAppleOS 26.0, *)
enum MTLSTrustSource: Sendable, CaseIterable {
    case systemDefaults
    case inMemory
    case pemFile
    case pemBytes
    case derFile
    case derBytes
    case customCallback

    /// Builds ``MTLSTrustConfiguration`` from `chain`.
    func makeTrustConfiguration(
        from chain: ChainPrivateKeyPair
    ) throws -> NIOHTTPServerConfiguration.TransportSecurity.MTLSTrustConfiguration.TrustSource {
        switch self {
        case .systemDefaults:
            return .systemDefaults

        case .inMemory:
            return .certificates(trustRoots: [chain.ca])

        case .pemFile:
            let (_, caPath, _) = try chain.writeToDisk()
            return .pemFile(trustRootsPath: caPath)

        case .pemBytes:
            return .pemBytes(trustRoots: Array(try chain.ca.serializeAsPEM().pemString.utf8))

        case .derFile:
            let (_, caPath, _) = try chain.writeToDisk(encoding: .der)
            return .derFile(trustRootPath: caPath)

        case .derBytes:
            return .derBytes(trustRoot: try chain.ca.serializeAsPEM().derBytes)

        case .customCallback:
            return .customCertificateVerificationCallback { _ in .certificateVerified(.init(nil)) }
        }
    }
}
