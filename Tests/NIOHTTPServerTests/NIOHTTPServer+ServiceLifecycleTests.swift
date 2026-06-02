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
import HTTPTypes
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTPTypes
import NIOPosix
import ServiceLifecycle
import ServiceLifecycleTestKit
import Testing

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServiceLifecycleTests {
    static let reqHead = HTTPRequestPart.head(.init(method: .post, scheme: "http", authority: "", path: "/"))
    static let bodyData = ByteBuffer(repeating: 5, count: 100)
    static let reqBody = HTTPRequestPart.body(Self.bodyData)
    static let trailer: HTTPFields = [.trailer: "test_trailer"]
    static let reqEnd = HTTPRequestPart.end(trailer)

    let serverLogger = Logger(label: "NIOHTTPServiceLifecycleTests")
    let serviceGroupLogger = Logger(label: "NIOHTTPServiceLifecycleTests_ServiceGroup")

    @Test(
        "Active connection completes when graceful shutdown triggered",
        arguments: [HTTPVersion.http1_1, HTTPVersion.http2]
    )
    @available(anyAppleOS 26.0, *)
    func activeConnectionCanCompleteWhenGracefullyShutdown(httpVersion: HTTPVersion) async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: self.serverLogger)

        // This promise will be fulfilled when the server receives the first part of the body. Once this happens, we can
        // initiate the graceful shutdown and then send the remaining body. If graceful shutdown is respected, we should
        // be able to successfully complete the request.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let firstChunkReadPromise = elg.any().makePromise(of: Void.self)

        let serverService = ClosureService {
            try await server.serve { request, requestContext, requestReader, responseSender in
                _ = try await requestReader.consumeAndConclude { bodyReader in
                    var bodyReader = bodyReader
                    try await bodyReader.read { _ in }

                    firstChunkReadPromise.succeed()

                    var requestFinished = false
                    while !requestFinished {
                        try await bodyReader.read { if $0.isEmpty { requestFinished = true } }
                    }
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

                    let serverAddress = try await server.listeningAddresses.first!

                    let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestSecureUpgradeHTTPServer(
                            at: serverAddress,
                            trustRoots: serverChain.chain,
                            applicationProtocol: httpVersion.alpnIdentifier
                        )
                        .unwrapChannel(expectedHTTPVersion: httpVersion)

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

    @Test(
        "Active connection forcefully shutdown when server task cancelled",
        arguments: [HTTPVersion.http1_1, HTTPVersion.http2]
    )
    @available(anyAppleOS 26.0, *)
    func activeConnectionForcefullyShutdownWhenServerTaskCancelled(httpVersion: HTTPVersion) async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(logger: self.serverLogger)

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
                            try await bodyReader.read { _ in }

                            firstChunkReadPromise.succeed()

                            // The following call will block: the client will never send a request end part. This is
                            // intentional because we want to keep the connection alive.
                            try await bodyReader.read { _ in }
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

                let serverAddress = try await server.listeningAddresses.first!

                let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                    .connectToTestSecureUpgradeHTTPServer(
                        at: serverAddress,
                        trustRoots: serverChain.chain,
                        applicationProtocol: httpVersion.alpnIdentifier
                    )
                    .unwrapChannel(expectedHTTPVersion: httpVersion)

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

                    // Wait for the client channel to be fully closed. The server has closed
                    // its side of the connection, but the client's event loop may not have
                    // processed the TCP FIN/RST yet. closeFuture completes only once the
                    // channel is fully inactive, which is a stronger guarantee than just
                    // draining inbound (which may return while the channel is half-closed).
                    try await client.channel.closeFuture.get()

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
    @available(anyAppleOS 26.0, *)
    func testActiveHTTP2ConnectionIsShutDownAfterGraceTimeout() async throws {
        let serverChain = try TestCA.makeSelfSignedChain()

        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [
                    .http1_1,
                    .http2(config: .init(gracefulShutdown: .init(maximumGracefulShutdownDuration: .milliseconds(500)))),
                ],
                transportSecurity: .tls(
                    credentials: .inMemory(certificateChain: serverChain.chain, privateKey: serverChain.privateKey)
                )
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
                        try await bodyReader.read { _ in }

                        firstChunkReadPromise.succeed()

                        // The following call will block: the client will never send a request end part. This is
                        // intentional because we want to keep the connection alive until the grace timer (500ms) fires.
                        try await bodyReader.read { _ in }
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

                    let serverAddress = try await server.listeningAddresses.first!

                    let client = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestSecureUpgradeHTTPServer(
                            at: serverAddress,
                            trustRoots: [serverChain.ca],
                            applicationProtocol: HTTPVersion.http2.alpnIdentifier
                        )

                    switch client {
                    case .http1:
                        Issue.record("Unexpectedly negotiated a HTTP/2 connection")

                    case .http2(let streamManager):
                        let streamChannel = try await streamManager.openStream()
                        try await streamChannel.executeThenClose { inbound, outbound in
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

    @Test(
        "Active connections across different listeners can complete when graceful shutdown triggered",
        arguments: [
            (HTTPVersion.http1_1, HTTPVersion.http1_1),
            (HTTPVersion.http1_1, HTTPVersion.http2),
            (HTTPVersion.http2, HTTPVersion.http1_1),
            (HTTPVersion.http2, HTTPVersion.http2),
        ]
    )
    @available(anyAppleOS 26.0, *)
    func activeConnectionsAcrossDifferentListenersCanCompleteWhenGracefullyShutdown(
        firstClientHTTPVersion: HTTPVersion,
        secondClientHTTPVersion: HTTPVersion
    ) async throws {
        let (server, serverChain) = try NIOHTTPServerTests.makeSecureUpgradeServer(
            bindTargets: [
                // Configure two bind targets. We want to test whether graceful shutdown works independently on each
                // bind target.
                .hostAndPort(host: "127.0.0.1", port: 0),
                .hostAndPort(host: "127.0.0.1", port: 0),
            ],
            logger: self.serverLogger
        )

        // The test needs both clients to have an active in-flight request before triggering graceful shutdown. To
        // express this, we create two promises (one for each bind target), which will be fulfilled by the server's
        // request handler once it has *started* processing the corresponding request.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let firstTargetRequestStartedPromise = elg.any().makePromise(of: Void.self)
        let secondTargetRequestStartedPromise = elg.any().makePromise(of: Void.self)

        // The server handler needs to know which of the two promises to fulfill. Since the second client only sends
        // its request after the server has started processing the first client's request, we set up a counter so that
        // the server can know to fulfill `firstTargetRequestStartedPromise` on the first request and
        // `secondTargetRequestStartedPromise` on the second request.
        let requestNumber = NIOLockedValueBox(0)

        let serverService = ClosureService {
            try await server.serve { request, requestContext, requestReader, responseSender in
                _ = try await requestReader.consumeAndConclude { bodyReader in
                    var bodyReader = bodyReader
                    try await bodyReader.read { _ in }

                    let count = requestNumber.withLockedValue { n in
                        n += 1
                        return n
                    }

                    if count == 1 {
                        firstTargetRequestStartedPromise.succeed()
                    } else if count == 2 {
                        secondTargetRequestStartedPromise.succeed()
                    }

                    var requestFinished = false
                    while !requestFinished {
                        try await bodyReader.read { if $0.isEmpty { requestFinished = true } }
                    }
                }

                let responseBodyWriter = try await responseSender.send(.init(status: .ok))
                try await responseBodyWriter.produceAndConclude { writer in
                    var writer = writer
                    try await writer.write([1, 2].span)
                    return .none
                }
            }
        }

        try await confirmation(expectedCount: 2) { responseReceived in
            try await testGracefulShutdown { trigger in
                try await withThrowingTaskGroup { group in
                    let serviceGroup = ServiceGroup(services: [serverService], logger: self.serviceGroupLogger)
                    group.addTask { try await serviceGroup.run() }

                    let firstServerAddress = try await server.listeningAddresses[0]
                    let secondServerAddress = try await server.listeningAddresses[1]

                    let firstClient = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                        .connectToTestSecureUpgradeHTTPServer(
                            at: firstServerAddress,
                            trustRoots: serverChain.chain,
                            applicationProtocol: firstClientHTTPVersion.alpnIdentifier
                        )
                        .unwrapChannel(expectedHTTPVersion: firstClientHTTPVersion)

                    try await firstClient.executeThenClose { firstInbound, firstOutbound in
                        try await firstOutbound.write(Self.reqHead)
                        try await firstOutbound.write(Self.reqBody)

                        // Wait until the server has received the body part.
                        try await firstTargetRequestStartedPromise.futureResult.get()

                        let secondClient = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                            .connectToTestSecureUpgradeHTTPServer(
                                at: secondServerAddress,
                                trustRoots: serverChain.chain,
                                applicationProtocol: secondClientHTTPVersion.alpnIdentifier
                            )
                            .unwrapChannel(expectedHTTPVersion: secondClientHTTPVersion)

                        try await secondClient.executeThenClose { secondInbound, secondOutbound in
                            try await secondOutbound.write(Self.reqHead)
                            try await secondOutbound.write(Self.reqBody)

                            // Wait until the server has received the body part.
                            try await secondTargetRequestStartedPromise.futureResult.get()

                            // Now start the shutdown.
                            trigger.triggerGracefulShutdown()

                            // The second client should be able to complete its request.
                            try await secondOutbound.write(Self.reqBody)
                            try await secondOutbound.write(Self.reqEnd)

                            for try await response in secondInbound {
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
                        }

                        // And so should the first client.
                        try await firstOutbound.write(Self.reqBody)
                        try await firstOutbound.write(Self.reqEnd)

                        for try await response in firstInbound {
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
}
