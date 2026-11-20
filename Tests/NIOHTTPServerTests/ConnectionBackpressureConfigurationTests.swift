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
    @Test func connectionLimitsDefaults() throws {
        let config = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        #expect(config.connectionLimits == .defaults)
    }

    @available(anyAppleOS 27.0, *)
    @Test func connectionLimitsIsEnabled() throws {
        #expect(try !NIOHTTPServerConfiguration.TCPConnectionLimits().isEnabled)
        #expect(try NIOHTTPServerConfiguration.TCPConnectionLimits(maxConnections: 1).isEnabled)
        #expect(try NIOHTTPServerConfiguration.TCPConnectionLimits(newConnectionsPerSecond: 1).isEnabled)
        #expect(try NIOHTTPServerConfiguration.TCPConnectionLimits(maxConcurrentTLSHandshakes: 1).isEnabled)

        #if HTTP3
        #expect(try !NIOHTTPServerConfiguration.QUICConnectionLimits().isEnabled)
        #expect(try NIOHTTPServerConfiguration.QUICConnectionLimits(maxConnections: 1).isEnabled)
        #expect(try NIOHTTPServerConfiguration.QUICConnectionLimits(newConnectionsPerSecond: 1).isEnabled)
        #expect(try NIOHTTPServerConfiguration.QUICConnectionLimits(maxConcurrentTLSHandshakes: 1).isEnabled)
        #endif
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
        arguments: ConnectionLimitsTransport.allCases,
        [
            (0, nil, nil, "maxConnections", "greater than 0"),
            (-1, nil, nil, "maxConnections", "greater than 0"),
            (nil, 0, nil, "newConnectionsPerSecond", "between 1 and 1,000,000,000"),
            (nil, 1_000_000_001, nil, "newConnectionsPerSecond", "between 1 and 1,000,000,000"),
            (nil, nil, 0, "maxConcurrentTLSHandshakes", "greater than 0"),
        ] as [(Int?, Int?, Int?, String, String)]
    )
    func outOfRangeConnectionLimitsRejected(
        transport: ConnectionLimitsTransport,
        limits: (Int?, Int?, Int?, String, String)
    ) async {
        let (maxConnections, newConnectionsPerSecond, maxConcurrentTLSHandshakes, invalidLimit, requirement) = limits
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            [
                transport = transport as ConnectionLimitsTransport,
                maxConnections = maxConnections as Int?,
                newConnectionsPerSecond = newConnectionsPerSecond as Int?,
                maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes as Int?
            ] in

            switch transport {
            case .tcp:
                var config = NIOHTTPServerConfiguration.TCPConnectionLimits.defaults
                config.maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes
                config.maxConnections = maxConnections
                config.newConnectionsPerSecond = newConnectionsPerSecond

            #if HTTP3
            case .quic:
                var config = NIOHTTPServerConfiguration.QUICConnectionLimits.defaults
                config.maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes
                config.maxConnections = maxConnections
                config.newConnectionsPerSecond = newConnectionsPerSecond
            #endif
            }
        }
        Self.expectStandardError(
            of: result,
            contains: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "connectionLimits.\(transport.rawValue).\(invalidLimit)",
                requirement: requirement
            )
        )
    }

    @available(anyAppleOS 27.0, *)
    @Test("Connection limits can be changed to valid values")
    func connectionLimitsChangedToValidValues() throws {
        var config = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        config.connectionLimits?.tcp?.maxConnections = 20
        #expect(config.connectionLimits?.tcp?.maxConnections == 20)
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
    @Test func quicConnectionLimitsDefaults() {
        let limits = NIOHTTPServerConfiguration.QUICConnectionLimits.defaults
        #expect(limits.maxConnections == 10_000)
        #expect(limits.newConnectionsPerSecond == 1_000)
        #expect(limits.maxConcurrentTLSHandshakes == nil)
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

enum ConnectionLimitsTransport: String, CaseIterable, Codable {
    case tcp
    #if HTTP3
    case quic
    #endif
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
            "connectionLimits.tcp.maxConnections": 500,
            "connectionLimits.tcp.newConnectionsPerSecond": 250,
        ])
        let config = ConfigReader(provider: provider)
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        #expect(serverConfig.connectionLimits?.tcp?.maxConnections == 500)
        #expect(serverConfig.connectionLimits?.tcp?.newConnectionsPerSecond == 250)
    }

    @available(anyAppleOS 27.0, *)
    @Test func zeroConnectionLimitMapsToNoLimit() throws {
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

        #expect(serverConfig.connectionLimits == .defaults)
        #expect(serverConfig.connectionTimeouts.idle == nil)
        #expect(serverConfig.connectionTimeouts.readHeader == nil)
        #expect(serverConfig.connectionTimeouts.readBody == nil)
    }

    @available(anyAppleOS 27.0, *)
    @Test(
        arguments: ConnectionLimitsTransport.allCases,
        [
            ("maxConnections", -1, "0 (unlimited) or greater"),
            ("newConnectionsPerSecond", -1, "between 0 (unlimited) and 1,000,000,000"),
            ("newConnectionsPerSecond", 1_000_000_001, "between 0 (unlimited) and 1,000,000,000"),
            ("maxConcurrentTLSHandshakes", -1, "0 (unlimited) or greater"),
        ]
    )
    func rejectsOutOfRangeConnectionLimits(transport: ConnectionLimitsTransport, limit: (String, Int, String)) throws {
        let (key, value, requirement) = limit
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            AbsoluteConfigKey(["connectionLimits", transport.rawValue, key]): .init(.int(value), isSecret: false),
        ])
        let config = ConfigReader(provider: provider)

        #expect(
            throws: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "connectionLimits.\(transport.rawValue).\(key)",
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
        // The default value is used when the key is omitted.
        #expect(limits.newConnectionsPerSecond == 1_000)
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
