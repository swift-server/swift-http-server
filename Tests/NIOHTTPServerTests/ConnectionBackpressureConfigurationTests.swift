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
    @available(anyAppleOS 26.0, *)
    @Test("maxConnections nil is the default")
    func maxConnectionsNilIsDefault() throws {
        let config = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        #expect(config.maxConnections == nil)
    }

    @available(anyAppleOS 26.0, *)
    @Test("ConnectionTimeouts defaults has expected values")
    func connectionTimeoutsDefaults() {
        let timeouts = NIOHTTPServerConfiguration.ConnectionTimeouts.defaults
        #expect(timeouts.idle == .seconds(60))
        #expect(timeouts.readHeader == .seconds(30))
        #expect(timeouts.readBody == .seconds(60))
    }

    @available(anyAppleOS 26.0, *)
    @Test("Valid maxConnections is accepted")
    func validMaxConnectionsAccepted() throws {
        var config = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )
        config.maxConnections = 100
        #expect(config.maxConnections == 100)
    }

    @available(anyAppleOS 26.0, *)
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
    @available(anyAppleOS 26.0, *)
    @Test("SwiftConfiguration parses maxConnections")
    func parsesMaxConnections() throws {
        let provider = InMemoryProvider(values: [
            "bindTarget.host": "127.0.0.1",
            "bindTarget.port": 8080,
            "http.versions": .init(.stringArray(["http1_1"]), isSecret: false),
            "transportSecurity.mode": "plaintext",
            "maxConnections": 500,
        ])
        let config = ConfigReader(provider: provider)
        let serverConfig = try NIOHTTPServerConfiguration(config: config)

        #expect(serverConfig.maxConnections == 500)
    }

    @available(anyAppleOS 26.0, *)
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

    @available(anyAppleOS 26.0, *)
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

        #expect(serverConfig.maxConnections == nil)
        #expect(serverConfig.connectionTimeouts.idle == nil)
        #expect(serverConfig.connectionTimeouts.readHeader == nil)
        #expect(serverConfig.connectionTimeouts.readBody == nil)
    }
}
#endif  // Configuration
