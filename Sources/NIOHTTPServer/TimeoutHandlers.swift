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

/// A channel handler that closes the connection after a period of inactivity.
///
/// The timeout is scheduled when the channel becomes active and is rescheduled
/// whenever a read or write occurs. If the timeout fires without any activity,
/// the connection is closed.
///
/// This replaces the combination of NIO's `IdleStateHandler` and a separate
/// handler to react to idle events.
final class ConnectionIdleTimeoutHandler: ChannelDuplexHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private let timeout: TimeAmount
    private var scheduledTimeout: Scheduled<Void>?

    init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    func channelActive(context: ChannelHandlerContext) {
        self.scheduleTimeout(context: context)
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        self.scheduleTimeout(context: context)
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        self.scheduleTimeout(context: context)
        context.write(data, promise: promise)
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
/// This combines header and body read timeouts into a single handler with a
/// state machine:
/// - On channel active, a header timeout is scheduled (if configured).
/// - When `.head` is received, the header timeout is cancelled and a body
///   timeout is scheduled (if configured).
/// - When `.end` is received, the body timeout is cancelled.
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

    func channelActive(context: ChannelHandlerContext) {
        if let readHeaderTimeout {
            self.scheduleTimeout(readHeaderTimeout, context: context)
        }
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
        }
        context.fireChannelRead(data)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.scheduledTimeout?.cancel()
        self.scheduledTimeout = nil
    }

    private func scheduleTimeout(_ timeout: TimeAmount, context: ChannelHandlerContext) {
        self.scheduledTimeout = context.eventLoop.assumeIsolated().scheduleTask(in: timeout) {
            context.close(promise: nil)
        }
    }
}
