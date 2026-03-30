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

/// A channel handler that closes the connection if the complete request headers
/// are not received within the configured timeout.
///
/// The timeout starts when the channel becomes active and is cancelled when
/// a `.head` part is received.
final class ReadHeaderTimeoutHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPRequestPart

    private let timeout: TimeAmount
    private var scheduledTimeout: Scheduled<Void>?

    init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    func channelActive(context: ChannelHandlerContext) {
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        self.scheduledTimeout = context.eventLoop.scheduleTask(in: self.timeout) {
            boundContext.value.close(promise: nil)
        }
        context.fireChannelActive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        if case .head = part {
            self.scheduledTimeout?.cancel()
            self.scheduledTimeout = nil
        }
        context.fireChannelRead(data)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.scheduledTimeout?.cancel()
        self.scheduledTimeout = nil
    }
}

/// A channel handler that closes the connection if the complete request body
/// is not received within the configured timeout after headers are received.
///
/// The timeout starts when a `.head` part is received and is cancelled when
/// an `.end` part is received. Intermediate `.body` parts do not reset the timer.
final class ReadBodyTimeoutHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPRequestPart

    private let timeout: TimeAmount
    private var scheduledTimeout: Scheduled<Void>?

    init(timeout: TimeAmount) {
        self.timeout = timeout
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        switch part {
        case .head:
            let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            self.scheduledTimeout = context.eventLoop.scheduleTask(in: self.timeout) {
                boundContext.value.close(promise: nil)
            }
        case .end:
            self.scheduledTimeout?.cancel()
            self.scheduledTimeout = nil
        case .body:
            break
        }
        context.fireChannelRead(data)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.scheduledTimeout?.cancel()
        self.scheduledTimeout = nil
    }
}

/// A channel handler that closes the connection when an idle state event is
/// received from an upstream `IdleStateHandler`.
final class ConnectionIdleHandler: ChannelInboundHandler {
    typealias InboundIn = NIOAny

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            context.close(promise: nil)
        } else {
            context.fireUserInboundEventTriggered(event)
        }
    }
}
