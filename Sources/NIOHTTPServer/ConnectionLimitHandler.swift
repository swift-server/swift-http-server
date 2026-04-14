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

/// A channel handler installed on the server (parent) channel that limits the
/// number of concurrent connections by gating `read()` calls.
///
/// When the number of active connections reaches `maxConnections`, this handler
/// stops forwarding `read()` events, which prevents NIO from calling `accept()`
/// on the listening socket. When a connection closes and count drops below the
/// limit, `read()` is re-triggered to resume accepting.
final class ConnectionLimitHandler: ChannelDuplexHandler {
    typealias InboundIn = Channel
    typealias InboundOut = Channel
    typealias OutboundIn = Channel

    private let maxConnections: Int
    private var activeConnections: Int = 0
    private var pendingRead: Bool = false

    init(maxConnections: Int) {
        self.maxConnections = maxConnections
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let childChannel = self.unwrapInboundIn(data)
        self.activeConnections += 1

        let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
        let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        let eventLoop = context.eventLoop
        childChannel.closeFuture.whenComplete { _ in
            eventLoop.execute {
                let `self` = loopBoundSelf.value
                let context = loopBoundContext.value
                `self`.activeConnections -= 1
                if `self`.pendingRead && `self`.activeConnections <= `self`.maxConnections {
                    `self`.pendingRead = false
                    context.read()
                }
            }
        }

        context.fireChannelRead(data)
    }

    func read(context: ChannelHandlerContext) {
        if self.activeConnections <= self.maxConnections {
            context.read()
        } else {
            self.pendingRead = true
        }
    }
}
