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
import Configuration
import Crypto
import Foundation
import NIOCertificateReloading
import SwiftASN1
import Testing
import X509

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServerSwiftConfigurationTests {
    @Suite("BindTarget")
    struct BindTargetTests {
        @Test("Valid host and port")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testValidConfig() throws {
            let provider = InMemoryProvider(values: ["host": "localhost", "port": 8080])

            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let bindTarget = try NIOHTTPServerConfiguration.BindTarget(config: snapshot)

            switch bindTarget.backing {
            case .hostAndPort(let host, let port):
                #expect(host == "localhost")
                #expect(port == 8080)
            }
        }

        @Test("Init fails with missing host")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testMissingHost() throws {
            let provider = InMemoryProvider(values: ["port": 8080])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let configError = try #require(throws: Error.self) {
                try NIOHTTPServerConfiguration.BindTarget(config: snapshot)
            }

            #expect("Missing required config value for key: host." == "\(configError)")
        }

        @Test("Init fails with missing port")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testMissingPort() throws {
            let provider = InMemoryProvider(values: ["host": "localhost"])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let configError = try #require(throws: Error.self) {
                try NIOHTTPServerConfiguration.BindTarget(config: snapshot)
            }

            #expect("Missing required config value for key: port." == "\(configError)")
        }
    }

    @Suite("BackPressureStrategy")
    struct BackPressureStrategyTests {
        @Test("Default values")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testDefaultValues() throws {
            // Don't provide anything. All values have defaults.
            let provider = InMemoryProvider(values: [:])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let strategy = NIOHTTPServerConfiguration.BackPressureStrategy(config: snapshot)

            switch strategy.backing {
            case .watermark(let low, let high):
                #expect(low == NIOHTTPServerConfiguration.BackPressureStrategy.defaultWatermarkLow)
                #expect(high == NIOHTTPServerConfiguration.BackPressureStrategy.defaultWatermarkHigh)
            }
        }

        @Test("Custom values")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testCustomValues() throws {
            let provider = InMemoryProvider(values: ["low": 5, "high": 20])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let strategy = NIOHTTPServerConfiguration.BackPressureStrategy(config: snapshot)

            switch strategy.backing {
            case .watermark(let low, let high):
                #expect(low == 5)
                #expect(high == 20)
            }
        }

        @Test("Partial custom values")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testPartialCustomValues() throws {
            let provider = InMemoryProvider(values: ["low": 3])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let strategy = NIOHTTPServerConfiguration.BackPressureStrategy(config: snapshot)

            switch strategy.backing {
            case .watermark(let low, let high):
                #expect(low == 3)
                #expect(high == NIOHTTPServerConfiguration.BackPressureStrategy.defaultWatermarkHigh)
            }
        }
    }

    @Suite("SupportedHTTPVersions")
    struct SupportedHTTPVersionsTests {
        @Test("Empty supported version set is invalid")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testEmptySupportedHTTPVersionSetFails() async {
            await #expect(processExitsWith: .failure) {
                let provider = InMemoryProvider(values: [
                    "supportedHTTPVersions": .init(.stringArray([]), isSecret: false)
                ])

                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()
                _ = try Set<NIOHTTPServerConfiguration.HTTPVersion>(config: snapshot)
            }
        }

        @Test("Unrecognized versions are ignored")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testUnrecognizedHTTPVersionIgnored() throws {
            let provider = InMemoryProvider(values: [
                "supportedHTTPVersions": .init(.stringArray(["unrecognized_version"]), isSecret: false)
            ])

            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let configError = try #require(throws: Error.self) {
                _ = try Set<NIOHTTPServerConfiguration.HTTPVersion>(config: snapshot)
            }

            #expect(
                "Config value for key 'supportedHTTPVersions' failed to cast to type HTTPVersionKind."
                    == "\(configError)"
            )
        }

        @Test("Default HTTP/2 configuration used when not specified")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testDefaultHTTP2ConfigurationUsed() throws {
            let provider = InMemoryProvider(values: [
                "supportedHTTPVersions": .init(.stringArray(["http1_1", "http2"]), isSecret: false)
            ])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let supportedVersions = try Set<NIOHTTPServerConfiguration.HTTPVersion>(config: snapshot)
            #expect(supportedVersions.contains(.http1_1))
            #expect(supportedVersions.http2ConfigIfSupported == .defaults)
        }
    }

    @Suite("HTTP2")
    struct HTTP2Tests {
        @Test("Default values")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testDefaultValues() throws {
            let provider = InMemoryProvider(values: [:])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let http2 = NIOHTTPServerConfiguration.HTTP2(config: snapshot)

            #expect(http2.maxFrameSize == NIOHTTPServerConfiguration.HTTP2.defaultMaxFrameSize)
            #expect(http2.targetWindowSize == NIOHTTPServerConfiguration.HTTP2.defaultTargetWindowSize)
            #expect(http2.maxConcurrentStreams == nil)
            #expect(http2.gracefulShutdown == .init(maximumGracefulShutdownDuration: nil))
        }

        @Test("Custom values")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testCustomValues() throws {
            let provider = InMemoryProvider(values: [
                "maxFrameSize": 1,
                "targetWindowSize": 2,
                "maxConcurrentStreams": 3,
                "maximumGracefulShutdownDuration": 4,
            ])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let http2 = NIOHTTPServerConfiguration.HTTP2(config: snapshot)

            #expect(http2.maxFrameSize == 1)
            #expect(http2.targetWindowSize == 2)
            #expect(http2.maxConcurrentStreams == 3)
            #expect(http2.gracefulShutdown.maximumGracefulShutdownDuration == .seconds(4))
        }

        @Test("Partial custom values")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testPartialCustomValues() throws {
            let provider = InMemoryProvider(values: ["maxFrameSize": 5])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let http2 = NIOHTTPServerConfiguration.HTTP2(config: snapshot)

            #expect(http2.maxFrameSize == 5)
            #expect(http2.targetWindowSize == NIOHTTPServerConfiguration.HTTP2.defaultTargetWindowSize)
            #expect(http2.maxConcurrentStreams == nil)
            #expect(http2.gracefulShutdown.maximumGracefulShutdownDuration == nil)
        }
    }

    @Suite("TransportSecurity")
    struct TransportSecurityTests {
        @Test("Invalid security type")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testInvalidSecurityType() throws {
            let provider = InMemoryProvider(values: ["security": "<this_security_type_does_not_exist>"])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let configError = try #require(throws: Error.self) {
                try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)
            }

            #expect("Config value for key 'security' failed to cast to type TransportSecurityKind." == "\(configError)")
        }

        @Test("Custom verification callback without mTLS being enabled")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func testCannotInitializeWithCustomCallbackWhenMTLSNotEnabled() throws {
            let provider = InMemoryProvider(values: ["security": "tls"])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let error = #expect(throws: Error.self) {
                // The custom verification callback will not be used when mTLS is not enabled. This is therefore an invalid
                // config, and we should expect an error.
                try NIOHTTPServerConfiguration.TransportSecurity(
                    config: snapshot,
                    customCertificateVerificationCallback: { peerCertificates in
                        .failed(.init(reason: "test"))
                    }
                )
            }

            #expect(
                error as? NIOHTTPServerSwiftConfigurationError == .customVerificationCallbackProvidedWhenNotUsingMTLS
            )
        }

        @Suite
        struct TLS {
            @Test("Valid config")
            @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
            func testValidConfig() throws {
                let chain = try TestCA.makeSelfSignedChain()
                let certsPEM = try chain.chainPEMString
                let keyPEM = try chain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "security": "tls",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let transportSecurity = try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)

                guard case .tls(let credentials) = transportSecurity.backing else {
                    Issue.record("Expected TLS transport security, got \(transportSecurity.backing) instead.")
                    return
                }

                guard case .inMemory(let certificateChain, let privateKey) = credentials.backing else {
                    Issue.record("Expected in-memory TLS credentials, got \(credentials.backing) instead.")
                    return
                }

                #expect(certificateChain == chain.chain)
                #expect(privateKey == chain.privateKey)
            }

            @Test("Init fails with missing certificate")
            @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
            func testMissingCertificate() throws {
                let chain = try TestCA.makeSelfSignedChain()
                let keyPEM = try chain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "security": "tls",
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let configError = try #require(throws: Error.self) {
                    try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)
                }

                #expect("Missing required config value for key: certificateChainPEMString." == "\(configError)")
            }

            @Test("Init fails with missing private key")
            @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
            func testMissingPrivateKey() throws {
                let chain = try TestCA.makeSelfSignedChain()
                let certsPEM = try chain.chainPEMString

                let provider = InMemoryProvider(
                    values: [
                        "security": "tls",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let configError = try #require(throws: Error.self) {
                    try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)
                }

                #expect("Missing required config value for key: privateKeyPEMString." == "\(configError)")
            }
        }

        @Suite
        struct ReloadingTLS {
            @Test("Valid config")
            @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
            func testValidConfig() async throws {
                let provider = InMemoryProvider(
                    values: [
                        "security": "reloadingTLS",
                        "certificateChainPEMPath": .init(.string("cert.pem"), isSecret: false),
                        "privateKeyPEMPath": .init(.string("key.pem"), isSecret: false),
                        "refreshInterval": 60,
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let transportSecurity = try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)

                guard case .tls(let credentials) = transportSecurity.backing else {
                    Issue.record("Expected TLS transport security, got \(transportSecurity.backing) instead.")
                    return
                }

                guard case .reloading = credentials.backing else {
                    Issue.record("Expected reloading TLS credentials, got \(credentials.backing) instead.")
                    return
                }
            }
        }

        @Suite
        struct MTLS {
            @Test("Custom verification callback")
            @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
            func testValidConfigWithCustomVerificationCallback() throws {
                let serverChain = try TestCA.makeSelfSignedChain()

                let certsPEM = try serverChain.chainPEMString
                let keyPEM = try serverChain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "security": "mTLS",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                        "certificateVerificationMode": "noHostnameVerification",
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                // Initialize with a custom verification callback
                let transportSecurity = try NIOHTTPServerConfiguration.TransportSecurity(
                    config: snapshot,
                    customCertificateVerificationCallback: { peerCerts in
                        .certificateVerified(.init(.init(uncheckedCertificateChain: peerCerts)))
                    }
                )

                guard case .mTLS(let tlsCredentials, let mTLSTrustConfiguration) = transportSecurity.backing else {
                    Issue.record("Expected mTLS transport security, got \(transportSecurity.backing) instead.")
                    return
                }

                guard case .inMemory(let certificateChain, let privateKey) = tlsCredentials.backing else {
                    Issue.record("Expected in-memory TLS credentials, got \(tlsCredentials.backing) instead.")
                    return
                }

                #expect(certificateChain == [serverChain.leaf, serverChain.ca])
                #expect(privateKey == serverChain.privateKey)

                guard case .customCertificateVerificationCallback = mTLSTrustConfiguration.backing else {
                    Issue.record(
                        "Expected a custom verification callback, got \(mTLSTrustConfiguration.backing) instead."
                    )
                    return
                }

                #expect(mTLSTrustConfiguration.certificateVerification.mode == .noHostnameVerification)
            }

            @Test("Optional verification mode")
            @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
            func testOptionalVerification() throws {
                let serverChain = try TestCA.makeSelfSignedChain()
                let certsPEM = try serverChain.chainPEMString
                let keyPEM = try serverChain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "security": "mTLS",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                        "certificateVerificationMode": "optionalVerification",
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let transportSecurity = try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)

                guard case .mTLS(let tlsCredentials, let mTLSTrustConfiguration) = transportSecurity.backing else {
                    Issue.record("Expected mTLS transport security, got \(transportSecurity.backing) instead.")
                    return
                }

                guard case .inMemory(let certificateChain, let privateKey) = tlsCredentials.backing else {
                    Issue.record("Expected in-memory TLS credentials, got \(tlsCredentials.backing) instead.")
                    return
                }

                #expect(certificateChain == [serverChain.leaf, serverChain.ca])
                #expect(privateKey == serverChain.privateKey)

                guard case .systemDefaults = mTLSTrustConfiguration.backing else {
                    Issue.record("Expected system default trust roots, got \(mTLSTrustConfiguration.backing) instead.")
                    return
                }
                #expect(mTLSTrustConfiguration.certificateVerification.mode == .optionalVerification)
            }

            @Test("Invalid verification mode")
            @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
            func testInvalidVerificationMode() throws {
                let serverChain = try TestCA.makeSelfSignedChain()

                let certsPEM = try serverChain.chainPEMString
                let keyPEM = try serverChain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "security": "mTLS",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                        "certificateVerificationMode": "<this_mode_does_not_exist>",
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let configError = try #require(throws: Error.self) {
                    try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)
                }

                #expect(
                    "Config value for key 'certificateVerificationMode' failed to cast to type VerificationMode."
                        == "\(configError)"
                )
            }

            @Test("Default trust roots")
            @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
            func testDefaultTrustRoots() throws {
                let serverChain = try TestCA.makeSelfSignedChain()

                let certsPEM = try serverChain.chainPEMString
                let keyPEM = try serverChain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "security": "mTLS",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                        "certificateVerificationMode": "noHostnameVerification",
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let transportSecurity = try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)

                guard case .mTLS(let tlsCredentials, let mTLSTrustConfiguration) = transportSecurity.backing else {
                    Issue.record("Expected mTLS transport security, got \(transportSecurity.backing) instead.")
                    return
                }

                guard case .inMemory(let certificateChain, let privateKey) = tlsCredentials.backing else {
                    Issue.record("Expected in-memory TLS credentials, got \(tlsCredentials.backing) instead.")
                    return
                }

                #expect(certificateChain == [serverChain.leaf, serverChain.ca])
                #expect(privateKey == serverChain.privateKey)

                guard case .systemDefaults = mTLSTrustConfiguration.backing else {
                    Issue.record("Expected system default trust roots, got \(mTLSTrustConfiguration.backing) instead.")
                    return
                }
            }
        }

        @Suite
        struct ReloadingMTLS {
            @Test("Valid config")
            @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
            func testValidConfig() async throws {
                let chain = try TestCA.makeSelfSignedChain()
                let trustRootPEM = try chain.ca.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "security": "reloadingMTLS",
                        "certificateChainPEMPath": .init(.string("certs.pem"), isSecret: false),
                        "privateKeyPEMPath": .init(.string("key.pem"), isSecret: false),
                        "trustRootsPEMString": .init(.string(trustRootPEM), isSecret: false),
                        "certificateVerificationMode": "noHostnameVerification",
                        "refreshInterval": 45,
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let transportSecurity = try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)

                guard case .mTLS(let tlsCredentials, let mTLSTrustConfiguration) = transportSecurity.backing else {
                    Issue.record("Expected mTLS transport security, got \(transportSecurity.backing) instead.")
                    return
                }

                guard case .reloading = tlsCredentials.backing else {
                    Issue.record("Expected reloading TLS credentials, got \(tlsCredentials.backing) instead.")
                    return
                }

                guard case .inMemory(let trustRoots) = mTLSTrustConfiguration.backing else {
                    Issue.record("Expected in-memory trust roots, got \(mTLSTrustConfiguration.backing) instead.")
                    return
                }
                #expect(trustRoots == [chain.ca])
            }
        }
    }

    @Suite("End-to-End")
    struct EndToEndConfigurationTests {
        @Test("Configure all possible values")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func fullConfiguration() throws {
            let chain = try TestCA.makeSelfSignedChain()
            let certsPEM = try chain.chainPEMString
            let keyPEM = try chain.privateKey.serializeAsPEM().pemString

            let provider = InMemoryProvider(
                values: [
                    "bindTarget.host": "127.0.0.1",
                    "bindTarget.port": 8000,
                    "supportedHTTPVersions": .init(.stringArray(["http1_1", "http2"]), isSecret: false),
                    "http2.maxFrameSize": 1,
                    "http2.targetWindowSize": 2,
                    "http2.maxConcurrentStreams": 3,
                    "http2.maximumGracefulShutdownDuration": 4,
                    "transportSecurity.security": .init(.string("mTLS"), isSecret: false),
                    "transportSecurity.certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                    "transportSecurity.privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                    "transportSecurity.trustRootsPEMString": .init(.string(certsPEM), isSecret: false),
                    "transportSecurity.certificateVerificationMode": "optionalVerification",
                ]
            )
            let config = ConfigReader(provider: provider)

            let serverConfig = try NIOHTTPServerConfiguration(config: config)

            guard case .hostAndPort(host: "127.0.0.1", port: 8000) = serverConfig.bindTarget.backing else {
                Issue.record(
                    "Expected bind target to be 127.0.0.1:8000, got \(serverConfig.bindTarget.backing) instead."
                )
                return
            }

            #expect(serverConfig.supportedHTTPVersions.contains(.http1_1))
            #expect(
                serverConfig.supportedHTTPVersions.http2ConfigIfSupported
                    == .init(
                        maxFrameSize: 1,
                        targetWindowSize: 2,
                        maxConcurrentStreams: 3,
                        gracefulShutdown: .init(maximumGracefulShutdownDuration: .seconds(4))
                    )
            )

            guard case .mTLS(let tlsCredentials, let trustConfig) = serverConfig.transportSecurity.backing else {
                Issue.record("Expected mTLS transport security, got \(serverConfig.transportSecurity.backing) instead.")
                return
            }

            guard case .inMemory(let certificateChain, let privateKey) = tlsCredentials.backing else {
                Issue.record("Expected in-memory TLS credentials, got \(tlsCredentials.backing) instead.")
                return
            }

            guard case .inMemory(let trustRoots) = trustConfig.backing else {
                Issue.record("Expected in-memory trust roots, got \(trustConfig.backing) instead.")
                return
            }

            #expect(trustRoots == chain.chain)
            #expect(certificateChain == chain.chain)
            #expect(privateKey == chain.privateKey)
        }

        @Test("Only HTTP/1.1 supported over plaintext")
        @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
        func onlyHTTP1_1SupportedOverPlaintext() async {
            await #expect(processExitsWith: .failure) {
                let provider = InMemoryProvider(
                    values: [
                        "bindTarget.host": "127.0.0.1",
                        "bindTarget.port": 8000,
                        "supportedHTTPVersions": .init(.stringArray(["http1_1", "http2"]), isSecret: false),
                        "transportSecurity.security": .init(.string("plaintext"), isSecret: false),
                    ]
                )
                let config = ConfigReader(provider: provider)

                _ = try NIOHTTPServerConfiguration(config: config)
            }
        }
    }
}
#endif  // Configuration
