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
import NIOHTTPTypes

/// A NIO channel handler that ensures HTTP/1.1 keep-alive semantics are honored when
/// the server starts writing a response before the request body has been fully read.
///
/// The handler buffers final response parts (head + any body fragments + end) when
/// they are written before the request `.end` has been received. The buffer is
/// released at the next deadline:
///
/// - **`channelReadComplete`**: the end of an inbound read cycle.
/// - **`flush`**: an upstream writer (e.g. `NIOAsyncChannelOutboundWriter`) forced a
///   flush.
///
/// At each deadline, if request `.end` has arrived, the buffer is flushed as-is and
/// the connection is reusable. If request `.end` has *not* arrived, the head is
/// amended with `Connection: close`, the buffer is flushed, and the connection is
/// closed once response `.end` is written. This protects against clients that keep
/// uploading request body bytes after the response has completed (which would
/// otherwise force the server to drain unbounded data) and gives the client an
/// explicit signal not to pipeline another request on the connection.
///
/// Informational (1xx) responses pass through unchanged and do not affect buffering
/// state.
@available(anyAppleOS 26.0, *)
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
        /// No final response part has been written yet for the current request.
        /// Informational (1xx) responses may have been passed through.
        case notStarted
        /// The final response head was written before request `.end` arrived. The
        /// head — and any additional response parts (body fragments, `.end`) the
        /// handler wrote in the same window — are buffered until the next deadline
        /// (`channelReadComplete` or `flush`), at which point we decide whether to
        /// keep the connection alive or amend the head with `Connection: close`.
        case buffering(head: BufferedWrite, additional: [BufferedWrite])
        /// The head has been flushed; remaining parts stream directly. If
        /// `closeAfterResponseEnd` is true, the head carried `Connection: close`
        /// and we close once response `.end` is written.
        case streaming
    }

    /// `true` when the request `.end` has been received on the inbound side, or no
    /// request is currently in flight. `false` between receiving a request `.head`
    /// and its `.end`.
    private var requestEndReceived: Bool = true

    /// `true` if we've committed to closing the connection after this response's
    /// `.end` is written. Set when the buffer is flushed while request `.end` has
    /// not yet arrived, and when a request is aborted (so a still-buffered head
    /// picks up `Connection: close` on its way out). Cleared when a new request
    /// begins.
    private var closeAfterResponseEnd: Bool = false

    private var finalResponseState: FinalResponseState = .notStarted

    /// Asks the handler to abandon the current response and close the connection.
    ///
    /// Fired as a user outbound event by the server when a request handler throws. HTTP/1.1 has no per-stream reset, so
    /// aborting means closing the connection — and how much of the response can still be salvaged depends on how far it
    /// has progressed, which only this handler knows.
    struct RequestAborted: Sendable {
        /// The response to send when the handler had not started a response yet.
        ///
        /// It is amended with `Connection: close` before being written. If a response has already been written this is
        /// ignored.
        var responseIfNotStarted: HTTPResponse
    }

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        guard let abort = event as? RequestAborted else {
            context.triggerUserOutboundEvent(event, promise: promise)
            return
        }

        self.abortResponse(context: context, responseIfNotStarted: abort.responseIfNotStarted)
        promise?.succeed()
    }

    /// Abandons the in-flight response and closes the connection.
    private func abortResponse(context: ChannelHandlerContext, responseIfNotStarted: HTTPResponse) {
        switch self.finalResponseState {
        case .notStarted:
            // Nothing has been written for this request, so a complete response can still be sent.
            var response = responseIfNotStarted
            response.headerFields[.connection] = "close"
            self.closeAfterResponseEnd = true
            self.finalResponseState = .streaming

            context.write(self.wrapOutboundOut(.head(response)), promise: nil)
            context.write(self.wrapOutboundOut(.end(nil)), promise: nil)

        case .buffering:
            // The head has not reached the wire yet, so it can still be amended with `Connection: close`.
            //
            // No response `.end` is synthesized: the handler abandoned this response, and for a chunked body `.end`
            // writes the terminating chunk, which would tell the client the truncated response was complete. Leaving it
            // out means the client sees an incomplete message, which is the signal we want. For a `Content-Length` body
            // `.end` writes no bytes at all, so omitting it changes nothing.
            self.closeAfterResponseEnd = true
            self.flushBuffer(context: context)

        case .streaming:
            // The head is already on the wire and cannot be recalled. The response is abandoned, so the client observes
            // it as truncated — again without a fabricated `.end`.
            ()
        }

        context.flush()
        context.close(mode: .output, promise: nil)
    }

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
        }
        context.fireChannelRead(data)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        // End of an inbound read cycle: this is the deadline for deciding whether
        // the buffered response can be sent as-is (keep-alive) or must include
        // `Connection: close`. If request `.end` arrived during the cycle the head
        // is flushed unchanged; otherwise we amend the head and close after
        // response `.end`.
        if case .buffering = self.finalResponseState {
            self.flushBuffer(context: context)
        }
        context.fireChannelReadComplete()
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
                // Start buffering with the head. Additional parts (body, end) the
                // handler may write before the next deadline are appended below.
                self.finalResponseState = .buffering(
                    head: BufferedWrite(part: part, promise: promise),
                    additional: []
                )
            }
        case .buffering(let head, var additional):
            additional.append(BufferedWrite(part: part, promise: promise))
            self.finalResponseState = .buffering(head: head, additional: additional)
        case .streaming:
            context.write(data, promise: promise)
            if case .end = part, self.closeAfterResponseEnd {
                // The head we flushed earlier carried `Connection: close`; close
                // the connection now that the response is complete.
                context.flush()
                context.close(mode: .output, promise: nil)
            }
        }
    }

    func flush(context: ChannelHandlerContext) {
        // An upstream writer forced a flush. Same deadline as `channelReadComplete`:
        // release any buffered parts, with `Connection: close` if request `.end`
        // hasn't arrived.
        if case .buffering = self.finalResponseState {
            self.flushBuffer(context: context)
        }
        context.flush()
    }

    /// Releases buffered response parts to the pipeline. If request `.end` has not
    /// yet arrived, or we have already committed to closing, amend the head with
    /// `Connection: close` and arrange to close the connection once response `.end`
    /// is written.
    private func flushBuffer(context: ChannelHandlerContext) {
        guard case .buffering(var head, let additional) = self.finalResponseState else { return }

        if self.closeAfterResponseEnd || !self.requestEndReceived {
            // Amend the head with `Connection: close` before flushing.
            if case .head(var response) = head.part {
                response.headerFields[.connection] = "close"
                head.part = .head(response)
            }
            self.closeAfterResponseEnd = true
        }

        self.finalResponseState = .streaming

        context.write(self.wrapOutboundOut(head.part), promise: head.promise)
        var sawEnd = false
        for write in additional {
            context.write(self.wrapOutboundOut(write.part), promise: write.promise)
            if case .end = write.part {
                sawEnd = true
            }
        }
        context.flush()

        if sawEnd && self.closeAfterResponseEnd {
            // The response was fully buffered (head + ... + end) and we have to
            // close. Close now (the flush above ensured the writes reached the
            // wire).
            context.close(mode: .output, promise: nil)
        }
    }
}
