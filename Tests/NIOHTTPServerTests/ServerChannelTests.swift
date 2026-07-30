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

import Logging
import NIOCore
import Testing

@testable import NIOHTTPServer

@Suite
struct ServerChannelTests {
    let logger = Logger(label: "ServerChannelTests")

    @available(anyAppleOS 26.0, *)
    @Test("transport: plaintext, versions: {HTTP/1.1} -> plaintext channel")
    func plaintextHTTP1_1() async throws {
        let server = NIOHTTPServer(
            logger: self.logger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .plaintext
            )
        )

        let channels = try await server.makeServerChannels()
        defer { server.close(serverChannels: channels) }

        #expect(channels.count == 1)
        #expect(channels[0].isPlaintextHTTP1_1)
    }

    @available(anyAppleOS 26.0, *)
    @Test("transport: TLS, versions: {HTTP/1.1} -> secure upgrade channel")
    func tlsHTTP1_1() async throws {
        let chain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: self.logger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1],
                transportSecurity: .tls(
                    credentials: .x509(.certificates(chain: chain.chain, privateKey: chain.privateKey))
                )
            )
        )

        let channels = try await server.makeServerChannels()
        defer { server.close(serverChannels: channels) }

        #expect(channels.count == 1)
        #expect(channels[0].isSecureUpgrade)
    }

    @available(anyAppleOS 26.0, *)
    @Test("transport: TLS, versions: {HTTP/1.1, HTTP/2} -> secure upgrade channel")
    func tlsHTTP1_1AndHTTP2() async throws {
        let chain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: self.logger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http1_1, .http2(config: .defaults)],
                transportSecurity: .tls(
                    credentials: .x509(.certificates(chain: chain.chain, privateKey: chain.privateKey))
                )
            )
        )

        let channels = try await server.makeServerChannels()
        defer { server.close(serverChannels: channels) }

        #expect(channels.count == 1)
        #expect(channels[0].isSecureUpgrade)
    }

    #if HTTP3
    @available(anyAppleOS 26.0, *)
    @Test("transport: TLS, versions: {HTTP/3} -> HTTP/3 channel")
    func http3Only() async throws {
        let chain = try TestCA.makeSelfSignedChain()
        let (leafPath, _, keyPath) = try chain.writeToDisk()

        let server = NIOHTTPServer(
            logger: self.logger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [.http3(config: .defaults)],
                transportSecurity: .tls(
                    credentials: .x509(.pemFile(certificateChainPath: leafPath, privateKeyPath: keyPath))
                )
            )
        )

        let channels = try await server.makeServerChannels()
        defer { server.close(serverChannels: channels) }

        #expect(channels.count == 1)
        #expect(channels[0].isHTTP3)
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "transport: TLS, versions: {HTTP/1.1 and/or HTTP/2} + {HTTP/3} -> HTTP/3 and secure upgrade channels",
        arguments: [
            [Self.http1_1, Self.http3],
            [Self.http2, Self.http3],
            [Self.http1_1, Self.http2, Self.http3],
        ]
    )
    func tlsCombinationOfSecureUpgradeAndHTTP3(
        supportedHTTPVersions: Set<NIOHTTPServerConfiguration.HTTPVersion>
    ) async throws {
        let chain = try TestCA.makeSelfSignedChain()
        let (leafPath, _, keyPath) = try chain.writeToDisk()

        let server = NIOHTTPServer(
            logger: self.logger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: supportedHTTPVersions,
                transportSecurity: .tls(
                    credentials: .x509(.pemFile(certificateChainPath: leafPath, privateKeyPath: keyPath))
                )
            )
        )

        let channels = try await server.makeServerChannels()
        defer { server.close(serverChannels: channels) }

        #expect(channels.count == 2)
        #expect(channels[0].isHTTP3)
        #expect(channels[1].isSecureUpgrade)

        // Check whether both channels share the same port
        let http3Address = try #require(channels[0].localAddress)
        let secureUpgradeAddress = try #require(channels[1].localAddress)
        #expect(http3Address.port == secureUpgradeAddress.port)
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "transport: plaintext, versions: HTTP/2 and/or HTTP/3 -> rejected",
        arguments: [
            [Self.http2],
            [Self.http3],
            [Self.http2, Self.http3],
            // Even when HTTP/1.1 is specified, the presence of HTTP/2 and/or HTTP/3 should make the config invalid
            [Self.http1_1, Self.http2],
            [Self.http1_1, Self.http3],
            [Self.http1_1, Self.http2, Self.http3],
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

@available(anyAppleOS 26.0, *)
extension ServerChannelTests {
    private static let http1_1 = NIOHTTPServerConfiguration.HTTPVersion.http1_1

    private static let http2 = NIOHTTPServerConfiguration.HTTPVersion.http2(config: .defaults)

    #if HTTP3
    private static let http3 = NIOHTTPServerConfiguration.HTTPVersion.http3(config: .defaults)
    #endif
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer.ServerChannel {
    var isPlaintextHTTP1_1: Bool {
        switch self {
        case .plaintextHTTP1_1:
            true
        default:
            false
        }
    }

    var isSecureUpgrade: Bool {
        switch self {
        case .secureUpgrade:
            true
        default:
            false
        }
    }

    #if HTTP3
    var isHTTP3: Bool {
        switch self {
        case .http3:
            true
        default:
            false
        }
    }
    #endif

    var localAddress: NIOCore.SocketAddress? {
        switch self {
        case .plaintextHTTP1_1(let serverChannel, _):
            serverChannel.channel.localAddress

        case .secureUpgrade(let serverChannel, _):
            serverChannel.channel.localAddress

        #if HTTP3
        case .http3(let serverChannel, _):
            serverChannel.localAddress
        #endif
        }
    }
}
