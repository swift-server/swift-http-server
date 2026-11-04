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

#if UnstableWebTransport

public import NIOCore
@_spi(HTTP3AsyncInterface) import NIOHTTP3
import NIOQUIC
import NIOQUICHelpers

@available(anyAppleOS 27.0, *)
extension NIOHTTPServer.Connection {
    /// If the connection is using HTTP/3, returns the associated QUIC stream creator. Otherwise, returns `nil`.
    var quicStreamCreator: NIOQUIC.QUICStreamCreator? {
        get async throws {
            guard case .http3(let connection) = self.httpProtocol else { return nil }
            return try await connection.streamCreator.get()
        }
    }

    /// If the connection is using HTTP/3,
    /// returns a ``NIOHTTPServer/Connection/WebTransportStreamCreator`` built with the connection's QUIC stream creator.
    /// Otherwise, returns `nil`.
    public var webTransportStreamCreator: WebTransportStreamCreator? {
        get async throws {
            guard let quicStreamCreator = try await self.quicStreamCreator else { return nil }
            return WebTransportStreamCreator(quicStreamCreator: quicStreamCreator)
        }
    }

    /// Use this to open WebTransport streams on the HTTP/3 connection.
    public struct WebTransportStreamCreator: Sendable {
        let quicStreamCreator: NIOQUIC.QUICStreamCreator

        /// Opens a unidirectional WebTransport stream,
        /// executes the provided operation with the outbound writer,
        /// and closes the stream afterwards.
        ///
        /// - Parameters:
        ///   - requestContext: The request context of the CONNECT stream. Used to get the CONNECT stream's QUIC stream ID (a.k.a. the Session ID).
        ///   - operation: A closure that takes the outbound writer and performs the desired operations on the stream.
        ///
        /// - Returns: The result of the `operation` closure.
        public func withUnidirectionalStream<Value>(
            requestContext: NIOHTTPServer.RequestContext,
            operation: (NIOAsyncChannelOutboundWriter<ByteBuffer>) async throws -> Value
        ) async throws -> Value {
            try await self.quicStreamCreator.createUnidirectionalStream { streamInitializer in
                streamInitializer.channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: streamInitializer.channel,
                        configuration: .init(
                            isOutboundHalfClosureEnabled: true,
                            inboundType: Never.self,
                            outboundType: ByteBuffer.self
                        )
                    )
                }
            }.get().executeThenClose { _, outbound in
                var buffer = ByteBuffer()
                buffer.writeEncodedInteger(0x54, strategy: .quic)
                buffer.writeEncodedInteger(try await requestContext.quicStreamID.rawValue, strategy: .quic)
                try await outbound.write(buffer)
                return try await operation(outbound)
            }
        }

        /// Opens a bidirectional WebTransport stream,
        /// executes the provided operation with the inbound stream and outbound writer,
        /// and closes the stream afterwards.
        ///
        /// - Parameters:
        ///   - requestContext: The request context of the CONNECT stream. Used to get the CONNECT stream's QUIC stream ID (a.k.a. the Session ID).
        ///   - operation: A closure that takes the inbound stream and outbound writer and performs the desired operations on the stream.
        ///
        /// - Returns: The result of the `operation` closure.
        public func withBidirectionalStream<Value>(
            requestContext: NIOHTTPServer.RequestContext,
            operation: (
                NIOAsyncChannelInboundStream<ByteBuffer>,
                NIOAsyncChannelOutboundWriter<ByteBuffer>
            ) async throws -> Value
        ) async throws -> Value {
            try await self.quicStreamCreator.createBidirectionalStream { streamInitializer in
                streamInitializer.channel.eventLoop.makeCompletedFuture {
                    try NIOAsyncChannel(
                        wrappingChannelSynchronously: streamInitializer.channel,
                        configuration: .init(
                            isOutboundHalfClosureEnabled: true,
                            inboundType: ByteBuffer.self,
                            outboundType: ByteBuffer.self
                        )
                    )
                }
            }.get().executeThenClose { inbound, outbound in
                var buffer = ByteBuffer()
                buffer.writeEncodedInteger(0x41, strategy: .quic)
                buffer.writeEncodedInteger(try await requestContext.quicStreamID.rawValue, strategy: .quic)
                try await outbound.write(buffer)
                return try await operation(inbound, outbound)
            }
        }
    }
}

@available(anyAppleOS 27.0, *)
extension NIOHTTPServer.RequestContext {
    /// Returns the QUIC stream ID associated with this request stream.
    ///
    /// This is only available if the connection is using HTTP/3.
    var quicStreamID: NIOQUICHelpers.QUICStreamID {
        get async throws {
            QUICStreamID(rawValue: try await self.channel.getOption(.quicStreamID))
        }
    }
}

#endif
