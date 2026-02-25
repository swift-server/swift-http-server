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

    let serverLogger = Logger(label: "Test Server")
    let serviceGroupLogger = Logger(label: "Test ServiceGroup")

    @Test("HTTP/1.1 active connection completes when graceful shutdown triggered", )
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    func activeHTTP1ConnectionCanCompleteWhenGracefulShutdown() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 0))
        )

        // This promise will be fulfilled when the server receives the first part of the body. Once this happens, we can
        // initiate the graceful shutdown and then send the remaining body. If graceful shutdown is respected, we should
        // be able to successfully complete the request.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let firstChunkReadPromise = elg.any().makePromise(of: Void.self)

        let serverService = ClosureService {
            try await server.serve { request, requestContext, requestReader, responseSender in
                _ = try await requestReader.consumeAndConclude { bodyReader in
                    var bodyReader = bodyReader
                    try await bodyReader.read(maximumCount: Self.bodyData.readableBytes) { _ in }

                    firstChunkReadPromise.succeed()

                    try await bodyReader.read(maximumCount: Self.bodyData.readableBytes) { _ in }
                }

                let responseBodyWriter = try await responseSender.send(.init(status: .ok))
                try await responseBodyWriter.produceAndConclude { writer in
                    var writer = writer
                    try await writer.write([1, 2].span)
                    return .none
                }
            }
        }

        try await confirmation { responseReceived in
            try await testGracefulShutdown { trigger in
                try await withThrowingTaskGroup { group in
                    let serviceGroup = ServiceGroup(services: [serverService], logger: self.serviceGroupLogger)
                    group.addTask { try await serviceGroup.run() }

                    let serverAddress = try await server.listeningAddress

                    let client = try await setUpClient(host: serverAddress.host, port: serverAddress.port)

                    try await client.executeThenClose { inbound, outbound in
                        try await outbound.write(Self.reqHead)

                        // Write the first body part.
                        try await outbound.write(Self.reqBody)

                        // Wait until the server has received the first body part.
                        try await firstChunkReadPromise.futureResult.get()

                        // Start the shutdown.
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

                        responseReceived()

                        // The server should now shut down. Wait for this.
                        try await group.waitForAll()
                    }
                }
            }
        }
    }

    @Test("HTTP/1.1 active connection forcefully shutdown when server task cancelled")
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    func activeHTTP1ConnectionForcefullyShutdownWhenServerTaskCancelled() async throws {
        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: .init(bindTarget: .hostAndPort(host: "127.0.0.1", port: 0))
        )

        // This promise will be fulfilled when the server receives the first part of the request body. Once this
        // happens, we cancel the server task and test whether the in-flight request's connection was forcefully shut.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let firstChunkReadPromise = elg.any().makePromise(of: Void.self)

        let serverService = ClosureService {
            await #expect(throws: CancellationError.self) {
                try await server.serve { request, requestContext, requestReader, responseSender in
                    // Read the first chunk, signal `firstChunkReadPromise`, then try to read the second chunk.
                    _ = try await requestReader.consumeAndConclude { bodyReader in
                        var bodyReader = bodyReader

                        let error = try await #require(throws: EitherError<Error, Never>.self) {
                            try await bodyReader.read(maximumCount: Self.bodyData.readableBytes) { _ in }

                            firstChunkReadPromise.succeed()

                            // The following call will block: the client will never send a request end part. This is
                            // intentional because we want to keep the connection alive.
                            try await bodyReader.read(maximumCount: Self.bodyData.readableBytes) { _ in }
                        }
                        #expect(throws: CancellationError.self) { try error.unwrap() }
                    }
                }
            }
        }

        try await confirmation { connectionForcefullyClosed in
            try await withThrowingTaskGroup { group in
                let serviceGroup = ServiceGroup(services: [serverService], logger: self.serviceGroupLogger)
                group.addTask { try await serviceGroup.run() }

                let serverAddress = try await server.listeningAddress

                let client = try await setUpClient(host: serverAddress.host, port: serverAddress.port)

                try await client.executeThenClose { inbound, outbound in
                    try await outbound.write(Self.reqHead)

                    // Write the first body part.
                    try await outbound.write(Self.reqBody)

                    // Wait until the server has received the first body part.
                    try await firstChunkReadPromise.futureResult.get()

                    // Cancel the server task.
                    group.cancelAll()
                    // Wait for the server to shut down.
                    try await group.waitForAll()

                    // We shouldn't be able to complete our request; the server should have shut down.
                    await #expect(throws: ChannelError.ioOnClosedChannel) {
                        try await outbound.write(Self.reqBody)
                    }

                    connectionForcefullyClosed()
                }
            }
        }
    }

    @Test("Active HTTP/2 connection is forcefully shut down upon graceful shutdown timeout")
    @available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
    func testActiveHTTP2ConnectionIsShutDownAfterGraceTimeout() async throws {
        let serverChain = try TestCA.makeSelfSignedChain()
        let clientChain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                transportSecurity: .tls(certificateChain: serverChain.chain, privateKey: serverChain.privateKey),
                http2: .init(gracefulShutdown: .init(maximumGracefulShutdownDuration: .milliseconds(500)))
            )
        )

        // This promise will be fulfilled when the server receives the first part of the request body. Once this
        // happens, we can initiate the graceful shutdown.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let firstChunkReadPromise = elg.any().makePromise(of: Void.self)

        let serverService = ClosureService {
            try await server.serve { request, requestContext, requestReader, responseSender in
                // Read the first chunk, signal `firstChunkReadPromise`, then try to read the second chunk.
                _ = try await requestReader.consumeAndConclude { bodyReader in
                    var bodyReader = bodyReader

                    let error = try await #require(throws: EitherError<Error, Never>.self) {
                        try await bodyReader.read(maximumCount: Self.bodyData.readableBytes) { _ in }

                        firstChunkReadPromise.succeed()

                        // The following call will block: the client will never send a request end part. This is
                        // intentional because we want to keep the connection alive until the grace timer (500ms) fires.
                        try await bodyReader.read(maximumCount: Self.bodyData.readableBytes) { _ in }
                    }
                    #expect(throws: RequestBodyReadError.streamEndedBeforeReceivingRequestEnd) { try error.unwrap() }
                }
            }
        }

        try await confirmation { connectionForcefullyShutdown in
            try await testGracefulShutdown { trigger in
                try await withThrowingTaskGroup { group in
                    let serviceGroup = ServiceGroup(services: [serverService], logger: self.serviceGroupLogger)
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
                        try await firstChunkReadPromise.futureResult.get()

                        // Now trigger graceful shutdown. This should propagate down to the server. The server will
                        // start the 500ms grace timer after which all connections that are still open will be
                        // forcefully closed.
                        trigger.triggerGracefulShutdown()

                        // The server should shut down after 500ms. Wait for this.
                        try await group.waitForAll()

                        // The connection should have been closed: we should get an `ioOnClosedChannel` error.
                        await #expect(throws: ChannelError.ioOnClosedChannel) {
                            try await outbound.write(Self.reqEnd)
                        }

                        connectionForcefullyShutdown()
                    }
                }
            }
        }
    }
}
