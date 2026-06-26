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

/// A channel handler that closes an HTTP/1.1 connection after a period in which no request is in
/// flight.
///
/// The timer runs only between requests: it is scheduled when the channel becomes active and
/// after each response `.end` is written. It is cancelled when an inbound request `.head` is
/// observed. While a request is being processed, request-level timeouts (see
/// ``RequestTimeoutHandler``) are responsible for protecting the server.
///
/// This handler is used on the per-connection channel for HTTP/1.1 only. For HTTP/2, idle
/// behaviour is delegated to `NIOHTTP2ServerConnectionManagementHandler`'s `maxIdleTime`, which
/// already understands stream lifecycle.
final class ConnectionIdleTimeoutHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPRequestPart
    typealias InboundOut = HTTPRequestPart
    typealias OutboundIn = HTTPResponsePart
    typealias OutboundOut = HTTPResponsePart

    private let timeout: TimeAmount
    private var scheduledTimeout: Scheduled<Void>?

    init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // If the handler is added to a channel that is already active, `channelActive` won't be
        // called for it (e.g. on the secure HTTP/1.1 path, where the timeout handlers are installed
        // after ALPN negotiation completes), so start the idle timer here instead.
        if context.channel.isActive {
            self.scheduleTimeout(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        // Connection just opened, no request yet — start the idle timer.
        self.scheduleTimeout(context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        if case .head = part {
            // A request just started; pause idle until the response is fully written.
            self.scheduledTimeout?.cancel()
            self.scheduledTimeout = nil
        }
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let part = self.unwrapOutboundIn(data)
        context.write(data, promise: promise)
        if case .end = part {
            // The response is complete; the connection is now between requests, so re-arm idle.
            self.scheduleTimeout(context: context)
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.scheduledTimeout?.cancel()
        self.scheduledTimeout = nil
    }

    private func scheduleTimeout(context: ChannelHandlerContext) {
        self.scheduledTimeout?.cancel()
        self.scheduledTimeout = context.eventLoop.assumeIsolated().scheduleTask(in: self.timeout) {
            context.close(promise: nil)
        }
    }
}

/// A channel handler that enforces timeouts on receiving request headers and body.
///
/// State machine:
/// - On channel active, a header timeout is scheduled (if configured).
/// - When `.head` is received, the header timeout is cancelled and a body timeout is scheduled
///   (if configured).
/// - When `.end` is received, the body timeout is cancelled and the header timeout is rescheduled
///   so that the next request on a keep-alive connection is also protected. (For HTTP/2 streams
///   this is a no-op in practice: each stream sees only one request and is closed shortly after
///   `.end`.)
///
/// If either timeout fires, the connection is closed.
final class RequestTimeoutHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPRequestPart

    private let readHeaderTimeout: TimeAmount?
    private let readBodyTimeout: TimeAmount?
    private var scheduledTimeout: Scheduled<Void>?

    init(readHeaderTimeout: TimeAmount?, readBodyTimeout: TimeAmount?) {
        self.readHeaderTimeout = readHeaderTimeout
        self.readBodyTimeout = readBodyTimeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // If the handler is added to a channel that is already active, `channelActive` won't be
        // called for it (e.g. on the secure HTTP/1.1 path, where the timeout handlers are installed
        // after ALPN negotiation completes), so start the header timeout here instead.
        if context.channel.isActive {
            self.scheduleHeaderTimeoutIfNeeded(context: context)
        }
    }

    func channelActive(context: ChannelHandlerContext) {
        self.scheduleHeaderTimeoutIfNeeded(context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head:
            self.scheduledTimeout?.cancel()
            self.scheduledTimeout = nil
            if let readBodyTimeout {
                self.scheduleTimeout(readBodyTimeout, context: context)
            }
        case .body:
            break
        case .end:
            self.scheduledTimeout?.cancel()
            self.scheduledTimeout = nil
            // Re-arm the header timer so the next request on this connection is also protected.
            if let readHeaderTimeout {
                self.scheduleTimeout(readHeaderTimeout, context: context)
            }
        }
        context.fireChannelRead(data)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.scheduledTimeout?.cancel()
        self.scheduledTimeout = nil
    }

    private func scheduleHeaderTimeoutIfNeeded(context: ChannelHandlerContext) {
        if let readHeaderTimeout {
            self.scheduleTimeout(readHeaderTimeout, context: context)
        }
    }

    private func scheduleTimeout(_ timeout: TimeAmount, context: ChannelHandlerContext) {
        self.scheduledTimeout = context.eventLoop.assumeIsolated().scheduleTask(in: timeout) {
            context.close(promise: nil)
        }
    }
}
