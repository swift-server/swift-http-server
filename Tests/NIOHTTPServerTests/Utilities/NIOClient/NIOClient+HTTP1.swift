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

import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOPosix

@testable import NIOHTTPServer

@available(anyAppleOS 27.0, *)
extension Channel {
    /// Adds HTTP/1.1 client handlers to the pipeline, then calls `additionalConnectionChannelInitializer` if provided.
    func configureTestHTTP1ClientPipeline(
        responseLeftOverBytesStrategy: RemoveAfterUpgradeStrategy = .dropBytes,
        informationalResponseStrategy: NIOInformationalResponseStrategy = .forward,
        additionalConnectionChannelInitializer: (@Sendable (any Channel) throws -> Void)? = nil
    ) -> EventLoopFuture<NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>> {
        self.eventLoop.makeCompletedFuture {
            let handlers: [ChannelHandler] = [
                HTTPRequestEncoder(configuration: .init()),
                ByteToMessageHandler(
                    HTTPResponseDecoder(
                        leftOverBytesStrategy: responseLeftOverBytesStrategy,
                        informationalResponseStrategy: informationalResponseStrategy
                    )
                ),
                NIOHTTPRequestHeadersValidator(),
                HTTP1ToHTTPClientCodec(),
            ]
            try self.pipeline.syncOperations.addHandlers(handlers)
            try additionalConnectionChannelInitializer?(self)

            return try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                wrappingChannelSynchronously: self,
                configuration: .init(isOutboundHalfClosureEnabled: true)
            )
        }
    }
}

@available(anyAppleOS 27.0, *)
extension ClientBootstrap {
    /// Connects to the provided `serverAddress` over plaintext HTTP/1.1 and returns a ``TestClientConnection``
    /// wrapping the established connection. Use ``TestClientConnection/makeRequestChannel()`` to obtain a
    /// `NIOAsyncChannel` for writing `HTTPRequestPart`s to the server and observing `HTTPResponsePart`s from its
    /// inbound stream.
    func connectToTestHTTP1Server(
        at serverAddress: NIOHTTPServer.SocketAddress,
        additionalConnectionChannelInitializer: (@Sendable (any Channel) throws -> Void)? = nil
    ) async throws -> TestClientConnection {
        let target: NIOCore.SocketAddress

        switch serverAddress.base {
        case .ipv4(let address):
            target = try NIOCore.SocketAddress(ipAddress: address.host, port: address.port)
        case .ipv6(let address):
            target = try NIOCore.SocketAddress(ipAddress: address.host, port: address.port)
        case .unixDomainSocket(let path):
            target = try NIOCore.SocketAddress(unixDomainSocketPath: path)
        }

        return .init(
            connectionProtocol: .http1(
                connectionChannel: try await self.connect(to: target) { channel in
                    channel.configureTestHTTP1ClientPipeline(
                        additionalConnectionChannelInitializer: additionalConnectionChannelInitializer
                    )
                }
            )
        )
    }
}
