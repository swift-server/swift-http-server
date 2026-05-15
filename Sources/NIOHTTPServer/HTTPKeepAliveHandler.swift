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

import HTTPTypes
import NIOCore
import NIOHTTPTypes

/// A NIO channel handler that ensures HTTP/1.1 keep-alive semantics are honored when
/// the server starts writing a response before the request body has been fully read.
///
/// The handler buffers only the outbound response head whenever it is written before
/// the request `.end` has been received. The buffered head is released in one of three
/// ways:
///
/// - **Request `.end` arrives before any response part is written**: the head is
///   flushed as-is and the response streams normally. The connection can be reused.
/// - **A response body part is written before request `.end` arrives**: the buffered
///   head is amended with `Connection: close`, then flushed; subsequent parts stream
///   directly; once response `.end` is written, the connection is closed.
/// - **Response `.end` is written while the head is still buffered (no body written)**:
///   the head is amended with `Connection: close`, flushed, followed by `.end`, then
///   the connection is closed.
///
/// Any time the head is flushed *because* the handler started producing the response
/// before the request was fully read, the client receives `Connection: close` and the
/// server itself closes the connection after writing response `.end`. This protects
/// against clients that keep uploading request body bytes after the response has
/// completed (which would otherwise force the server to drain unbounded data) and
/// gives the client an explicit signal not to pipeline another request on the
/// connection.
///
/// Informational (1xx) responses pass through unchanged and do not affect buffering
/// state.
@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
final class HTTPKeepAliveHandler: ChannelDuplexHandler {
    typealias InboundIn = HTTPRequestPart
    typealias InboundOut = HTTPRequestPart
    typealias OutboundIn = HTTPResponsePart
    typealias OutboundOut = HTTPResponsePart

    private struct BufferedWrite {
        var part: HTTPResponsePart
        var promise: EventLoopPromise<Void>?
    }

    private enum FinalResponseState {
        /// No final response has been written yet for the current request. Informational
        /// (1xx) responses may have been passed through.
        case notStarted
        /// The final response head was written before request `.end` arrived. The head
        /// is buffered until either request `.end` arrives (flush as-is, transition to
        /// streaming, keep-alive), or a response body or `.end` is written (flush head
        /// with `Connection: close`, transition to streaming, close after response
        /// `.end`).
        case bufferingHead(BufferedWrite)
        /// The response is being streamed directly. If `closeAfterResponseEnd` is
        /// true, the connection will be closed once response `.end` is written.
        case streaming
    }

    /// `true` when the request `.end` has been received on the inbound side, or no
    /// request is currently in flight. `false` between receiving a request `.head`
    /// and its `.end`.
    private var requestEndReceived: Bool = true

    /// `true` if we've committed to closing the connection after this response's
    /// `.end` is written. Set when the buffered head is flushed because a response
    /// body or `.end` was written before request `.end` arrived. Cleared when a new
    /// request begins.
    private var closeAfterResponseEnd: Bool = false

    private var finalResponseState: FinalResponseState = .notStarted

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head:
            // Begin a new request. (Any previous request's response must have
            // completed already since HTTPServerPipelineHandler enforces ordering.)
            self.requestEndReceived = false
            self.closeAfterResponseEnd = false
            self.finalResponseState = .notStarted
        case .body:
            break
        case .end:
            self.requestEndReceived = true
            // If we've been buffering the response head, flush it now: we can keep the
            // connection alive.
            if case .bufferingHead(let buffered) = self.finalResponseState {
                self.finalResponseState = .streaming
                context.write(self.wrapOutboundOut(buffered.part), promise: buffered.promise)
                context.flush()
            }
        }
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = self.unwrapOutboundIn(data)
        switch self.finalResponseState {
        case .notStarted:
            // Informational (1xx) responses pass through without affecting state: they
            // don't conclude the response, so we remain in `.notStarted` until the
            // final response head is written.
            if case .head(let response) = part, response.status.kind == .informational {
                context.write(data, promise: promise)
                return
            }
            if self.requestEndReceived {
                // Request fully read; stream the response directly.
                self.finalResponseState = .streaming
                context.write(data, promise: promise)
            } else {
                // Buffer just the head until we know whether a body will follow.
                self.finalResponseState = .bufferingHead(BufferedWrite(part: part, promise: promise))
            }
        case .bufferingHead(let buffered):
            // Reaching this case means the handler is producing more of the response
            // before request `.end` arrived (otherwise `channelRead(.end)` would have
            // flushed the buffer and transitioned us to `.streaming`). Amend the head
            // with `Connection: close` so the client knows not to reuse the
            // connection, and remember to close after writing response `.end`.
            var headPart = buffered.part
            if case .head(var response) = headPart {
                response.headerFields[.connection] = "close"
                headPart = .head(response)
            }
            self.closeAfterResponseEnd = true
            self.finalResponseState = .streaming

            switch part {
            case .end:
                // Response is just head + end (no body). Flush head + end and close.
                context.write(self.wrapOutboundOut(headPart), promise: buffered.promise)
                context.write(data, promise: promise)
                context.flush()
                context.close(mode: .all, promise: nil)
            case .body:
                // Flush head + body and continue streaming. We'll close once response
                // `.end` is written.
                context.write(self.wrapOutboundOut(headPart), promise: buffered.promise)
                context.write(data, promise: promise)
                context.flush()
            case .head:
                preconditionFailure(
                    "HTTPKeepAliveHandler received a second response head while the previous head was still buffered. "
                    + "A handler must only write one final response head per request."
                )
            }
        case .streaming:
            context.write(data, promise: promise)
            if case .end = part, self.closeAfterResponseEnd {
                // The head we flushed earlier carried `Connection: close`; close
                // the connection now that the response is complete.
                context.flush()
                context.close(mode: .all, promise: nil)
            }
        }
    }
}
