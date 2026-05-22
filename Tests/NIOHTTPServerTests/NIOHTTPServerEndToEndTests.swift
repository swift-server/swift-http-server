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

import HTTPAPIs
import Logging
import NIOSSL
import Testing

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServerEndToEndTests {
    @available(anyAppleOS 26.0, *)
    @Test("HTTP/1.1 request and response")
    func testHTTP1_1() async throws {
        try await TestingChannelHTTP1Server.serve(
            logger: Logger(label: "NIOHTTPServerEndToEndTests"),
            handler: HTTPServerClosureRequestHandler { request, reqContext, reqReader, resSender in
                let sender = try await resSender.send(.init(status: .ok))

                try await sender.produceAndConclude { writer in
                    var writer = writer
                    try await writer.write([1, 2].span)
                    return [.serverTiming: "test"]
                }
            }
        ) { server in
            try await server.withConnectedClient { connectionChannel in
                try await connectionChannel.executeThenClose { inbound, outbound in
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

    @available(anyAppleOS 26.0, *)
    @Test("HTTP/2 negotiation")
    func testHTTP2Negotiation() async throws {
        let serverChain = try TestCA.makeSelfSignedChain()
        var clientTLSConfig = TLSConfiguration.makeClientConfiguration()
        clientTLSConfig.trustRoots = try .init(treatingNilAsSystemTrustRoots: [serverChain.ca])
        clientTLSConfig.certificateVerification = .noHostnameVerification
        clientTLSConfig.applicationProtocols = ["http/1.1", "h2"]

        try await TestingChannelSecureUpgradeServer.serve(
            logger: Logger(label: "NIOHTTPServerEndToEndTests"),
            transportSecurity: .tls(
                credentials: .inMemory(
                    certificateChain: serverChain.chain,
                    privateKey: serverChain.privateKey
                )
            ),
            supportedHTTPVersions: [.http1_1, .http2(config: .defaults)],
            handler: HTTPServerClosureRequestHandler { request, reqContext, reqReader, resSender in
                let sender = try await resSender.send(.init(status: .ok))

                try await sender.produceAndConclude { writer in
                    var writer = writer
                    try await writer.write([1, 2].span)
                    return [.serverTiming: "test"]
                }
            }
        ) { server in
            try await server.withConnectedClient(clientTLSConfig: clientTLSConfig) { negotiatedConnectionChannel in
                switch negotiatedConnectionChannel {
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
