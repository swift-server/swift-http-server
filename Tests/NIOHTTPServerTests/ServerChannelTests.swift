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
    @Test(
        "transport: TLS, versions: {HTTP/1.1 and/or HTTP/2} -> secure upgrade channel",
        arguments: [
            [NIOHTTPServerConfiguration.HTTPVersion.http1_1],
            [.http2],
            [.http1_1, .http2],
        ]
    )
    func tlsHTTP1_1AndOrHTTP2(
        supportedHTTPVersions: Set<NIOHTTPServerConfiguration.HTTPVersion>
    ) async throws {
        let chain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: self.logger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: supportedHTTPVersions,
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
                supportedHTTPVersions: [.http3],
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
            [NIOHTTPServerConfiguration.HTTPVersion.http1_1, .http3],
            [.http2, .http3],
            [.http1_1, .http2, .http3],
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
    #endif  // HTTP3
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
