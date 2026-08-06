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

import BasicContainers
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
                var buffer = UniqueArray<UInt8>(copying: [1, 2])
                try await resSender.sendAndFinish(.init(status: .ok), buffer: &buffer, trailer: [.serverTiming: "test"])
            }
        ) { server in
            try await server.withConnectedClient { connectionChannel in
                try await connectionChannel.executeThenClose { inbound, outbound in
                    try await outbound.write(.head(.init(method: .get, scheme: "", authority: "", path: "/")))
                    try await outbound.write(.end(nil))

                    try await TestHelpers.validateResponse(
                        inbound,
                        expectedHead: [.makeResponse(status: .ok, for: .http1_1)],
                        expectedBody: [.init([1, 2])],
                        expectedTrailers: [.serverTiming: "test"],
                        expectStreamEnd: false
                    )
                }
            }
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("HTTP/2 negotiation")
    func testHTTP2Negotiation() async throws {
        let serverChain = try TestCA.makeSelfSignedChain()
        var clientTLSConfig = TLSConfiguration.makeClientConfiguration()
        clientTLSConfig.trustRoots = try .certificates([serverChain.ca])
        clientTLSConfig.certificateVerification = .noHostnameVerification
        clientTLSConfig.applicationProtocols = ["http/1.1", "h2"]

        try await TestingChannelSecureUpgradeServer.serve(
            logger: Logger(label: "NIOHTTPServerEndToEndTests"),
            transportSecurity: .tls(
                credentials: .x509(.certificates(chain: serverChain.chain, privateKey: serverChain.privateKey))
            ),
            supportedHTTPVersions: [.http1_1, .http2],
            handler: HTTPServerClosureRequestHandler { request, reqContext, reqReader, resSender in
                var buffer = UniqueArray<UInt8>(copying: [1, 2])
                try await resSender.sendAndFinish(.init(status: .ok), buffer: &buffer, trailer: [.serverTiming: "test"])
            }
        ) { server in
            try await server.withConnectedClient(clientTLSConfig: clientTLSConfig) { negotiatedConnection in
                try await negotiatedConnection
                    .makeRequestChannel(expectedHTTPVersion: .http2)
                    .executeThenClose { inbound, outbound in
                        try await outbound.write(.head(.init(method: .get, scheme: "", authority: "", path: "/")))
                        try await outbound.write(.end(nil))

                        try await TestHelpers.validateResponse(
                            inbound,
                            expectedHead: [.makeResponse(status: .ok, for: .http2)],
                            expectedBody: [.init([1, 2])],
                            expectedTrailers: [.serverTiming: "test"],
                            expectStreamEnd: true
                        )
                    }
            }
        }
    }
}
