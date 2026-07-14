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

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// An active HTTP server connection.
    ///
    /// A `Connection` is owned by exactly one ``NIOHTTPServerConnectionHandler/handleConnection(connection:context:)``
    /// invocation. The handler typically passes it to ``handleRequests(handler:)``,
    /// which runs the request loop until the peer closes the connection, the
    /// server shuts down, or an error occurs.
    ///
    /// A handler that decides to terminate before any request can simply
    /// return without calling ``handleRequests(handler:)``: the `Connection`
    /// is dropped on scope exit and the underlying channel is torn down
    /// cleanly by the server.
    ///
    /// Connection-scoped data is exposed on the accompanying
    /// ``ConnectionContext`` passed alongside the connection to the handler.
    public struct Connection: ~Copyable, Sendable {
        /// Per-protocol state. HTTP/1.1 carries the request-channel's already-running
        /// inbound stream and outbound writer (the dispatcher owns the channel and
        /// drives `executeThenClose`, so the writer is finished cleanly even if the
        /// connection handler returns without calling ``handleRequests(handler:)``).
        /// HTTP/2 carries the connection channel and stream multiplexer.
        enum HTTPProtocol: Sendable {
            case http1_1(
                inbound: NIOAsyncChannelInboundStream<HTTPRequestPart>,
                outbound: NIOAsyncChannelOutboundWriter<HTTPResponsePart>
            )
            case http2(
                connectionChannel: any Channel,
                multiplexer: NIOHTTP2Handler.AsyncStreamMultiplexer<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>>
            )
        }

        let server: NIOHTTPServer
        let context: ConnectionContext
        let httpProtocol: HTTPProtocol

        init(server: NIOHTTPServer, context: ConnectionContext, httpProtocol: HTTPProtocol) {
            self.server = server
            self.context = context
            self.httpProtocol = httpProtocol
        }

        /// Run the request loop on this connection until it terminates.
        ///
        /// Each request received on this connection is dispatched to `handler`. The
        /// loop returns when the peer closes the connection, the server shuts down,
        /// or an error occurs.
        public consuming func handleRequests<Handler: HTTPServerRequestHandler>(
            handler: Handler
        ) async
        where
            Handler.RequestContext == NIOHTTPServer.RequestContext,
            Handler.Reader == NIOHTTPServer.Reader,
            Handler.ResponseSender == NIOHTTPServer.ResponseSender
        {
            let server = self.server
            let context = self.context
            switch self.httpProtocol {
            case .http1_1(let inbound, let outbound):
                await server.handleHTTP1RequestLoop(
                    inbound: inbound,
                    outbound: outbound,
                    handler: handler,
                    context: context
                )
            case .http2(let connectionChannel, let multiplexer):
                await server.handleHTTP2Connection(
                    connectionChannel: connectionChannel,
                    multiplexer: multiplexer,
                    handler: handler,
                    context: context
                )
            }
        }

        /// Convenience overload accepting a closure instead of a
        /// ``HTTPServerRequestHandler`` conformance.
        ///
        /// ```swift
        /// try await server.serve { connection, context in
        ///     try await connection.handleRequests { request, requestContext, reader, responseSender in
        ///         var body = UniqueArray<UInt8>(copying: "Hello, World!".utf8)
        ///         try await responseSender.sendAndFinish(.init(status: .ok), buffer: &body)
        ///     }
        /// }
        /// ```
        public consuming func handleRequests(
            handler:
                @Sendable @escaping (
                    _ request: HTTPRequest,
                    _ requestContext: consuming NIOHTTPServer.RequestContext,
                    _ reader: consuming sending NIOHTTPServer.Reader,
                    _ responseSender: consuming sending NIOHTTPServer.ResponseSender
                ) async throws -> Void
        ) async {
            await self.handleRequests(
                handler: HTTPServerClosureRequestHandler<
                    NIOHTTPServer.RequestContext,
                    NIOHTTPServer.Reader,
                    NIOHTTPServer.ResponseSender
                >(handler: handler)
            )
        }
    }
}
