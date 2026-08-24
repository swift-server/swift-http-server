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
        @available(anyAppleOS 26.0, *)
        func testValidConfig() throws {
            let provider = InMemoryProvider(values: ["host": "localhost", "port": 8080])

            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let bindTarget = try NIOHTTPServerConfiguration.BindTarget(config: snapshot)

            switch bindTarget.backing {
            case .hostAndPort(let host, let port):
                #expect(host == "localhost")
                #expect(port == 8080)
            case .unixDomainSocket(let path):
                Issue.record("Expected first bind target to be host/port, got unix domain socket path: \(path)")
            }
        }

        @Test("Init fails with missing host")
        @available(anyAppleOS 26.0, *)
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
        @available(anyAppleOS 26.0, *)
        func testMissingPort() throws {
            let provider = InMemoryProvider(values: ["host": "localhost"])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let configError = try #require(throws: Error.self) {
                try NIOHTTPServerConfiguration.BindTarget(config: snapshot)
            }

            #expect("Missing required config value for key: port." == "\(configError)")
        }

        @Test("Valid unix domain socket path")
        @available(anyAppleOS 26.0, *)
        func testValidUnixDomainSocketConfig() throws {
            let provider = InMemoryProvider(values: ["socketPath": "/tmp/test.sock"])

            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let bindTarget = try NIOHTTPServerConfiguration.BindTarget(config: snapshot)

            switch bindTarget.backing {
            case .unixDomainSocket(let path):
                #expect(path == "/tmp/test.sock")
            case .hostAndPort(let host, let port):
                Issue.record("Expected a unix domain socket bind target, got host \(host) and port \(port) instead.")
            }
        }

        @Test("Init fails when both socketPath and host/port are provided")
        @available(anyAppleOS 26.0, *)
        func testSocketPathAndHostPortThrows() throws {
            let provider = InMemoryProvider(values: ["socketPath": "/tmp/test.sock", "host": "localhost", "port": 8080])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            #expect(throws: NIOHTTPServerSwiftConfigurationError.hostPortAndSocketPathProvided) {
                try NIOHTTPServerConfiguration.BindTarget(config: snapshot)
            }
        }
    }

    @Suite("Multiple bind targets via bindTargets")
    struct MultipleBindTargetsTests {
        @Test("Parallel hosts and ports produce multiple bind targets")
        @available(anyAppleOS 26.0, *)
        func testMultipleBindTargets() throws {
            let provider = InMemoryProvider(
                values: [
                    "bindTargets.hosts": .init(.stringArray(["127.0.0.1", "::1"]), isSecret: false),
                    "bindTargets.ports": .init(.intArray([8080, 8443]), isSecret: false),
                    "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
                    "transportSecurity.mode": "plaintext",
                ]
            )
            let config = ConfigReader(provider: provider)

            let serverConfig = try NIOHTTPServerConfiguration(config: config)

            #expect(serverConfig.bindTargets.count == 2)
            guard case .hostAndPort(let host0, let port0) = serverConfig.bindTargets[0].backing else {
                Issue.record("Expected first bind target to be host/port, got \(serverConfig.bindTargets[0].backing)")
                return
            }
            #expect(host0 == "127.0.0.1")
            #expect(port0 == 8080)

            guard case .hostAndPort(let host1, let port1) = serverConfig.bindTargets[1].backing else {
                Issue.record("Expected second bind target to be host/port, got \(serverConfig.bindTargets[1].backing)")
                return
            }
            #expect(host1 == "::1")
            #expect(port1 == 8443)
        }

        @Test("Singular bindTarget still works")
        @available(anyAppleOS 26.0, *)
        func testSingularBindTargetStillWorks() throws {
            let provider = InMemoryProvider(
                values: [
                    "bindTarget.host": "127.0.0.1",
                    "bindTarget.port": 8080,
                    "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
                    "transportSecurity.mode": "plaintext",
                ]
            )
            let config = ConfigReader(provider: provider)

            let serverConfig = try NIOHTTPServerConfiguration(config: config)

            #expect(serverConfig.bindTargets.count == 1)
            guard case .hostAndPort(let host, let port) = serverConfig.bindTargets[0].backing else {
                Issue.record("Expected host/port, got \(serverConfig.bindTargets[0].backing)")
                return
            }
            #expect(host == "127.0.0.1")
            #expect(port == 8080)
        }

        @Test("Providing both singular and plural throws an error")
        @available(anyAppleOS 26.0, *)
        func testBothSingularAndPluralThrows() throws {
            let provider = InMemoryProvider(
                values: [
                    "bindTarget.host": "127.0.0.1",
                    "bindTarget.port": 8080,
                    "bindTargets.hosts": .init(.stringArray(["127.0.0.1"]), isSecret: false),
                    "bindTargets.ports": .init(.intArray([8443]), isSecret: false),
                    "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
                    "transportSecurity.mode": "plaintext",
                ]
            )
            let config = ConfigReader(provider: provider)

            #expect(throws: NIOHTTPServerSwiftConfigurationError.singularAndPluralBindTargetsProvided) {
                _ = try NIOHTTPServerConfiguration(config: config)
            }
        }

        @Test("Mismatched hosts and ports lengths throws an error")
        @available(anyAppleOS 26.0, *)
        func testMismatchedHostsAndPortsLengthsThrows() throws {
            let provider = InMemoryProvider(
                values: [
                    "bindTargets.hosts": .init(.stringArray(["127.0.0.1", "::1"]), isSecret: false),
                    "bindTargets.ports": .init(.intArray([8080]), isSecret: false),
                    "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
                    "transportSecurity.mode": "plaintext",
                ]
            )
            let config = ConfigReader(provider: provider)

            #expect(throws: NIOHTTPServerSwiftConfigurationError.bindTargetsHostsAndPortsLengthMismatch) {
                _ = try NIOHTTPServerConfiguration(config: config)
            }
        }

        @Test("Empty bindTargets arrays throws an error")
        @available(anyAppleOS 26.0, *)
        func testEmptyBindTargetsArraysThrows() throws {
            let provider = InMemoryProvider(
                values: [
                    "bindTargets.hosts": .init(.stringArray([]), isSecret: false),
                    "bindTargets.ports": .init(.intArray([]), isSecret: false),
                    "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
                    "transportSecurity.mode": "plaintext",
                ]
            )
            let config = ConfigReader(provider: provider)

            #expect(throws: NIOHTTPServerConfigurationError.noBindTargetsSpecified) {
                _ = try NIOHTTPServerConfiguration(config: config)
            }
        }
    }

    @Suite("BackPressureStrategy")
    struct BackPressureStrategyTests {
        @Test("Default values")
        @available(anyAppleOS 26.0, *)
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
        @available(anyAppleOS 26.0, *)
        func testCustomValues() throws {
            let provider = InMemoryProvider(values: ["lowWatermark": 5, "highWatermark": 20])
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
        @available(anyAppleOS 26.0, *)
        func testPartialCustomValues() throws {
            let provider = InMemoryProvider(values: ["lowWatermark": 3])
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
        @available(anyAppleOS 26.0, *)
        func testEmptySupportedHTTPVersionSetFails() async {
            await #expect(processExitsWith: .failure) {
                let provider = InMemoryProvider(values: [
                    "versions": .init(.stringArray([]), isSecret: false)
                ])

                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()
                _ = try Set<NIOHTTPServerConfiguration.HTTPVersion>(config: snapshot)
            }
        }

        @Test("Unrecognized versions are ignored")
        @available(anyAppleOS 26.0, *)
        func testUnrecognizedHTTPVersionIgnored() throws {
            let provider = InMemoryProvider(values: [
                "versions": .init(.stringArray(["unrecognized_version"]), isSecret: false)
            ])

            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let configError = try #require(throws: Error.self) {
                _ = try Set<NIOHTTPServerConfiguration.HTTPVersion>(config: snapshot)
            }

            #expect("Config value for key 'versions' failed to cast to type HTTPVersionKind." == "\(configError)")
        }

        @Test("Default HTTP/2 configuration used when not specified")
        @available(anyAppleOS 26.0, *)
        func testDefaultHTTP2ConfigurationUsed() throws {
            let provider = InMemoryProvider(values: [
                "versions": .init(.stringArray(["http1_1", "http2"]), isSecret: false)
            ])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let supportedVersions = try Set<NIOHTTPServerConfiguration.HTTPVersion>(config: snapshot)
            #expect(supportedVersions.contains(.http1_1))
            #expect(supportedVersions.http2ConfigIfSupported == .defaults)
        }

        #if HTTP3
        @Test("Default HTTP/3 configuration used when not specified")
        @available(anyAppleOS 26.0, *)
        func defaultHTTP3ConfigurationUsed() throws {
            let versions = ConfigValue(.stringArray(["http1_1", "http3"]), isSecret: false)
            let snapshot = ConfigReader(provider: InMemoryProvider(values: ["versions": versions])).snapshot()

            let supportedVersions = try Set<NIOHTTPServerConfiguration.HTTPVersion>(config: snapshot)
            #expect(supportedVersions.contains(.http1_1))
            #expect(supportedVersions.http3ConfigIfSupported == .defaults)
        }
        #endif
    }

    @Suite("HTTP2")
    struct HTTP2Tests {
        @Test("Default values")
        @available(anyAppleOS 26.0, *)
        func testDefaultValues() throws {
            let provider = InMemoryProvider(values: [:])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let http2 = NIOHTTPServerConfiguration.HTTP2(config: snapshot)

            #expect(http2.maxFrameSize == NIOHTTPServerConfiguration.HTTP2.defaultMaxFrameSize)
            #expect(http2.targetWindowSize == NIOHTTPServerConfiguration.HTTP2.defaultTargetWindowSize)
            #expect(http2.maxConcurrentStreams == 100)
            #expect(http2.gracefulShutdown == .init(maximumGracefulShutdownDuration: nil))
        }

        @Test("Custom values")
        @available(anyAppleOS 26.0, *)
        func testCustomValues() throws {
            let provider = InMemoryProvider(values: [
                "maxFrameSize": 1,
                "targetWindowSize": 2,
                "maxConcurrentStreams": 3,
                "gracefulShutdown.maximumDuration": 4,
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
        @available(anyAppleOS 26.0, *)
        func testPartialCustomValues() throws {
            let provider = InMemoryProvider(values: ["maxFrameSize": 5])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let http2 = NIOHTTPServerConfiguration.HTTP2(config: snapshot)

            #expect(http2.maxFrameSize == 5)
            #expect(http2.targetWindowSize == NIOHTTPServerConfiguration.HTTP2.defaultTargetWindowSize)
            #expect(http2.maxConcurrentStreams == 100)
            #expect(http2.gracefulShutdown.maximumGracefulShutdownDuration == nil)
        }
    }

    #if HTTP3
    @Suite("HTTP3")
    struct HTTP3Tests {
        @Test("Default values")
        @available(anyAppleOS 26.0, *)
        func defaultValues() throws {
            let snapshot = ConfigReader(provider: InMemoryProvider(values: [:])).snapshot()

            let http3 = try NIOHTTPServerConfiguration.HTTP3(config: snapshot)

            #expect(http3 == .defaults)
        }

        @Test("Custom values")
        @available(anyAppleOS 26.0, *)
        func customValues() throws {
            let provider = InMemoryProvider(values: [
                "preferHuffmanEncoding": false,
                "connectionSettings.qpackMaximumTableCapacity": 4096,
                "connectionSettings.qpackBlockedStreams": 16,
                "connectionSettings.maximumFieldSectionSize": 8192,
                "quicConfiguration.keyExchangeGroup": "secp384",
                "quicConfiguration.maxIdleTimeout": 10,
                "quicConfiguration.keepAliveInterval": 20,
                "quicConfiguration.initialMaxData": 2048,
                "quicConfiguration.initialMaxStreamDataBidirectionalLocal": 50,
                "quicConfiguration.initialMaxStreamDataBidirectionalRemote": 75,
                "quicConfiguration.initialMaxStreamDataUnidirectional": 125,
                "quicConfiguration.initialMaxStreamsBidirectional": 150,
                "quicConfiguration.initialMaxStreamsUnidirectional": 175,
                "quicConfiguration.sendRetry": true,
                "quicConfiguration.keyLogPath": "/tmp/keylog",
                "quicConfiguration.qlog.path": "/tmp/qlog",
                "quicConfiguration.qlog.topic": "topic",
                "quicConfiguration.qlog.description": "description",
            ])
            let snapshot = ConfigReader(provider: provider).snapshot()

            let http3 = try NIOHTTPServerConfiguration.HTTP3(config: snapshot)

            #expect(http3.preferHuffmanEncoding == false)

            let connectionSettings = http3.connectionSettings
            #expect(connectionSettings.qpackMaximumTableCapacity == 4096)
            #expect(connectionSettings.qpackBlockedStreams == 16)
            #expect(connectionSettings.maximumFieldSectionSize == 8192)

            let quic = http3.quicConfiguration
            #expect(quic.keyExchangeGroup == .secp384)
            #expect(quic.maxIdleTimeout == .seconds(10))
            #expect(quic.keepAliveInterval == .seconds(20))
            #expect(quic.initialMaxData == 2048)
            #expect(quic.initialMaxStreamDataBidirectionalLocal == 50)
            #expect(quic.initialMaxStreamDataBidirectionalRemote == 75)
            #expect(quic.initialMaxStreamDataUnidirectional == 125)
            #expect(quic.initialMaxStreamsBidirectional == 150)
            #expect(quic.initialMaxStreamsUnidirectional == 175)
            #expect(quic.sendRetry == true)
            #expect(quic.keyLogPath == "/tmp/keylog")
            #expect(quic.qLogConfiguration == .init(path: "/tmp/qlog", topic: "topic", description: "description"))
        }

        @Suite("ConnectionSettings")
        struct ConnectionSettingsTests {
            @Test("Default values")
            @available(anyAppleOS 26.0, *)
            func defaultValues() {
                let snapshot = ConfigReader(provider: InMemoryProvider(values: [:])).snapshot()

                let settings = NIOHTTPServerConfiguration.HTTP3.ConnectionSettings(config: snapshot)

                #expect(settings == .defaults)
                #expect(settings.qpackMaximumTableCapacity == 0)
                #expect(settings.qpackBlockedStreams == 0)
                #expect(settings.maximumFieldSectionSize == nil)
            }

            @Test("Custom values")
            @available(anyAppleOS 26.0, *)
            func customValues() {
                let snapshot = ConfigReader(
                    provider: InMemoryProvider(values: [
                        "qpackMaximumTableCapacity": 1024,
                        "qpackBlockedStreams": 8,
                        "maximumFieldSectionSize": 4096,
                    ])
                ).snapshot()

                let settings = NIOHTTPServerConfiguration.HTTP3.ConnectionSettings(config: snapshot)

                #expect(settings.qpackMaximumTableCapacity == 1024)
                #expect(settings.qpackBlockedStreams == 8)
                #expect(settings.maximumFieldSectionSize == 4096)
            }

            @Test("Negative values resolve to valid values")
            @available(anyAppleOS 26.0, *)
            func negativeClampsResolveToValidValues() {
                let snapshot = ConfigReader(
                    provider: InMemoryProvider(values: [
                        "qpackMaximumTableCapacity": -5,
                        "qpackBlockedStreams": -7,
                        "maximumFieldSectionSize": -1,
                    ])
                ).snapshot()

                let settings = NIOHTTPServerConfiguration.HTTP3.ConnectionSettings(config: snapshot)

                #expect(settings.qpackMaximumTableCapacity == 0)
                #expect(settings.qpackBlockedStreams == 0)
                #expect(settings.maximumFieldSectionSize == nil)
            }
        }

        @Suite("QUICConfiguration")
        struct QUICConfigurationTests {
            @Test("Default values")
            @available(anyAppleOS 26.0, *)
            func defaultValues() throws {
                let snapshot = ConfigReader(provider: InMemoryProvider(values: [:])).snapshot()

                let quic = try NIOHTTPServerConfiguration.HTTP3.QUICConfiguration(config: snapshot)

                #expect(quic == .defaults)
            }

            @Test("Durations are extracted as seconds")
            @available(anyAppleOS 26.0, *)
            func durationsExtractedAsSeconds() throws {
                let snapshot = ConfigReader(
                    provider: InMemoryProvider(values: ["maxIdleTimeout": 45, "keepAliveInterval": 5])
                ).snapshot()

                let quic = try NIOHTTPServerConfiguration.HTTP3.QUICConfiguration(config: snapshot)

                #expect(quic.maxIdleTimeout == .seconds(45))
                #expect(quic.keepAliveInterval == .seconds(5))
            }

            @Test("Invalid key exchange group throws")
            @available(anyAppleOS 26.0, *)
            func invalidKeyExchangeGroup() throws {
                let snapshot = ConfigReader(provider: InMemoryProvider(values: ["keyExchangeGroup": "<not_a_group>"]))
                    .snapshot()

                let configError = try #require(throws: Error.self) {
                    try NIOHTTPServerConfiguration.HTTP3.QUICConfiguration(config: snapshot)
                }

                #expect(
                    "Config value for key 'keyExchangeGroup' failed to cast to type KeyExchangeGroupKind."
                        == "\(configError)"
                )
            }
        }

        @Suite("QLogConfiguration")
        struct QLogConfigurationTests {
            @Test("No qlog configuration specified")
            @available(anyAppleOS 26.0, *)
            func valuesNotSpecified() throws {
                let snapshot = ConfigReader(provider: InMemoryProvider(values: [:])).snapshot()

                let quic = try NIOHTTPServerConfiguration.HTTP3.QUICConfiguration(config: snapshot)

                #expect(quic.qLogConfiguration == nil)
            }

            @Test("Fully specified qlog configuration")
            @available(anyAppleOS 26.0, *)
            func allValuesSpecified() throws {
                let snapshot = ConfigReader(
                    provider: InMemoryProvider(values: [
                        "qlog.path": "/var/log/qlog",
                        "qlog.topic": "server",
                        "qlog.description": "server qlog",
                    ])
                ).snapshot()

                let quic = try NIOHTTPServerConfiguration.HTTP3.QUICConfiguration(config: snapshot)

                #expect(
                    quic.qLogConfiguration == .init(path: "/var/log/qlog", topic: "server", description: "server qlog")
                )
            }

            @Test("Partial qlog configuration is invalid")
            @available(anyAppleOS 26.0, *)
            func partialConfigurationInvalid() throws {
                let snapshot = ConfigReader(provider: InMemoryProvider(values: ["qlog.path": "/var/log/qlog"]))
                    .snapshot()

                let configError = try #require(throws: Error.self) {
                    try NIOHTTPServerConfiguration.HTTP3.QUICConfiguration(config: snapshot)
                }

                #expect("Missing required config value for key: qlog.topic." == "\(configError)")
            }
        }

        @Test("End-to-end HTTP/3 configuration over TLS")
        @available(anyAppleOS 26.0, *)
        func testEndToEnd() throws {
            let (leafPath, _, keyPath) = try TestCA.makeSelfSignedChain().writeToDisk()
            let provider = InMemoryProvider(values: [
                "bindTarget.host": "127.0.0.1",
                "bindTarget.port": 8000,
                "http.versions": .init(.stringArray(["http3"]), isSecret: false),
                "http.http3.preferHuffmanEncoding": false,
                "http.http3.connectionSettings.qpackBlockedStreams": 7,
                "http.http3.quicConfiguration.maxIdleTimeout": 60,
                "http.http3.quicConfiguration.sendRetry": true,
                "transportSecurity.mode": "tls",
                "transportSecurity.credentialSource": "file",
                "transportSecurity.certificateChainPEMPath": .init(.string(leafPath), isSecret: false),
                "transportSecurity.privateKeyPEMPath": .init(.string(keyPath), isSecret: true),
            ])
            let config = ConfigReader(provider: provider)

            let serverConfig = try NIOHTTPServerConfiguration(config: config)

            let http3 = try #require(serverConfig.supportedHTTPVersions.http3ConfigIfSupported)
            #expect(http3.preferHuffmanEncoding == false)
            #expect(http3.connectionSettings.qpackBlockedStreams == 7)
            #expect(http3.quicConfiguration.maxIdleTimeout == .seconds(60))
            #expect(http3.quicConfiguration.sendRetry == true)
        }
    }
    #endif  // HTTP3

    @Suite("TransportSecurity")
    struct TransportSecurityTests {
        @Test("Invalid security mode")
        @available(anyAppleOS 26.0, *)
        func testInvalidSecurityMode() throws {
            let provider = InMemoryProvider(values: ["mode": "<this_mode_does_not_exist>"])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let configError = try #require(throws: Error.self) {
                try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)
            }

            #expect("Config value for key 'mode' failed to cast to type TransportSecurityMode." == "\(configError)")
        }

        @Test("Custom verification callback without mTLS being enabled")
        @available(anyAppleOS 26.0, *)
        func testCannotInitializeWithCustomCallbackWhenMTLSNotEnabled() throws {
            let provider = InMemoryProvider(values: ["mode": "tls", "credentialSource": "inline"])
            let config = ConfigReader(provider: provider)
            let snapshot = config.snapshot()

            let error = #expect(throws: Error.self) {
                // The custom verification callback will not be used when mTLS is not enabled. This is therefore an
                // invalid config, and we should expect an error.
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
            @Test("Valid config using inline credentials")
            @available(anyAppleOS 26.0, *)
            func testValidConfigUsingInlineCredentials() throws {
                let chain = try TestCA.makeSelfSignedChain()
                let certsPEM = try chain.chainPEMString
                let keyPEM = try chain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "mode": "tls",
                        "credentialSource": "inline",
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

                guard case .x509(let x509) = credentials.backing,
                    case .certificates(let certificateChain, let privateKey) = x509.backing
                else {
                    Issue.record("Expected in-memory TLS credentials, got \(credentials.backing) instead.")
                    return
                }

                #expect(certificateChain == chain.chain)
                #expect(privateKey == chain.privateKey)
            }

            @Test("Valid file-based credentials with reloading")
            @available(anyAppleOS 26.0, *)
            func testValidFileConfigWithReloading() async throws {
                let provider = InMemoryProvider(
                    values: [
                        "mode": "tls",
                        "credentialSource": "file",
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

                guard case .x509(let x509Credentials) = credentials.backing,
                    case .reloading = x509Credentials.backing
                else {
                    Issue.record("Expected reloading TLS credentials, got \(credentials.backing) instead.")
                    return
                }
            }

            @Test("Valid file-based credentials without reloading")
            @available(anyAppleOS 26.0, *)
            func testValidFileConfigWithoutReloading() throws {
                let provider = InMemoryProvider(
                    values: [
                        "mode": "tls",
                        "credentialSource": "file",
                        "certificateChainPEMPath": .init(.string("cert.pem"), isSecret: false),
                        "privateKeyPEMPath": .init(.string("key.pem"), isSecret: false),
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let transportSecurity = try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)

                guard case .tls(let credentials) = transportSecurity.backing else {
                    Issue.record("Expected TLS transport security, got \(transportSecurity.backing) instead.")
                    return
                }

                guard case .x509(let x509Credentials) = credentials.backing,
                    case .serialized(.file(_, _, .pem)) = x509Credentials.backing
                else {
                    Issue.record("Expected PEM file TLS credentials, got \(credentials.backing) instead.")
                    return
                }
            }

            #if HTTP3
            @Test("Raw public key credentials")
            @available(anyAppleOS 26.0, *)
            func testRawPublicKeyCredentials() throws {
                let provider = InMemoryProvider(
                    values: [
                        "mode": "tls",
                        "credentialSource": "rawPublicKey",
                        "publicKeyDERPath": .init(.string("public.der"), isSecret: false),
                        "privateKeyDERPath": .init(.string("private.der"), isSecret: false),
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let transportSecurity = try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)

                guard case .tls(let credentials) = transportSecurity.backing else {
                    Issue.record("Expected TLS transport security, got \(transportSecurity.backing) instead.")
                    return
                }

                guard case .rawPublicKey(let rpkCredentials) = credentials.backing else {
                    Issue.record("Expected raw public key TLS credentials, got \(credentials.backing) instead.")
                    return
                }

                switch rpkCredentials.backing {
                case .file(let publicKey, let privateKey, let format):
                    #expect(format == .der)
                    #expect(publicKey == "public.der")
                    #expect(privateKey == "private.der")
                }
            }
            #endif  // HTTP3

            @Test("Init fails with missing certificate")
            @available(anyAppleOS 26.0, *)
            func testMissingCertificate() throws {
                let chain = try TestCA.makeSelfSignedChain()
                let keyPEM = try chain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "mode": "tls",
                        "credentialSource": "inline",
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
            @available(anyAppleOS 26.0, *)
            func testMissingPrivateKey() throws {
                let chain = try TestCA.makeSelfSignedChain()
                let certsPEM = try chain.chainPEMString

                let provider = InMemoryProvider(
                    values: [
                        "mode": "tls",
                        "credentialSource": "inline",
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
        struct MTLS {
            @Test("Custom verification callback")
            @available(anyAppleOS 26.0, *)
            func testValidConfigWithCustomVerificationCallback() throws {
                let serverChain = try TestCA.makeSelfSignedChain()

                let certsPEM = try serverChain.chainPEMString
                let keyPEM = try serverChain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "mode": "mTLS",
                        "credentialSource": "inline",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                        "trustRootsSource": "customCertificateVerificationCallback",
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

                guard case .x509(let x509Credentials) = tlsCredentials.backing,
                    case .certificates(let certificateChain, let privateKey) = x509Credentials.backing
                else {
                    Issue.record("Expected in-memory TLS credentials, got \(tlsCredentials.backing) instead.")
                    return
                }

                #expect(certificateChain == [serverChain.leaf, serverChain.ca])
                #expect(privateKey == serverChain.privateKey)

                guard case .customCertificateVerificationCallback = mTLSTrustConfiguration.source.backing else {
                    Issue.record(
                        "Expected a custom verification callback, got \(mTLSTrustConfiguration.source.backing) instead."
                    )
                    return
                }

                #expect(mTLSTrustConfiguration.certificateVerification.mode == .noHostnameVerification)
            }

            @Test("Optional verification mode")
            @available(anyAppleOS 26.0, *)
            func testOptionalVerification() throws {
                let serverChain = try TestCA.makeSelfSignedChain()
                let certsPEM = try serverChain.chainPEMString
                let keyPEM = try serverChain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "mode": "mTLS",
                        "credentialSource": "inline",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                        "trustRootsSource": "systemDefaults",
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

                guard case .x509(let x509Credentials) = tlsCredentials.backing,
                    case .certificates(let certificateChain, let privateKey) = x509Credentials.backing
                else {
                    Issue.record("Expected in-memory TLS credentials, got \(tlsCredentials.backing) instead.")
                    return
                }

                #expect(certificateChain == [serverChain.leaf, serverChain.ca])
                #expect(privateKey == serverChain.privateKey)

                guard case .systemDefaults = mTLSTrustConfiguration.source.backing else {
                    Issue.record(
                        "Expected system default trust roots, got \(mTLSTrustConfiguration.source.backing) instead."
                    )
                    return
                }
                #expect(mTLSTrustConfiguration.certificateVerification.mode == .optionalVerification)
            }

            @Test("Invalid verification mode")
            @available(anyAppleOS 26.0, *)
            func testInvalidVerificationMode() throws {
                let serverChain = try TestCA.makeSelfSignedChain()

                let certsPEM = try serverChain.chainPEMString
                let keyPEM = try serverChain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "mode": "mTLS",
                        "credentialSource": "inline",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                        "trustRootsSource": "systemDefaults",
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
            @available(anyAppleOS 26.0, *)
            func testDefaultTrustRoots() throws {
                let serverChain = try TestCA.makeSelfSignedChain()

                let certsPEM = try serverChain.chainPEMString
                let keyPEM = try serverChain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "mode": "mTLS",
                        "credentialSource": "inline",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                        "trustRootsSource": "systemDefaults",
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

                guard case .x509(let x509Credentials) = tlsCredentials.backing,
                    case .certificates(let certificateChain, let privateKey) = x509Credentials.backing
                else {
                    Issue.record("Expected in-memory TLS credentials, got \(tlsCredentials.backing) instead.")
                    return
                }

                #expect(certificateChain == [serverChain.leaf, serverChain.ca])
                #expect(privateKey == serverChain.privateKey)

                guard case .systemDefaults = mTLSTrustConfiguration.source.backing else {
                    Issue.record(
                        "Expected system default trust roots, got \(mTLSTrustConfiguration.source.backing) instead."
                    )
                    return
                }
            }

            @Test("Trust roots from PEM file path")
            @available(anyAppleOS 26.0, *)
            func testTrustRootsFromPEMFilePath() throws {
                let serverChain = try TestCA.makeSelfSignedChain()

                let certsPEM = try serverChain.chainPEMString
                let keyPEM = try serverChain.privateKey.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "mode": "mTLS",
                        "credentialSource": "inline",
                        "certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                        "privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                        "trustRootsSource": "file",
                        "trustRootsPEMPath": .init(.string("/path/to/trust-roots.pem"), isSecret: false),
                        "certificateVerificationMode": "noHostnameVerification",
                    ]
                )
                let config = ConfigReader(provider: provider)
                let snapshot = config.snapshot()

                let transportSecurity = try NIOHTTPServerConfiguration.TransportSecurity(config: snapshot)

                guard case .mTLS(_, let mTLSTrustConfiguration) = transportSecurity.backing else {
                    Issue.record("Expected mTLS transport security, got \(transportSecurity.backing) instead.")
                    return
                }

                guard case .serialized(.file(let path, .pem)) = mTLSTrustConfiguration.source.backing else {
                    Issue.record(
                        "Expected pemFile trust configuration, got \(mTLSTrustConfiguration.source.backing) instead."
                    )
                    return
                }

                #expect(path == "/path/to/trust-roots.pem")
            }

        }

        @Suite
        struct ReloadingMTLS {
            @Test("Valid config with file credentials and reloading")
            @available(anyAppleOS 26.0, *)
            func testValidConfig() async throws {
                let chain = try TestCA.makeSelfSignedChain()
                let trustRootPEM = try chain.ca.serializeAsPEM().pemString

                let provider = InMemoryProvider(
                    values: [
                        "mode": "mTLS",
                        "credentialSource": "file",
                        "certificateChainPEMPath": .init(.string("certs.pem"), isSecret: false),
                        "privateKeyPEMPath": .init(.string("key.pem"), isSecret: false),
                        "trustRootsSource": "inline",
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

                guard case .x509(let x509Credentials) = tlsCredentials.backing,
                    case .reloading = x509Credentials.backing
                else {
                    Issue.record("Expected reloading TLS credentials, got \(tlsCredentials.backing) instead.")
                    return
                }

                guard case .certificates(let trustRoots) = mTLSTrustConfiguration.source.backing else {
                    Issue.record(
                        "Expected in-memory trust roots, got \(mTLSTrustConfiguration.source.backing) instead."
                    )
                    return
                }
                #expect(trustRoots == [chain.ca])
            }
        }
    }

    @Suite("End-to-End")
    struct EndToEndConfigurationTests {
        @Test("Configure all possible values")
        @available(anyAppleOS 26.0, *)
        func fullConfiguration() throws {
            let chain = try TestCA.makeSelfSignedChain()
            let certsPEM = try chain.chainPEMString
            let keyPEM = try chain.privateKey.serializeAsPEM().pemString

            let provider = InMemoryProvider(
                values: [
                    "bindTarget.host": "127.0.0.1",
                    "bindTarget.port": 8000,
                    "http.versions": .init(.stringArray(["http1_1", "http2"]), isSecret: false),
                    "http.http2.maxFrameSize": 1,
                    "http.http2.targetWindowSize": 2,
                    "http.http2.maxConcurrentStreams": 3,
                    "http.http2.gracefulShutdown.maximumDuration": 4,
                    "transportSecurity.mode": .init(.string("mTLS"), isSecret: false),
                    "transportSecurity.credentialSource": .init(.string("inline"), isSecret: false),
                    "transportSecurity.certificateChainPEMString": .init(.string(certsPEM), isSecret: false),
                    "transportSecurity.privateKeyPEMString": .init(.string(keyPEM), isSecret: true),
                    "transportSecurity.trustRootsSource": .init(.string("inline"), isSecret: false),
                    "transportSecurity.trustRootsPEMString": .init(.string(certsPEM), isSecret: false),
                    "transportSecurity.certificateVerificationMode": "optionalVerification",
                ]
            )
            let config = ConfigReader(provider: provider)

            let serverConfig = try NIOHTTPServerConfiguration(config: config)

            guard let firstBindTarget = serverConfig.bindTargets.first,
                case .hostAndPort(host: "127.0.0.1", port: 8000) = firstBindTarget.backing
            else {
                Issue.record(
                    "Expected bind target to be 127.0.0.1:8000, got \(serverConfig.bindTargets) instead."
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

            guard case .x509(let x509Credentials) = tlsCredentials.backing,
                case .certificates(let certificateChain, let privateKey) = x509Credentials.backing
            else {
                Issue.record("Expected in-memory TLS credentials, got \(tlsCredentials.backing) instead.")
                return
            }

            guard case .certificates(let trustRoots) = trustConfig.source.backing else {
                Issue.record("Expected in-memory trust roots, got \(trustConfig.source.backing) instead.")
                return
            }

            #expect(trustRoots == chain.chain)
            #expect(certificateChain == chain.chain)
            #expect(privateKey == chain.privateKey)
        }

        @Test("Only HTTP/1.1 supported over plaintext")
        @available(anyAppleOS 26.0, *)
        func onlyHTTP1_1SupportedOverPlaintext() async {
            await #expect(processExitsWith: .failure) {
                let provider = InMemoryProvider(
                    values: [
                        "bindTarget.host": "127.0.0.1",
                        "bindTarget.port": 8000,
                        "http.versions": .init(.stringArray(["http1_1", "http2"]), isSecret: false),
                        "transportSecurity.mode": "plaintext",
                    ]
                )
                let config = ConfigReader(provider: provider)

                _ = try NIOHTTPServerConfiguration(config: config)
            }
        }
    }
}
#endif  // Configuration
