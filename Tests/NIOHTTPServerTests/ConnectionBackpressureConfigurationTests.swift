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
    @Test("tcpConnectionLimits has no limits by default")
    func tcpConnectionLimitsUnlimitedByDefault() throws {
        let config = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        #expect(config.tcpConnectionLimits == .defaults)
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
    @Test("Valid TCP connection limits are accepted on a plaintext HTTP/1.1 configuration")
    func validTCPConnectionLimitsAccepted() throws {
        var config = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        for maxConnections in [1, 100] {
            config.tcpConnectionLimits = .init(maxConnections: maxConnections)
            #expect(config.tcpConnectionLimits.maxConnections == maxConnections)
        }
        for newConnectionRateLimit in [1, 1_000_000_000] {
            config.tcpConnectionLimits = .init(newConnectionRateLimit: newConnectionRateLimit)
            #expect(config.tcpConnectionLimits.newConnectionRateLimit == newConnectionRateLimit)
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test func zeroMaxConnectionsPreconditionFailure() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            var config = try NIOHTTPServerConfiguration(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
            config.tcpConnectionLimits = .init(maxConnections: 0)
        }

        Self.expectStandardError(
            of: result,
            contains: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "tcpConnectionLimits.maxConnections",
                requirement: "greater than 0"
            )
        )
    }

    @available(anyAppleOS 27.0, *)
    @Test func tooLargeRateLimitPreconditionFailure() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            var config = try NIOHTTPServerConfiguration(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
            config.tcpConnectionLimits = .init(newConnectionRateLimit: 1_000_000_001)
        }

        Self.expectStandardError(
            of: result,
            contains: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "tcpConnectionLimits.newConnectionRateLimit",
                requirement: "between 1 and 1,000,000,000"
            )
        )
    }

    #if HTTP3
    @available(anyAppleOS 27.0, *)
    @Test func tcpConnectionLimitsOnHTTP3OnlyAreRejected() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            var (config, _) = try TestHelpers.makeTLSServerConfiguration(supportedHTTPVersions: [.http3])
            config.tcpConnectionLimits = .init(maxConnections: 10)
        }

        Self.expectStandardError(
            of: result,
            contains: NIOHTTPServerConfigurationError.tcpConnectionLimitsRequireHTTP1OrHTTP2
        )
    }

    @available(anyAppleOS 27.0, *)
    @Test func switchingToHTTP3OnlyWithTCPConnectionLimitsIsRejected() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            var (config, _) = try TestHelpers.makeTLSServerConfiguration(
                supportedHTTPVersions: [.http1_1, .http2, .http3]
            )
            config.tcpConnectionLimits = .init(maxConnections: 10)
            // We already set a TCP connection limit. Moving to just supporting HTTP/3 should fail.
            config.supportedHTTPVersions = [.http3]
        }

        Self.expectStandardError(
            of: result,
            contains: NIOHTTPServerConfigurationError.tcpConnectionLimitsRequireHTTP1OrHTTP2
        )
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
            "tcpConnectionLimits.newConnectionRateLimit": 250,
        ])
        let config = ConfigReader(provider: provider)
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        #expect(serverConfig.tcpConnectionLimits.maxConnections == 500)
        #expect(serverConfig.tcpConnectionLimits.newConnectionRateLimit == 250)
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

        #expect(serverConfig.tcpConnectionLimits == .defaults)
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
    @Test func rejectsZeroNewConnectionRateLimit() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "tcpConnectionLimits.newConnectionRateLimit": 0,
        ])
        let config = ConfigReader(provider: provider)

        #expect(
            throws: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "tcpConnectionLimits.newConnectionRateLimit",
                requirement: "between 1 and 1,000,000,000"
            )
        ) {
            _ = try NIOHTTPServerConfiguration(config: config)
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test func rejectsTooLargeNewConnectionRateLimit() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "tcpConnectionLimits.newConnectionRateLimit": 1_000_000_001,
        ])
        let config = ConfigReader(provider: provider)

        #expect(
            throws: NIOHTTPServerConfigurationError.invalidConnectionLimit(
                name: "tcpConnectionLimits.newConnectionRateLimit",
                requirement: "between 1 and 1,000,000,000"
            )
        ) {
            _ = try NIOHTTPServerConfiguration(config: config)
        }
    }

    #if HTTP3
    @available(anyAppleOS 27.0, *)
    @Test func rejectsTCPConnectionLimitsOnHTTP3Only() throws {
        let (leafPath, _, keyPath) = try TestCA.makeSelfSignedChain().writeToDisk()
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http3"]), isSecret: false),
            "transportSecurity.mode": "tls",
            "transportSecurity.credentialSource": "file",
            "transportSecurity.certificateChainPEMPath": .init(.string(leafPath), isSecret: false),
            "transportSecurity.privateKeyPEMPath": .init(.string(keyPath), isSecret: true),
            "tcpConnectionLimits.maxConnections": 10,
        ])
        let config = ConfigReader(provider: provider)

        #expect(throws: NIOHTTPServerConfigurationError.tcpConnectionLimitsRequireHTTP1OrHTTP2) {
            _ = try NIOHTTPServerConfiguration(config: config)
        }
    }
    #endif
}
#endif  // Configuration
