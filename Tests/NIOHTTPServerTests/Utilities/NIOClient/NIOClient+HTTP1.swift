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
import NIOHTTPServer
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOPosix

/// Provides NIO HTTP clients for testing that one can interact with using `NIOHTTPTypes`.
///
/// Server responses are `NIOHTTPTypes/HTTPResponsePart` and client requests are `NIOHTTPTypes/HTTPRequestPart`.
/// With the ``NIOAsyncChannel`` the `setUpClient` methods vend, one can write `HTTPRequestPart`s to the channel
/// and observe `HTTPResponsePart`s from the inbound stream of the async channel.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct NIOHTTP1Client {
    /// Configures a channel with HTTP/1.1 client handlers for interaction in terms of HTTP types.
    static func clientChannelInitializer(_ channel: Channel) throws {
        try channel.pipeline.syncOperations.addHTTPClientHandlers()
        try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPClientCodec())
    }

    /// Creates and connects an HTTP/1.1 client to the specified address.
    static func setUpChannel(
        at address: NIOHTTPServer.SocketAddress
    ) async throws -> NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart> {
        try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connect(to: try .init(ipAddress: address.host, port: address.port)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try self.clientChannelInitializer(channel)

                    return try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(isOutboundHalfClosureEnabled: true)
                    )
                }
            }
    }
}
