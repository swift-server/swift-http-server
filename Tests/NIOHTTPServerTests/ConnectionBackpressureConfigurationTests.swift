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

import Testing

@testable import NIOHTTPServer

@Suite("Connection Backpressure Configuration")
struct ConnectionBackpressureConfigurationTests {
    @available(anyAppleOS 27.0, *)
    @Test func tcpConnectionLimitsDefaults() throws {
        let config = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        #expect(config.tcpConnectionLimits == (try .init(maxConnections: 100_000, newConnectionsPerSecond: 10_000)))
    }

    @available(anyAppleOS 27.0, *)
    @Test func connectionLimitsWithEveryLimitNilRejected() {
        #expect(throws: NIOHTTPServerConfigurationError.noConnectionLimitsSpecified(name: "ConnectionLimits")) {
            _ = try NIOHTTPServerConfiguration.ConnectionLimits()
        }
        #expect(throws: NIOHTTPServerConfigurationError.noConnectionLimitsSpecified(name: "ConnectionLimits")) {
            _ = try NIOHTTPServerConfiguration.ConnectionLimits(
                maxConnections: nil,
                newConnectionsPerSecond: nil,
                maxConcurrentTLSHandshakes: nil
            )
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test func nilConnectionLimitsAccepted() throws {
        #if HTTP3
        var (config, _) = try TestHelpers.makeTLSServerConfiguration(
            supportedHTTPVersions: [.http2, Self.http3(connectionLimits: nil)]
        )
        #expect(try Self.quicConnectionLimits(of: config) == nil)
        #else
        var (config, _) = try TestHelpers.makeTLSServerConfiguration(supportedHTTPVersions: [.http1_1, .http2])
        #endif
        config.tcpConnectionLimits = nil
        #expect(config.tcpConnectionLimits == nil)
    }

    @available(anyAppleOS 27.0, *)
    @Test("ConnectionTimeouts defaults has expected values")
    func connectionTimeoutsDefaults() {
        let timeouts = NIOHTTPServerConfiguration.ConnectionTimeouts.defaults
        #expect(timeouts.idle == .seconds(60))
        #expect(timeouts.readHeader == .seconds(30))
        #expect(timeouts.readBody == .seconds(60))
    }

    @available(anyAppleOS 27.0, *)
    @Test func connectionLimitsInitializerLeavesOmittedLimitsUnset() throws {
        let limits = try NIOHTTPServerConfiguration.ConnectionLimits(maxConnections: 5)
        #expect(limits.maxConnections == 5)
        #expect(limits.newConnectionsPerSecond == nil)
        #expect(limits.maxConcurrentTLSHandshakes == nil)
    }

    @available(anyAppleOS 27.0, *)
    @Test(
        arguments: [
            (1, 1, 1),
            (100, 1_000_000_000, 100),
            (nil, nil, 1),
        ]
    )
    func validConnectionLimitsAccepted(
        maxConnections: Int?,
        newConnectionsPerSecond: Int?,
        maxConcurrentTLSHandshakes: Int?
    ) throws {
        let limits = try NIOHTTPServerConfiguration.ConnectionLimits(
            maxConnections: maxConnections,
            newConnectionsPerSecond: newConnectionsPerSecond,
            maxConcurrentTLSHandshakes: maxConcurrentTLSHandshakes
        )
        #expect(limits.maxConnections == maxConnections)
        #expect(limits.newConnectionsPerSecond == newConnectionsPerSecond)
        #expect(limits.maxConcurrentTLSHandshakes == maxConcurrentTLSHandshakes)

        // The same `ConnectionLimits` value can be used for both TCP and QUIC connections.
        #if HTTP3
        var (config, _) = try TestHelpers.makeTLSServerConfiguration(
            supportedHTTPVersions: [.http2, Self.http3(connectionLimits: limits)]
        )
        #expect(try Self.quicConnectionLimits(of: config) == limits)
        #else
        var (config, _) = try TestHelpers.makeTLSServerConfiguration(supportedHTTPVersions: [.http1_1, .http2])
        #endif
        config.tcpConnectionLimits = limits
        #expect(config.tcpConnectionLimits == limits)
    }

    @available(anyAppleOS 27.0, *)
    @Test(
        arguments: [
            (0, nil, nil, "maxConnections", "greater than 0"),
            (-1, nil, nil, "maxConnections", "greater than 0"),
            (nil, 0, nil, "newConnectionsPerSecond", "between 1 and 1,000,000,000"),
            (nil, 1_000_000_001, nil, "newConnectionsPerSecond", "between 1 and 1,000,000,000"),
            (nil, nil, 0, "maxConcurrentTLSHandshakes", "greater than 0"),
        ] as [(Int?, Int?, Int?, String, String)]
    )
    func outOfRangeConnectionLimitsRejected(
        maxConnections: Int?,
        newConnectionsPerSecond: Int?,
        maxConcurrentTLSHandshakes: Int?,
        invalidLimit: String,
        requirement: String
    ) {
        #expect(
            throws: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "ConnectionLimits.\(invalidLimit)",
                requirement: requirement
            )
        ) {
            _ = try NIOHTTPServerConfiguration.ConnectionLimits(
                maxConnections: maxConnections,
                newConnectionsPerSecond: newConnectionsPerSecond,
                maxConcurrentTLSHandshakes: maxConcurrentTLSHandshakes
            )
        }
    }

    #if HTTP3
    @available(anyAppleOS 27.0, *)
    @Test("TCP connection limits are accepted, and unused, when only HTTP/3 is supported")
    func tcpConnectionLimitsAcceptedOnHTTP3Only() throws {
        var (config, _) = try TestHelpers.makeTLSServerConfiguration(supportedHTTPVersions: [.http1_1, .http2, .http3])
        let limits = try NIOHTTPServerConfiguration.ConnectionLimits(maxConnections: 10)
        config.tcpConnectionLimits = limits

        config.supportedHTTPVersions = [.http3]
        #expect(config.tcpConnectionLimits == limits)
    }

    @available(anyAppleOS 27.0, *)
    @Test("QUIC connection limits limit connections and the connection rate by default")
    func quicConnectionLimitsDefaults() throws {
        let limits = try #require(NIOHTTPServerConfiguration.HTTP3.QUICConfiguration.defaults.connectionLimits)
        #expect(limits.maxConnections == 10_000)
        #expect(limits.newConnectionsPerSecond == 1_000)
        #expect(limits.maxConcurrentTLSHandshakes == nil)

        let (config, _) = try TestHelpers.makeTLSServerConfiguration(supportedHTTPVersions: [.http3])
        #expect(try Self.quicConnectionLimits(of: config) == limits)
    }

    /// An HTTP/3 version with the default configuration, except for the QUIC `connectionLimits`.
    @available(anyAppleOS 27.0, *)
    static func http3(
        connectionLimits: NIOHTTPServerConfiguration.ConnectionLimits?
    ) -> NIOHTTPServerConfiguration.HTTPVersion {
        var http3 = NIOHTTPServerConfiguration.HTTP3.defaults
        http3.quicConfiguration.connectionLimits = connectionLimits
        return .http3(config: http3)
    }

    /// The QUIC connection limits in `configuration`'s HTTP/3 configuration. Fails the test if HTTP/3 is not
    /// supported.
    @available(anyAppleOS 27.0, *)
    static func quicConnectionLimits(
        of configuration: NIOHTTPServerConfiguration,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> NIOHTTPServerConfiguration.ConnectionLimits? {
        let http3Configuration = try #require(
            configuration.supportedHTTPVersions.http3ConfigIfSupported,
            sourceLocation: sourceLocation
        )
        return http3Configuration.quicConfiguration.connectionLimits
    }
    #endif

    /// Checks that the standard error output of an exit test contains the description of `error`.
    @available(anyAppleOS 27.0, *)
    private static func expectStandardError(
        of result: ExitTest.Result?,
        contains error: NIOHTTPServerConfigurationError,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        let standardError = String(decoding: result?.standardErrorContent ?? [], as: UTF8.self)
        #expect(
            standardError.contains(error.description),
            "Standard error should contain '\(error.description)', but was '\(standardError)'",
            sourceLocation: sourceLocation
        )
    }

    @available(anyAppleOS 27.0, *)
    @Test("Custom ConnectionTimeouts are preserved")
    func customConnectionTimeouts() throws {
        var config = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        config.connectionTimeouts = .init(idle: .seconds(10), readHeader: .seconds(5), readBody: nil)
        #expect(config.connectionTimeouts.idle == .seconds(10))
        #expect(config.connectionTimeouts.readHeader == .seconds(5))
        #expect(config.connectionTimeouts.readBody == nil)
    }
}

#if Configuration
import Configuration

@Suite("Connection Backpressure SwiftConfiguration")
struct ConnectionBackpressureSwiftConfigurationTests {
    @available(anyAppleOS 27.0, *)
    @Test("SwiftConfiguration parses tcpConnectionLimits")
    func parsesTCPConnectionLimits() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "tcpConnectionLimits.maxConnections": 500,
            "tcpConnectionLimits.newConnectionsPerSecond": 250,
        ])
        let config = ConfigReader(provider: provider)
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        #expect(serverConfig.tcpConnectionLimits?.maxConnections == 500)
        #expect(serverConfig.tcpConnectionLimits?.newConnectionsPerSecond == 250)
    }

    @available(anyAppleOS 27.0, *)
    @Test("ConnectionLimits reads omitted keys from the provided defaults")
    func connectionLimitsConfigUsesProvidedDefaults() throws {
        let defaults = try NIOHTTPServerConfiguration.ConnectionLimits(maxConnections: 10, newConnectionsPerSecond: 20)
        let snapshot = ConfigReader(provider: InMemoryProvider(values: ["maxConnections": 5])).snapshot()

        let limits = try NIOHTTPServerConfiguration.ConnectionLimits(
            config: snapshot,
            defaults: defaults,
            name: "limits"
        )
        #expect(limits == (try .init(maxConnections: 5, newConnectionsPerSecond: 20)))
    }

    @available(anyAppleOS 27.0, *)
    @Test("SwiftConfiguration imposes no TCP connection limits when enabled is false")
    func disablesTCPConnectionLimits() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "tcpConnectionLimits.enabled": false,
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: ConfigReader(provider: provider))

        #expect(serverConfig.tcpConnectionLimits == nil)
    }

    @available(anyAppleOS 27.0, *)
    @Test("SwiftConfiguration uses the default TCP connection limits when enabled is true")
    func explicitlyEnabledTCPConnectionLimitsUseDefaults() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "tcpConnectionLimits.enabled": true,
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: ConfigReader(provider: provider))

        #expect(
            serverConfig.tcpConnectionLimits == (try .init(maxConnections: 100_000, newConnectionsPerSecond: 10_000))
        )
    }

    @available(anyAppleOS 27.0, *)
    @Test func rejectsDisabledTCPConnectionLimitsWithLimits() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "tcpConnectionLimits.enabled": false,
            "tcpConnectionLimits.maxConnections": 10,
        ])
        let config = ConfigReader(provider: provider)

        #expect(
            throws: NIOHTTPServerSwiftConfigurationError.connectionLimitsDisabledButLimitsProvided(
                scope: "tcpConnectionLimits"
            )
        ) {
            _ = try NIOHTTPServerConfiguration(config: config)
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test("SwiftConfiguration parses connectionTimeouts")
    func parsesConnectionTimeouts() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "connectionTimeouts.idle": 120,
            "connectionTimeouts.readHeader": 15,
            "connectionTimeouts.readBody": 45,
        ])
        let config = ConfigReader(provider: provider)
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        #expect(serverConfig.connectionTimeouts.idle == .seconds(120))
        #expect(serverConfig.connectionTimeouts.readHeader == .seconds(15))
        #expect(serverConfig.connectionTimeouts.readBody == .seconds(45))
    }

    @available(anyAppleOS 27.0, *)
    @Test("SwiftConfiguration uses defaults for absent fields")
    func usesDefaultsForAbsentFields() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
        ])
        let config = ConfigReader(provider: provider)
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        #expect(
            serverConfig.tcpConnectionLimits == (try .init(maxConnections: 100_000, newConnectionsPerSecond: 10_000))
        )
        #expect(serverConfig.connectionTimeouts.idle == nil)
        #expect(serverConfig.connectionTimeouts.readHeader == nil)
        #expect(serverConfig.connectionTimeouts.readBody == nil)
    }

    @available(anyAppleOS 27.0, *)
    @Test func rejectsZeroMaxConnections() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "tcpConnectionLimits.maxConnections": 0,
        ])
        let config = ConfigReader(provider: provider)

        #expect(
            throws: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "tcpConnectionLimits.maxConnections",
                requirement: "greater than 0"
            )
        ) {
            _ = try NIOHTTPServerConfiguration(config: config)
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test func rejectsZeroNewConnectionsPerSecondRateLimit() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "tcpConnectionLimits.newConnectionsPerSecond": 0,
        ])
        let config = ConfigReader(provider: provider)

        #expect(
            throws: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "tcpConnectionLimits.newConnectionsPerSecond",
                requirement: "between 1 and 1,000,000,000"
            )
        ) {
            _ = try NIOHTTPServerConfiguration(config: config)
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test func rejectsTooLargeNewConnectionsPerSecondRateLimit() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "tcpConnectionLimits.newConnectionsPerSecond": 1_000_000_001,
        ])
        let config = ConfigReader(provider: provider)

        #expect(
            throws: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "tcpConnectionLimits.newConnectionsPerSecond",
                requirement: "between 1 and 1,000,000,000"
            )
        ) {
            _ = try NIOHTTPServerConfiguration(config: config)
        }
    }

    #if HTTP3
    @available(anyAppleOS 27.0, *)
    @Test("SwiftConfiguration accepts TCP connection limits when only HTTP/3 is supported")
    func acceptsTCPConnectionLimitsOnHTTP3Only() throws {
        let config = try Self.makeHTTP3ConfigReader(additionalValues: ["tcpConnectionLimits.maxConnections": 10])
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        #expect(serverConfig.tcpConnectionLimits?.maxConnections == 10)
    }

    @available(anyAppleOS 27.0, *)
    @Test("SwiftConfiguration parses the QUIC connection limits")
    func parsesQUICConnectionLimits() throws {
        let config = try Self.makeHTTP3ConfigReader(additionalValues: [
            "http.http3.quicConfiguration.connectionLimits.maxConnections": 500,
            "http.http3.quicConfiguration.connectionLimits.maxConcurrentTLSHandshakes": 50,
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: config)
        let limits = try #require(try ConnectionBackpressureConfigurationTests.quicConnectionLimits(of: serverConfig))

        #expect(limits.maxConnections == 500)
        #expect(limits.maxConcurrentTLSHandshakes == 50)
        // An omitted key takes its default value.
        #expect(limits.newConnectionsPerSecond == 1_000)
    }

    @available(anyAppleOS 27.0, *)
    @Test("SwiftConfiguration uses the default connection limits for absent fields on an HTTP/3 only server")
    func usesDefaultConnectionLimitsForAbsentFieldsOnHTTP3Only() throws {
        let serverConfig = try NIOHTTPServerConfiguration(config: try Self.makeHTTP3ConfigReader())

        #expect(
            try ConnectionBackpressureConfigurationTests.quicConnectionLimits(of: serverConfig)
                == NIOHTTPServerConfiguration.HTTP3.QUICConfiguration.defaults.connectionLimits
        )
        #expect(
            serverConfig.tcpConnectionLimits == (try .init(maxConnections: 100_000, newConnectionsPerSecond: 10_000))
        )
    }

    @available(anyAppleOS 27.0, *)
    @Test("SwiftConfiguration imposes no QUIC connection limits when enabled is false")
    func disablesQUICConnectionLimits() throws {
        let config = try Self.makeHTTP3ConfigReader(additionalValues: [
            "http.http3.quicConfiguration.connectionLimits.enabled": false
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        #expect(try ConnectionBackpressureConfigurationTests.quicConnectionLimits(of: serverConfig) == nil)
    }

    @available(anyAppleOS 27.0, *)
    @Test func rejectsDisabledQUICConnectionLimitsWithLimits() throws {
        let config = try Self.makeHTTP3ConfigReader(additionalValues: [
            "http.http3.quicConfiguration.connectionLimits.enabled": false,
            "http.http3.quicConfiguration.connectionLimits.newConnectionsPerSecond": 10,
        ])

        #expect(
            throws: NIOHTTPServerSwiftConfigurationError.connectionLimitsDisabledButLimitsProvided(
                scope: "http3.quicConfiguration.connectionLimits"
            )
        ) {
            _ = try NIOHTTPServerConfiguration(config: config)
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test(
        "SwiftConfiguration rejects out of range QUIC connection limits",
        arguments: [
            ("maxConnections", 0, "greater than 0"),
            ("newConnectionsPerSecond", 0, "between 1 and 1,000,000,000"),
            ("newConnectionsPerSecond", 1_000_000_001, "between 1 and 1,000,000,000"),
            ("maxConcurrentTLSHandshakes", 0, "greater than 0"),
        ]
    )
    func rejectsOutOfRangeQUICConnectionLimits(key: String, value: Int, requirement: String) throws {
        let config = try Self.makeHTTP3ConfigReader(additionalValues: [
            AbsoluteConfigKey(["http", "http3", "quicConfiguration", "connectionLimits", key]): .init(
                .int(value),
                isSecret: false
            )
        ])

        #expect(
            throws: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "http3.quicConfiguration.connectionLimits.\(key)",
                requirement: requirement
            )
        ) {
            _ = try NIOHTTPServerConfiguration(config: config)
        }
    }

    /// Makes a config reader for a TLS server that only supports HTTP/3, with `additionalValues` added.
    @available(anyAppleOS 27.0, *)
    private static func makeHTTP3ConfigReader(
        additionalValues: [AbsoluteConfigKey: ConfigValue] = [:]
    ) throws -> ConfigReader {
        let (leafPath, _, keyPath) = try TestCA.makeSelfSignedChain().writeToDisk()
        let values: [AbsoluteConfigKey: ConfigValue] = [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http3"]), isSecret: false),
            "transportSecurity.mode": "tls",
            "transportSecurity.credentialSource": "file",
            "transportSecurity.certificateChainPEMPath": .init(.string(leafPath), isSecret: false),
            "transportSecurity.privateKeyPEMPath": .init(.string(keyPath), isSecret: true),
        ]
        return ConfigReader(
            provider: InMemoryProvider(values: values.merging(additionalValues, uniquingKeysWith: { $1 }))
        )
    }
    #endif
}
#endif  // Configuration
