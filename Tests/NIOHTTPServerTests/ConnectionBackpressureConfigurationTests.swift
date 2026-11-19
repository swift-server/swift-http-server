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
        #expect(config.connectionLimits?.tcp == .defaults)
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
    @Test(
        arguments: [
            (1, 1, 1),
            (100, 1_000_000_000, 100),
            (nil, nil, 1),
            // Every limit can be `nil`.
            (nil, nil, nil),
        ] as [(Int?, Int?, Int?)]
    )
    func validConnectionLimitsAccepted(
        maxConnections: Int?,
        newConnectionsPerSecond: Int?,
        maxConcurrentTLSHandshakes: Int?
    ) throws {
        var tcpLimits = NIOHTTPServerConfiguration.TCPConnectionLimits.defaults
        tcpLimits.maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes
        tcpLimits.maxConnections = maxConnections
        tcpLimits.newConnectionsPerSecond = newConnectionsPerSecond

        #expect(tcpLimits.maxConnections == maxConnections)
        #expect(tcpLimits.newConnectionsPerSecond == newConnectionsPerSecond)
        #expect(tcpLimits.maxConcurrentTLSHandshakes == maxConcurrentTLSHandshakes)

        #if HTTP3
        var quicLimits = NIOHTTPServerConfiguration.QUICConnectionLimits.defaults
        quicLimits.maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes
        quicLimits.maxConnections = maxConnections
        quicLimits.newConnectionsPerSecond = newConnectionsPerSecond

        #expect(quicLimits.maxConnections == maxConnections)
        #expect(quicLimits.newConnectionsPerSecond == newConnectionsPerSecond)
        #expect(quicLimits.maxConcurrentTLSHandshakes == maxConcurrentTLSHandshakes)
        #endif
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
    ) async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            [
                maxConnections = maxConnections as Int?,
                newConnectionsPerSecond = newConnectionsPerSecond as Int?,
                maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes as Int?
            ] in
            var config = NIOHTTPServerConfiguration.TCPConnectionLimits.defaults
            config.maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes
            config.maxConnections = maxConnections
            config.newConnectionsPerSecond = newConnectionsPerSecond
        }
        Self.expectStandardError(
            of: result,
            contains: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "connectionLimits.tcp.\(invalidLimit)",
                requirement: requirement
            )
        )
    }

    @available(anyAppleOS 27.0, *)
    @Test("Connection limits can be changed to valid values")
    func connectionLimitsChangedToValidValues() throws {
        var limits = NIOHTTPServerConfiguration.TCPConnectionLimits.defaults
        limits.maxConnections = 20
        limits.newConnectionsPerSecond = 5
        limits.maxConcurrentTLSHandshakes = 1
        // Limits can be removed, including every limit at once.
        limits.maxConnections = nil
        #expect(limits == (try .init(newConnectionsPerSecond: 5, maxConcurrentTLSHandshakes: 1)))
        limits.newConnectionsPerSecond = nil
        limits.maxConcurrentTLSHandshakes = nil
        #expect(limits == (try .init()))

        // Limits can also be changed in place on the server configuration.
        var config = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        config.connectionLimits?.tcp?.maxConnections = 20
        #expect(config.connectionLimits?.tcp?.maxConnections == 20)
    }

    @available(anyAppleOS 27.0, *)
    @Test(
        "Changing a connection limit to an invalid value is a precondition failure",
        arguments: [
            (
                "maxConnections", 0,
                NIOHTTPServerConfigurationError.invalidConnectionLimit(
                    name: "connectionLimits.tcp.maxConnections",
                    requirement: "greater than 0"
                )
            ),
            (
                "newConnectionsPerSecond", 1_000_000_001,
                .invalidConnectionLimit(
                    name: "connectionLimits.tcp.newConnectionsPerSecond",
                    requirement: "between 1 and 1,000,000,000"
                )
            ),
            (
                "maxConcurrentTLSHandshakes", 0,
                .invalidConnectionLimit(
                    name: "connectionLimits.tcp.maxConcurrentTLSHandshakes",
                    requirement: "greater than 0"
                )
            ),
        ] as [(String, Int?, NIOHTTPServerConfigurationError)]
    )
    func invalidConnectionLimitChangePreconditionFailure(
        limit: String,
        value: Int?,
        expectedError: NIOHTTPServerConfigurationError
    ) async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            [limit = limit as String, value = value as Int?] in
            var limits = NIOHTTPServerConfiguration.TCPConnectionLimits.defaults
            limits.maxConnections = 10
            limits.newConnectionsPerSecond = nil
            limits.maxConcurrentTLSHandshakes = nil

            switch limit {
            case "maxConnections":
                limits.maxConnections = value
            case "newConnectionsPerSecond":
                limits.newConnectionsPerSecond = value
            default:
                limits.maxConcurrentTLSHandshakes = value
            }
            _ = limits
        }

        Self.expectStandardError(of: result, contains: expectedError)
    }

    @available(anyAppleOS 27.0, *)
    @Test("Setting a TCP TLS handshake limit with plaintext is a precondition failure")
    func tlsHandshakeLimitWithPlaintextPreconditionFailure() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            var config = try NIOHTTPServerConfiguration(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
            config.connectionLimits?.tcp?.maxConcurrentTLSHandshakes = 5
        }

        Self.expectStandardError(of: result, contains: .tlsHandshakeLimitRequiresTLS)
    }

    #if HTTP3
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
    func outOfRangeQUICConnectionLimitsRejected(
        maxConnections: Int?,
        newConnectionsPerSecond: Int?,
        maxConcurrentTLSHandshakes: Int?,
        invalidLimit: String,
        requirement: String
    ) async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            [
                maxConnections = maxConnections as Int?,
                newConnectionsPerSecond = newConnectionsPerSecond as Int?,
                maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes as Int?
            ] in
            var config = NIOHTTPServerConfiguration.QUICConnectionLimits.defaults
            config.maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes
            config.maxConnections = maxConnections
            config.newConnectionsPerSecond = newConnectionsPerSecond
        }
        Self.expectStandardError(
            of: result,
            contains: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "connectionLimits.quic.\(invalidLimit)",
                requirement: requirement
            )
        )
    }

    @available(anyAppleOS 27.0, *)
    @Test func quicConnectionLimitsDefaults() throws {
        let limits = NIOHTTPServerConfiguration.QUICConnectionLimits.defaults
        #expect(limits.maxConnections == 10_000)
        #expect(limits.newConnectionsPerSecond == 1_000)
        #expect(limits.maxConcurrentTLSHandshakes == nil)

        let (config, _) = try TestHelpers.makeTLSServerConfiguration(supportedHTTPVersions: [.http3])
        #expect(config.connectionLimits?.quic == limits)
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
    @Test func parsesTCPConnectionLimits() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "connectionLimits.tcp.maxConnections": 500,
            "connectionLimits.tcp.newConnectionsPerSecond": 250,
        ])
        let config = ConfigReader(provider: provider)
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        #expect(serverConfig.connectionLimits?.tcp?.maxConnections == 500)
        #expect(serverConfig.connectionLimits?.tcp?.newConnectionsPerSecond == 250)
    }

    @available(anyAppleOS 27.0, *)
    @Test func connectionLimitsConfigUsesDefaults() throws {
        let snapshot = ConfigReader(provider: InMemoryProvider(values: [:])).snapshot()

        let limits = try NIOHTTPServerConfiguration.ConnectionLimits(config: snapshot)
        let defaults = NIOHTTPServerConfiguration.ConnectionLimits.defaults
        #expect(limits == defaults)
    }

    @available(anyAppleOS 27.0, *)
    @Test func zeroTCPConnectionLimitIsUnlimited() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "connectionLimits.tcp.newConnectionsPerSecond": 0,
            "connectionLimits.quic.newConnectionsPerSecond": 0,
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: ConfigReader(provider: provider))

        var expectedTCPConfig = NIOHTTPServerConfiguration.TCPConnectionLimits.defaults
        expectedTCPConfig.newConnectionsPerSecond = nil
        #expect(serverConfig.connectionLimits?.tcp == expectedTCPConfig)

        #if HTTP3
        var expectedQUICConfig = NIOHTTPServerConfiguration.QUICConnectionLimits.defaults
        expectedQUICConfig.newConnectionsPerSecond = nil
        #expect(serverConfig.connectionLimits?.quic == expectedQUICConfig)
        #endif
    }

    @available(anyAppleOS 27.0, *)
    @Test func parsesOnlyTLSHandshakeTCPConnectionLimit() throws {
        let config = try Self.makeTLSConfigReader(
            versions: ["http1_1"],
            additionalValues: [
                "connectionLimits.tcp.maxConnections": 0,
                "connectionLimits.tcp.newConnectionsPerSecond": 0,
                "connectionLimits.tcp.maxConcurrentTLSHandshakes": 500,
            ]
        )
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        var expected = NIOHTTPServerConfiguration.TCPConnectionLimits.defaults
        expected.maxConnections = nil
        expected.newConnectionsPerSecond = nil
        expected.maxConcurrentTLSHandshakes = 500

        #expect(serverConfig.connectionLimits?.tcp == expected)
    }

    @available(anyAppleOS 27.0, *)
    @Test func allZeroTCPConnectionLimitsImposeNoLimits() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "connectionLimits.tcp.maxConnections": 0,
            "connectionLimits.tcp.newConnectionsPerSecond": 0,
            "connectionLimits.tcp.maxConcurrentTLSHandshakes": 0,
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: ConfigReader(provider: provider))

        #expect(serverConfig.connectionLimits?.tcp == nil)
    }

    @available(anyAppleOS 27.0, *)
    @Test func acceptsZeroTLSHandshakeLimitWithPlaintext() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "connectionLimits.tcp.maxConcurrentTLSHandshakes": 0,
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: ConfigReader(provider: provider))

        #expect(serverConfig.connectionLimits?.tcp == .defaults)
    }

    @available(anyAppleOS 27.0, *)
    @Test func rejectsTLSHandshakeLimitWithPlaintext() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "connectionLimits.tcp.maxConcurrentTLSHandshakes": 5,
        ])

        #expect(throws: NIOHTTPServerConfigurationError.tlsHandshakeLimitRequiresTLS) {
            _ = try NIOHTTPServerConfiguration(config: ConfigReader(provider: provider))
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test func allZeroConnectionLimitsImposeNoLimits() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "connectionLimits.tcp.maxConnections": 0,
            "connectionLimits.tcp.newConnectionsPerSecond": 0,
            "connectionLimits.tcp.maxConcurrentTLSHandshakes": 0,
            "connectionLimits.quic.maxConnections": 0,
            "connectionLimits.quic.newConnectionsPerSecond": 0,
            "connectionLimits.quic.maxConcurrentTLSHandshakes": 0,
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: ConfigReader(provider: provider))

        #expect(serverConfig.connectionLimits == nil)
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

        #expect(serverConfig.connectionLimits?.tcp == .defaults)
        #expect(serverConfig.connectionTimeouts.idle == nil)
        #expect(serverConfig.connectionTimeouts.readHeader == nil)
        #expect(serverConfig.connectionTimeouts.readBody == nil)
    }

    @available(anyAppleOS 27.0, *)
    @Test(
        arguments: [
            ("maxConnections", -1, "0 (unlimited) or greater"),
            ("newConnectionsPerSecond", -1, "between 0 (unlimited) and 1,000,000,000"),
            ("newConnectionsPerSecond", 1_000_000_001, "between 0 (unlimited) and 1,000,000,000"),
            ("maxConcurrentTLSHandshakes", -1, "0 (unlimited) or greater"),
        ]
    )
    func rejectsOutOfRangeTCPConnectionLimits(key: String, value: Int, requirement: String) throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            AbsoluteConfigKey(["connectionLimits", "tcp", key]): .init(.int(value), isSecret: false),
        ])
        let config = ConfigReader(provider: provider)

        #expect(
            throws: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "connectionLimits.tcp.\(key)",
                requirement: requirement
            )
        ) {
            _ = try NIOHTTPServerConfiguration(config: config)
        }
    }

    #if HTTP3
    @available(anyAppleOS 27.0, *)
    @Test func parsesQUICConnectionLimits() throws {
        let config = try Self.makeHTTP3ConfigReader(additionalValues: [
            "connectionLimits.quic.maxConnections": 500,
            "connectionLimits.quic.maxConcurrentTLSHandshakes": 50,
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: config)
        let limits = try #require(serverConfig.connectionLimits?.quic)

        #expect(limits.maxConnections == 500)
        #expect(limits.maxConcurrentTLSHandshakes == 50)
        // An omitted key takes its default value.
        #expect(limits.newConnectionsPerSecond == 1_000)
    }

    @available(anyAppleOS 27.0, *)
    @Test func usesDefaultConnectionLimitsForAbsentFieldsOnHTTP3Only() throws {
        let serverConfig = try NIOHTTPServerConfiguration(config: try Self.makeHTTP3ConfigReader())

        #expect(serverConfig.connectionLimits == .defaults)
    }

    @available(anyAppleOS 27.0, *)
    @Test func parsesOnlyTLSHandshakeQUICConnectionLimit() throws {
        let config = try Self.makeHTTP3ConfigReader(additionalValues: [
            "connectionLimits.quic.maxConnections": 0,
            "connectionLimits.quic.newConnectionsPerSecond": 0,
            "connectionLimits.quic.maxConcurrentTLSHandshakes": 50,
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        let limits = try #require(serverConfig.connectionLimits?.quic)

        #expect(limits == (try .init(maxConcurrentTLSHandshakes: 50)))
    }

    @available(anyAppleOS 27.0, *)
    @Test func zeroQUICConnectionLimitsImposeNoLimits() throws {
        // `maxConcurrentTLSHandshakes` is omitted, and defaults to no limit.
        let config = try Self.makeHTTP3ConfigReader(additionalValues: [
            "connectionLimits.quic.maxConnections": 0,
            "connectionLimits.quic.newConnectionsPerSecond": 0,
        ])
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        let limits = try #require(serverConfig.connectionLimits)
        #expect(limits.quic == nil)
        #expect(limits.tcp == .defaults)
    }

    @available(anyAppleOS 27.0, *)
    @Test(
        arguments: [
            ("maxConnections", -1, "0 (unlimited) or greater"),
            ("newConnectionsPerSecond", -1, "between 0 (unlimited) and 1,000,000,000"),
            ("newConnectionsPerSecond", 1_000_000_001, "between 0 (unlimited) and 1,000,000,000"),
            ("maxConcurrentTLSHandshakes", -1, "0 (unlimited) or greater"),
        ]
    )
    func rejectsOutOfRangeQUICConnectionLimits(key: String, value: Int, requirement: String) throws {
        let config = try Self.makeHTTP3ConfigReader(additionalValues: [
            AbsoluteConfigKey(["connectionLimits", "quic", key]): .init(
                .int(value),
                isSecret: false
            )
        ])

        #expect(
            throws: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "connectionLimits.quic.\(key)",
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
        try Self.makeTLSConfigReader(versions: ["http3"], additionalValues: additionalValues)
    }
    #endif

    /// Makes a config reader for a TLS server that supports `versions`, with `additionalValues` added.
    @available(anyAppleOS 27.0, *)
    private static func makeTLSConfigReader(
        versions: [String],
        additionalValues: [AbsoluteConfigKey: ConfigValue] = [:]
    ) throws -> ConfigReader {
        let (leafPath, _, keyPath) = try TestCA.makeSelfSignedChain().writeToDisk()
        let values: [AbsoluteConfigKey: ConfigValue] = [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(versions), isSecret: false),
            "transportSecurity.mode": "tls",
            "transportSecurity.credentialSource": "file",
            "transportSecurity.certificateChainPEMPath": .init(.string(leafPath), isSecret: false),
            "transportSecurity.privateKeyPEMPath": .init(.string(keyPath), isSecret: true),
        ]
        return ConfigReader(
            provider: InMemoryProvider(values: values.merging(additionalValues, uniquingKeysWith: { $1 }))
        )
    }
}
#endif  // Configuration
