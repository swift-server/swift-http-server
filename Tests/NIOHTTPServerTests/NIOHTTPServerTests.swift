//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
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
import Logging
import NIOCore
import NIOHTTPTypes
import NIOPosix
import Testing
import X509

@testable import NIOHTTPServer

#if canImport(Dispatch)
import Dispatch
#endif

@Suite
struct NIOHTTPServerTests {
    static let reqHead = HTTPRequestPart.head(.init(method: .post, scheme: "http", authority: "", path: "/"))
    static let bodyData = ByteBuffer(repeating: 5, count: 100)
    static let reqBody = HTTPRequestPart.body(Self.bodyData)
    static let trailer: HTTPFields = [.trailer: "test_trailer"]
    static let reqEnd = HTTPRequestPart.end(trailer)

    static func clientResponseHandler(
        _ response: HTTPResponsePart,
        expectedStatus: HTTPResponse.Status,
        expectedBody: ByteBuffer,
        expectedTrailers: HTTPFields? = nil
    ) async throws {
        switch response {
        case .head(let head):
            try #require(head.status == expectedStatus)
        case .body(let body):
            try #require(body == expectedBody)
        case .end(let trailers):
            try #require(trailers == expectedTrailers)
        }
    }

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test("Obtain the listening address correctly")
    func testListeningAddress() async throws {
        let server = NIOHTTPServer(
            logger: Logger(label: "NIOHTTPServerTests"),
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 1234))
        )

        try await Self.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in },
            body: { serverAddress in
                let address = try #require(serverAddress.ipv4)
                #expect(address.host == "127.0.0.1")
                #expect(address.port == 1234)
            }
        )

        // Now that the server has shut down, try obtaining the listening address. This should result in an error.
        await #expect(throws: ListeningAddressError.serverClosed) {
            try await server.listeningAddress
        }
    }

    @Test("Plaintext request-response")
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    func testPlaintext() async throws {
        let server = NIOHTTPServer(
            logger: Logger(label: "NIOHTTPServerTests"),
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 0))
        )

        try await Self.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseWriter in
                #expect(request.method == .post)
                #expect(request.path == "/")

                var buffer = ByteBuffer()
                let (_, finalElement) = try await reader.consumeAndConclude { bodyReader in
                    var bodyReader = bodyReader
                    return try await bodyReader.collect(upTo: Self.bodyData.readableBytes + 1) { body in
                        buffer.writeBytes(body.bytes)
                    }
                }
                #expect(buffer == Self.bodyData)
                #expect(finalElement == Self.trailer)

                let responseBodySender = try await responseWriter.send(.init(status: .ok))
                try await responseBodySender.produceAndConclude { responseBodyWriter in
                    var responseBodyWriter = responseBodyWriter
                    try await responseBodyWriter.write([1, 2].span)
                    return Self.trailer
                }
            },
            body: { serverAddress in
                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestHTTP1Server(at: serverAddress)

                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(Self.reqHead)
                    try await outbound.write(Self.reqBody)
                    try await outbound.write(Self.reqEnd)

                    for try await response in inbound {
                        try await Self.clientResponseHandler(
                            response,
                            expectedStatus: .ok,
                            expectedBody: .init([1, 2]),
                            expectedTrailers: Self.trailer
                        )
                    }
                }
            }
        )
    }

    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    @Test(
        "mTLS request-response with custom verification callback returning peer certificates",
        .serialized,
        arguments: ["http/1.1", "h2"]
    )
    func testMTLS(applicationProtocol: String) async throws {
        let serverChain = try TestCA.makeSelfSignedChain()
        let clientChain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: Logger(label: "NIOHTTPServerTests"),
            configuration: .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                transportSecurity: .mTLS(
                    certificateChain: [serverChain.leaf],
                    privateKey: serverChain.privateKey,
                    trustRoots: [clientChain.ca],
                    customCertificateVerificationCallback: { certificates in
                        // Return the peer's certificate chain; this must then be accessible in the request handler
                        .certificateVerified(.init(.init(uncheckedCertificateChain: certificates)))
                    }
                )
            )
        )

        try await Self.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseWriter in
                #expect(request.method == .post)
                #expect(request.path == "/")

                do {
                    let peerChain = try #require(try await NIOHTTPServer.connectionContext.peerCertificateChain)
                    #expect(Array(peerChain) == [clientChain.leaf])
                } catch {
                    Issue.record("Could not obtain the peer's certificate chain: \(error)")
                }

                let (buffer, finalElement) = try await reader.consumeAndConclude { bodyReader in
                    var bodyReader = bodyReader
                    var buffer = ByteBuffer()
                    _ = try await bodyReader.collect(upTo: Self.bodyData.readableBytes + 1) { body in
                        buffer.writeBytes(body.bytes)
                    }
                    return buffer
                }
                #expect(buffer == Self.bodyData)
                #expect(finalElement == Self.trailer)

                let sender = try await responseWriter.send(.init(status: .ok))
                try await sender.produceAndConclude { bodyWriter in
                    var bodyWriter = bodyWriter
                    try await bodyWriter.write([1, 2].span)
                    return Self.trailer
                }
            },
            body: { serverAddress in
                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestSecureUpgradeHTTPServerOverMTLS(
                        at: serverAddress,
                        clientChain: clientChain,
                        trustRoots: [serverChain.ca],
                        applicationProtocol: applicationProtocol
                    )

                let clientChannel: NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>
                switch client {
                case .http1(let http1ClientChannel):
                    guard applicationProtocol == "http/1.1" else {
                        Issue.record("Unexpectedly negotiated a HTTP/1.1 connection")
                        return
                    }
                    clientChannel = http1ClientChannel

                case .http2(let streamManager):
                    guard applicationProtocol == "h2" else {
                        Issue.record("Unexpectedly negotiated a HTTP/2 connection")
                        return
                    }
                    clientChannel = try await streamManager.openStream()
                }

                try await clientChannel.executeThenClose { inbound, outbound in
                    try await outbound.write(Self.reqHead)
                    try await outbound.write(Self.reqBody)
                    try await outbound.write(Self.reqEnd)

                    for try await response in inbound {
                        try await Self.clientResponseHandler(
                            response,
                            expectedStatus: .ok,
                            expectedBody: .init([1, 2]),
                            expectedTrailers: Self.trailer
                        )
                    }
                }
            }
        )
    }
}

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOHTTPServerTests {
    static func withServer(
        server: NIOHTTPServer,
        serverHandler: some HTTPServerRequestHandler<
            NIOHTTPServer.RequestConcludingReader,
            NIOHTTPServer.ResponseConcludingWriter
        >,
        body: (NIOHTTPServer.SocketAddress) async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup { group in
            // Add the server task to the group
            group.addTask {
                try await server.serve(handler: serverHandler)
            }

            // Wait for the server to start listening before running the body closure
            let listeningAddress = try await server.listeningAddress

            try await body(listeningAddress)

            // Shut the server down
            group.cancelAll()
        }
    }
}
