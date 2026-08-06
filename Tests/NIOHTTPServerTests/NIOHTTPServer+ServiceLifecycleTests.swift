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
import BasicContainers
import HTTPTypes
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTPTypes
import NIOPosix
import NIOSSL
import ServiceLifecycle
import ServiceLifecycleTestKit
import Testing

@testable import NIOHTTPServer

#if HTTP3
import HTTP3
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import NIOQUIC
#endif

@Suite
struct NIOHTTPServiceLifecycleTests {
    let clientLogger = Logger(label: "NIOHTTPServiceLifecycleTests.client")
    let serverLogger = Logger(label: "NIOHTTPServiceLifecycleTests.server")
    let serviceGroupLogger = Logger(label: "NIOHTTPServiceLifecycleTests.serviceGroup")

    @Test(
        "Active connection completes when graceful shutdown triggered",
        arguments: [NIOHTTPServer.HTTPVersion.http1_1, .http2]
    )
    @available(anyAppleOS 26.0, *)
    func activeConnectionCanCompleteWhenGracefullyShutdown(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        // This promise will be fulfilled when the server receives the first part of the body. Once this happens, we can
        // initiate the graceful shutdown and then send the remaining body. If graceful shutdown is respected, we should
        // be able to successfully complete the request.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let firstChunkReadPromise = elg.any().makePromise(of: Void.self)

        let serverService = ClosureService {
            try await server.serve { request, requestContext, requestReader, responseSender in
                var requestReader = requestReader
                try await requestReader.read { _, _ in }

                firstChunkReadPromise.succeed()

                var requestFinished = false
                while !requestFinished {
                    try await requestReader.read { if $1 != nil { requestFinished = true } }
                }

                var buffer = UniqueArray<UInt8>(copying: [1, 2])
                try await responseSender.sendAndFinish(.init(status: .ok), buffer: &buffer)
            }
        }

        try await confirmation { responseReceived in
            try await testGracefulShutdown { trigger in
                try await withThrowingTaskGroup { group in
                    let serviceGroup = ServiceGroup(services: [serverService], logger: self.serviceGroupLogger)
                    group.addTask { try await serviceGroup.run() }

                    let serverAddress = try await server.listeningAddresses.first!

                    try await TestClientConnection.withConnectedRequestChannel(
                        configuration: clientConfiguration,
                        serverAddress: serverAddress
                    ) { inbound, outbound in
                        try await outbound.write(.testHead(method: .post, for: httpVersion))

                        // Write the first body part.
                        try await outbound.write(.testBody)

                        // Wait until the server has received the first body part.
                        try await firstChunkReadPromise.futureResult.get()

                        // Start the shutdown.
                        trigger.triggerGracefulShutdown()

                        // We should be able to complete our request.
                        try await outbound.write(.testBody)
                        try await outbound.write(.testEnd)

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
        "Server closes active connection upon forceful shutdown",
        arguments: [NIOHTTPServer.HTTPVersion.http1_1, .http2]
    )
    @available(anyAppleOS 26.0, *)
    func testServerClosesActiveConnectionOnForcefulShutdown(httpVersion: NIOHTTPServer.HTTPVersion) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        // This promise will be fulfilled when the server receives the first part of the request body. Once this
        // happens, we cancel the server task and test whether the client's socket channel has closed.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let firstChunkReadPromise = elg.any().makePromise(of: Void.self)

        let serverService = ClosureService {
            await #expect(throws: CancellationError.self) {
                try await server.serve { request, requestContext, requestReader, responseSender in
                    var requestReader = requestReader
                    // Read the first chunk, signal `firstChunkReadPromise`, then try to read the second chunk.
                    let error = try await #require(throws: EitherError<Error, Never>.self) {
                        try await requestReader.read { _, _ in }

                        firstChunkReadPromise.succeed()

                        // The following call will block: the client will never send a request end part. This is
                        // intentional because we want to keep the connection alive.
                        try await requestReader.read { _, _ in }
                    }
                    #expect(throws: CancellationError.self) { try error.unwrap() }
                }
            }
        }

        try await withThrowingTaskGroup { group in
            let serviceGroup = ServiceGroup(services: [serverService], logger: self.serviceGroupLogger)
            group.addTask { try await serviceGroup.run() }

            let serverAddress = try await server.listeningAddresses.first!

            try await TestClientConnection.withConnection(
                configuration: clientConfiguration,
                serverAddress: serverAddress
            ) { connection in
                let clientRequestChannel = try await connection.makeRequestChannel(expectedHTTPVersion: httpVersion)

                try await clientRequestChannel.executeThenClose { inbound, outbound in
                    try await outbound.write(.testHead(method: .post, for: httpVersion))

                    // Write the first body part.
                    try await outbound.write(.testBody)

                    // Wait until the server has received the first body part.
                    try await firstChunkReadPromise.futureResult.get()

                    // Cancel the server task.
                    group.cancelAll()
                    // Wait for the server to shut down.
                    try await group.waitForAll()

                    // Wait for the client channel to be fully closed.
                    try await clientRequestChannel.channel.closeFuture.get()

                    // We shouldn't be able to complete our request; the server should have shut down.
                    await #expect(throws: ChannelError.ioOnClosedChannel) {
                        try await outbound.write(.testBody)
                    }
                }
            }
        }
    }

    @Test(
        "Active connection forcefully shutdown when server task cancelled",
        arguments: [NIOHTTPServer.HTTPVersion.http1_1, .http2]
    )
    @available(anyAppleOS 26.0, *)
    func activeConnectionForcefullyShutdownWhenServerTaskCancelled(httpVersion: NIOHTTPServer.HTTPVersion) async throws
    {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        // This promise will be fulfilled when the server receives the first part of the request body. Once this
        // happens, we cancel the server task and test whether the in-flight request's connection was forcefully shut.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let firstChunkReadPromise = elg.any().makePromise(of: Void.self)

        let serverService = ClosureService {
            await #expect(throws: CancellationError.self) {
                try await server.serve { request, requestContext, requestReader, responseSender in
                    var requestReader = requestReader
                    // Read the first chunk, signal `firstChunkReadPromise`, then try to read the second chunk.

                    let error = try await #require(throws: EitherError<Error, Never>.self) {
                        try await requestReader.read { _, _ in }

                        firstChunkReadPromise.succeed()

                        // The following call will block: the client will never send a request end part. This is
                        // intentional because we want to keep the connection alive.
                        try await requestReader.read { _, _ in }
                    }
                    #expect(throws: CancellationError.self) { try error.unwrap() }
                }
            }
        }

        try await confirmation { connectionForcefullyClosed in
            try await withThrowingTaskGroup { group in
                let serviceGroup = ServiceGroup(services: [serverService], logger: self.serviceGroupLogger)
                group.addTask { try await serviceGroup.run() }

                let serverAddress = try await server.listeningAddresses.first!

                try await TestClientConnection.withConnection(
                    configuration: clientConfiguration,
                    serverAddress: serverAddress
                ) { clientConnection in
                    let requestChannel = try await clientConnection.makeRequestChannel(expectedHTTPVersion: httpVersion)

                    try await requestChannel.executeThenClose { inbound, outbound in
                        try await outbound.write(.testHead(method: .post, for: httpVersion))

                        // Write the first body part.
                        try await outbound.write(.testBody)

                        // Wait until the server has received the first body part.
                        try await firstChunkReadPromise.futureResult.get()

                        // Cancel the server task.
                        group.cancelAll()
                        // Wait for the server to shut down.
                        try await group.waitForAll()

                        // Wait for the client channel to be fully closed. The server has closed its side of the
                        // connection, but the client's event loop may not have processed the TCP FIN/RST yet.
                        // closeFuture completes only once the channel is fully inactive, which is a stronger guarantee
                        // than just draining inbound (which may return while the channel is half-closed).
                        try await requestChannel.channel.closeFuture.get()

                        // We shouldn't be able to complete our request; the server should have shut down.
                        await #expect(throws: ChannelError.ioOnClosedChannel) {
                            try await outbound.write(.testBody)
                        }
                    }

                    connectionForcefullyClosed()
                }
            }
        }
    }

    @Test("Active HTTP/2 connection is forcefully shut down upon graceful shutdown timeout")
    @available(anyAppleOS 26.0, *)
    func testActiveHTTP2ConnectionIsShutDownAfterGraceTimeout() async throws {
        let (leafPath, caPath, keyPath) = try TestCA.makeSelfSignedChain().writeToDisk()

        let server = NIOHTTPServer(
            logger: self.serverLogger,
            configuration: try .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
                supportedHTTPVersions: [
                    .http1_1,
                    .http2(config: .init(gracefulShutdown: .init(maximumGracefulShutdownDuration: .milliseconds(500)))),
                ],
                transportSecurity: .tls(
                    credentials: .x509(.pemFile(certificateChainPath: leafPath, privateKeyPath: keyPath))
                )
            )
        )

        // This promise will be fulfilled when the server receives the first part of the request body. Once this
        // happens, we can initiate the graceful shutdown.
        let elg = MultiThreadedEventLoopGroup.singletonMultiThreadedEventLoopGroup
        let firstChunkReadPromise = elg.any().makePromise(of: Void.self)

        let serverService = ClosureService {
            try await server.serve { request, requestContext, requestReader, responseSender in
                var requestReader = requestReader
                // Read the first chunk, signal `firstChunkReadPromise`, then try to read the second chunk.

                let error = try await #require(throws: EitherError<Error, Never>.self) {
                    try await requestReader.read { _, _ in }

                    firstChunkReadPromise.succeed()

                    // The following call will block: the client will never send a request end part. This is
                    // intentional because we want to keep the connection alive until the grace timer (500ms) fires.
                    try await requestReader.read { _, _ in }
                }
                #expect(throws: RequestBodyReadError.streamEndedBeforeReceivingRequestEnd) { try error.unwrap() }
            }
        }

        try await confirmation { connectionForcefullyShutdown in
            try await testGracefulShutdown { trigger in
                try await withThrowingTaskGroup { group in
                    let serviceGroup = ServiceGroup(services: [serverService], logger: self.serviceGroupLogger)
                    group.addTask { try await serviceGroup.run() }

                    let serverAddress = try await server.listeningAddresses.first!

                    try await TestClientConnection.withConnectedRequestChannel(
                        configuration: .init(
                            logger: self.clientLogger,
                            httpVersion: .http2,
                            trustRootsPEMPath: caPath
                        ),
                        serverAddress: serverAddress
                    ) { inbound, outbound in
                        try await outbound.write(.testHead(method: .post, for: .http2))
                        try await outbound.write(.testBody)

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
                            try await outbound.write(.testEnd)
                        }

                        connectionForcefullyShutdown()
                    }
                }
            }
        }
    }

    @Test(
        "Active connections across different listeners can complete when graceful shutdown triggered",
        arguments: [
            (NIOHTTPServer.HTTPVersion.http1_1, NIOHTTPServer.HTTPVersion.http1_1),
            (.http1_1, .http2),
            (.http2, .http1_1),
            (.http2, .http2),
        ]
    )
    @available(anyAppleOS 26.0, *)
    func activeConnectionsAcrossDifferentListenersCanCompleteWhenGracefullyShutdown(
        firstClientHTTPVersion: NIOHTTPServer.HTTPVersion,
        secondClientHTTPVersion: NIOHTTPServer.HTTPVersion
    ) async throws {
        // Configure two listeners. We want to test whether graceful shutdown works independently on each listener.
        let (serverConfiguration, trustRootsPEMPath) = try TestHelpers.makeSecureUpgradeServerConfiguration(
            supportedHTTPVersions: [.http1_1, .http2],
            concurrentListeners: 2
        )
        let server = NIOHTTPServer(logger: self.serverLogger, configuration: serverConfiguration)

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
                var requestReader = requestReader
                try await requestReader.read { _, _ in }

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
                    try await requestReader.read { if $1 != nil { requestFinished = true } }
                }

                var buffer = UniqueArray<UInt8>(copying: [1, 2])
                try await responseSender.sendAndFinish(.init(status: .ok), buffer: &buffer)
            }
        }

        try await confirmation(expectedCount: 2) { responseReceived in
            try await testGracefulShutdown { trigger in
                try await withThrowingTaskGroup { group in
                    let serviceGroup = ServiceGroup(services: [serverService], logger: self.serviceGroupLogger)
                    group.addTask { try await serviceGroup.run() }

                    let firstServerAddress = try await server.listeningAddresses[0]
                    let secondServerAddress = try await server.listeningAddresses[1]

                    try await TestClientConnection.withConnectedRequestChannel(
                        configuration: TestHelpers.ClientConfiguration(
                            logger: self.clientLogger,
                            httpVersion: firstClientHTTPVersion,
                            trustRootsPEMPath: trustRootsPEMPath
                        ),
                        serverAddress: firstServerAddress
                    ) { firstInbound, firstOutbound in
                        try await firstOutbound.write(.testHead(method: .post, for: firstClientHTTPVersion))
                        try await firstOutbound.write(.testBody)

                        // Wait until the server has received the body part.
                        try await firstTargetRequestStartedPromise.futureResult.get()

                        try await TestClientConnection.withConnectedRequestChannel(
                            configuration: TestHelpers.ClientConfiguration(
                                logger: self.clientLogger,
                                httpVersion: secondClientHTTPVersion,
                                trustRootsPEMPath: trustRootsPEMPath
                            ),
                            serverAddress: secondServerAddress
                        ) { secondInbound, secondOutbound in
                            try await secondOutbound.write(.testHead(method: .post, for: secondClientHTTPVersion))
                            try await secondOutbound.write(.testBody)

                            // Wait until the server has received the body part.
                            try await secondTargetRequestStartedPromise.futureResult.get()

                            // Now start the shutdown.
                            trigger.triggerGracefulShutdown()

                            // The second client should be able to complete its request.
                            try await secondOutbound.write(.testBody)
                            try await secondOutbound.write(.testEnd)

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
                        try await firstOutbound.write(.testBody)
                        try await firstOutbound.write(.testEnd)

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
