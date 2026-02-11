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

import NIOCore
import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP2

/// A testing utility that wraps the result of ALPN negotiation for HTTP/1.1 or HTTP/2 client connections.
///
/// - If HTTP/1.1 is negotiated, this type vends the underlying client connection channel.
/// - If HTTP/2 is negotiated, this type vends a ``HTTP2StreamManager``. In tests, you can then call the
///   ``HTTP2StreamManager/openStream()`` method, which will create a stream channel, set it up with a channel handler,
///   and return a ``NIOAsyncChannel`` from which you can send/observe requests/responses in terms of HTTP types.
enum NegotiatedClientConnection {
    case http1(NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>)
    case http2(HTTP2StreamManager)

    init(
        negotiationResult: NIONegotiatedHTTPVersion<
            NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>, NIOHTTP2Handler.AsyncStreamMultiplexer<Channel>
        >
    ) async throws {
        switch negotiationResult {
        case .http1_1(let http1AsyncChannel):
            self = .http1(http1AsyncChannel)

        case .http2(let http2StreamMultiplexer):
            self = .http2(.init(http2StreamMultiplexer: http2StreamMultiplexer))
        }
    }

    /// Provides utilities for managing HTTP/2 streams.
    struct HTTP2StreamManager {
        let http2StreamMultiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<Channel>

        /// A wrapper over `NIOHTTP2Handler/AsyncStreamMultiplexer/openStream(_:)` that first initializes the stream
        /// channel with the `HTTP2FramePayloadToHTTPClientCodec` channel handler, and wraps it in a `NIOAsyncChannel`
        /// (with outbound half closure enabled).
        func openStream() async throws -> NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart> {
            try await self.http2StreamMultiplexer.openStream { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTPClientCodec())
                    return try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                        wrappingChannelSynchronously: channel,
                        configuration: .init(isOutboundHalfClosureEnabled: true)
                    )
                }
            }
        }
    }
}
