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

import AsyncStreaming
import HTTPServer
import HTTPTypes
import Logging
import NIOCore
import NIOHTTPTypes
import NIOPosix
import ServiceLifecycle
import ServiceLifecycleTestKit
import Testing
import X509

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServiceLifecycleTests {
    static let reqHead = HTTPRequestPart.head(.init(method: .post, scheme: "http", authority: "", path: "/"))
    static let bodyData = ByteBuffer(repeating: 5, count: 100)
    static let reqBody = HTTPRequestPart.body(Self.bodyData)
    static let trailer: HTTPFields = [.trailer: "test_trailer"]
    static let reqEnd = HTTPRequestPart.end(trailer)

    @Test("HTTP/1.1 in-flight request completes after graceful shutdown triggered")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testHTTP1ConnectionInFlightRequestCompletesDuringGracefulShutdown() async throws {
        let server = NIOHTTPServer(
            logger: Logger(label: "Test"),
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 0))
        )

        // Create a promise that will be fulfilled when the server receives the request. When this promise is fulfilled,
        // we can initiate the graceful shutdown.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let requestReceivedPromise = elg.any().makePromise(of: Void.self)

        let serverService = HTTPService(server: server) { request, requestContext, reader, responseWriter in
            requestReceivedPromise.succeed()

            // The server is expecting 2 `Self.bodyData` parts. After the client sends the first body part, graceful
            // shutdown is triggered. The client should be able to send the second body part and complete the inflight
            // request before the server shuts down.
            _ = try await reader.consumeAndConclude { bodyReader in
                var bodyReader = bodyReader
                try await bodyReader.collect(upTo: Self.bodyData.readableBytes * 2) { _ in }
            }

            let responseBodyWriter = try await responseWriter.send(.init(status: .ok))
            try await responseBodyWriter.produceAndConclude {
                (writer: consuming HTTPResponseConcludingAsyncWriter.ResponseBodyAsyncWriter) in
                try await writer.write([1, 2].span)
                return .none
            }
        }

        try await testGracefulShutdown { trigger in
            try await withThrowingTaskGroup { group in
                let serviceGroup = ServiceGroup(services: [serverService], logger: .init(label: "test"))
                group.addTask { try await serviceGroup.run() }

                let serverAddress = try await server.listeningAddress

                let client = try await setUpClient(host: serverAddress.host, port: serverAddress.port)

                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(Self.reqHead)

                    // Write the first body part.
                    try await outbound.write(Self.reqBody)

                    // Wait until the server has received the request.
                    try await requestReceivedPromise.futureResult.get()

                    // Start the shutdown
                    trigger.triggerGracefulShutdown()

                    // We should be able to complete our request.
                    try await outbound.write(Self.reqBody)
                    try await outbound.write(Self.reqEnd)

                    for try await response in inbound {
                        switch response {
                        case .head(let head):
                            #expect(head.status == .ok)
                        case .body(let body):
                            #expect(body == .init([1, 2]))
                        case .end(let trailers):
                            #expect(trailers == nil)
                        }
                    }

                    // The server should now shut down. Wait for this.
                    try await group.waitForAll()
                }
            }
        }
    }

    @Test("Long-running HTTP/2 connection is forcefully shut down upon graceful shutdown timeout")
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
    func testLongRunningHTTP2ConnectionIsShutDownAfterGraceTimeout() async throws {
        let serverChain = try TestCA.makeSelfSignedChain()
        let clientChain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: Logger(label: "Test"),
            configuration: .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                transportSecurity: .tls(
                    certificateChain: serverChain.chain,
                    privateKey: serverChain.privateKey
                ),
                http2: .init(gracefulShutdown: .init(maxGraceTime: .milliseconds(500)))
            )
        )

        // Create a promise that will be fulfilled when the server receives the request. When this promise is fulfilled,
        // we can initiate the graceful shutdown.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let requestReceivedPromise = elg.any().makePromise(of: Void.self)

        let serverService = HTTPService(server: server) { request, requestContext, reader, responseWriter in
            requestReceivedPromise.succeed()

            // Consume the body: this will block because the client will never send a request end part. This is
            // intentional because we want to keep the connection alive until the grace timer (500ms) fires.
            _ = try await reader.consumeAndConclude { bodyReader in
                var bodyReader = bodyReader
                let error = try await #require(throws: EitherError<Error, Never>.self) {
                    try await bodyReader.collect(upTo: 100) { _ in }
                }
                #expect(throws: RequestBodyReadError.streamEndedBeforeReceivingRequestEnd) { try error.unwrap() }
            }
        }

        try await testGracefulShutdown { trigger in
            try await withThrowingTaskGroup { group in
                let serviceGroup = ServiceGroup(services: [serverService], logger: .init(label: "test"))
                group.addTask { try await serviceGroup.run() }

                let serverAddress = try await server.listeningAddress

                let client = try await setUpClientWithMTLS(
                    at: serverAddress,
                    chain: clientChain,
                    trustRoots: [serverChain.ca],
                    applicationProtocol: "h2"
                )

                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(Self.reqHead)
                    try await outbound.write(Self.reqBody)

                    // Wait until the server has received the request.
                    try await requestReceivedPromise.futureResult.get()

                    // Now trigger graceful shutdown. This should propagate down to the server. The server will start
                    // the 500ms grace timer after which all connections that are still open will be forcefully-closed.
                    trigger.triggerGracefulShutdown()

                    // The server should shut down after 500ms. Wait for this.
                    try await group.waitForAll()

                    // The connection should have been closed: we should get an `ioOnClosedChannel` error.
                    await #expect(throws: ChannelError.ioOnClosedChannel) {
                        try await outbound.write(Self.reqEnd)
                    }
                }
            }
        }
    }
}
