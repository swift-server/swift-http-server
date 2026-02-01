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

import HTTPServer
import HTTPTypes
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP2
import NIOSSL
import Testing
import X509

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServerEndToEndTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test("HTTP/1.1 request and response")
    func testHTTP1_1() async throws {
        try await HTTP1ClientServerProvider.withProvider(
            handler: HTTPServerClosureRequestHandler { request, reqContext, reqReader, resSender in
                let sender = try await resSender.send(.init(status: .ok))

                try await sender.produceAndConclude { writer in
                    var writer = writer
                    try await writer.write([1, 2].span)
                    return [.serverTiming: "test"]
                }
            }
        ) { clientServerProvider in
            try await clientServerProvider.withConnectedClient { client in
                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(.head(.init(method: .get, scheme: "", authority: "", path: "/")))
                    try await outbound.write(.end(nil))

                    var inboundIterator = inbound.makeAsyncIterator()

                    let head = try await inboundIterator.next()
                    guard case .head(let responseHead) = head else {
                        Issue.record("Expected response head but received \(head).")
                        return
                    }
                    #expect(responseHead.status == 200)
                    #expect(responseHead.headerFields == [.transferEncoding: "chunked"])

                    let body = try await inboundIterator.next()
                    guard case .body(let responseBody) = body else {
                        Issue.record("Expected response body but received \(body).")
                        return
                    }
                    #expect(responseBody == .init([1, 2]))

                    let end = try await inboundIterator.next()
                    guard case .end(let responseEnd) = end else {
                        Issue.record("Expected response end but received \(end).")
                        return
                    }
                    #expect(responseEnd == [.serverTiming: "test"])
                }
            }
        }
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    @Test("HTTP/2 negotiation")
    func testSecureUpgradeNegotiation() async throws {
        let serverChain = try TestCA.makeSelfSignedChain()
        var serverTLSConfig = TLSConfiguration.makeServerConfiguration(
            certificateChain: [try .init(serverChain.leaf)],
            privateKey: try .init(serverChain.privateKey)
        )
        serverTLSConfig.applicationProtocols = ["h2", "http/1.1"]

        var clientTLSConfig = TLSConfiguration.makeClientConfiguration()
        clientTLSConfig.trustRoots = try .init(treatingNilAsSystemTrustRoots: [serverChain.ca])
        clientTLSConfig.certificateVerification = .noHostnameVerification
        clientTLSConfig.applicationProtocols = ["h2"]

        try await HTTPSecureUpgradeClientServerProvider.withProvider(
            tlsConfiguration: serverTLSConfig,
            handler: HTTPServerClosureRequestHandler { request, reqContext, reqReader, resSender in
                let sender = try await resSender.send(.init(status: .ok))

                try await sender.produceAndConclude { writer in
                    var writer = writer
                    try await writer.write([1, 2].span)
                    return [.serverTiming: "test"]
                }
            }
        ) { clientServerProvider in
            try await clientServerProvider.withConnectedClient(clientTLSConfiguration: clientTLSConfig) {
                negotiatedConnection in
                switch negotiatedConnection {
                case .http1(_):
                    Issue.record("Failed to negotiate HTTP/2 despite the client requiring HTTP/2.")
                case .http2(let http2StreamManager):
                    let http2AsyncChannel = try await http2StreamManager.openStream()

                    try await http2AsyncChannel.executeThenClose { inbound, outbound in
                        try await outbound.write(.head(.init(method: .get, scheme: "", authority: "", path: "/")))
                        try await outbound.write(.end(nil))

                        var inboundIterator = inbound.makeAsyncIterator()

                        let head = try await inboundIterator.next()
                        guard case .head(let responseHead) = head else {
                            Issue.record("Expected response head but received \(head).")
                            return
                        }
                        #expect(responseHead.status == 200)

                        let body = try await inboundIterator.next()
                        guard case .body(let responseBody) = body else {
                            Issue.record("Expected response body but received \(body).")
                            return
                        }
                        #expect(responseBody == .init([1, 2]))

                        let end = try await inboundIterator.next()
                        guard case .end(let responseEnd) = end else {
                            Issue.record("Expected response end but received \(end).")
                            return
                        }
                        #expect(responseEnd == [.serverTiming: "test"])
                    }
                }
            }
        }
    }
}
