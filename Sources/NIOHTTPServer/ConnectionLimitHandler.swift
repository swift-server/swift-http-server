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

import Logging
import NIOCore

/// A channel handler installed on the server (parent) channel that imposes limits on the following:
/// 1. `maxConnections`: How many active connections there can be;
/// 2. `newConnectionRateLimit`: How quickly new connections can be accepted;
/// 3. `maxConcurrentTLSHandshakes`: How many connections can be in the TLS handshake stage.
///
/// - When the `maxConnections` or `newConnectionRateLimit` limit is reached, this handler stops forwarding `read()`
///   calls to prevent NIO from calling `accept()` on the listening socket and accepting more connection.
///
///   Note that a single `read()` call can potentially result in multiple connections being accepted (depending on the
///   `MaxMessagesPerReadOption` channel option, which defaults to 4). As such, we may sometimes marginally exceed these
///   limits, but there is logic in place to hold further `read()` calls until we fall below the threshold again.
///
/// - When the `maxConcurrentTLSHandshakes` limit is reached, new connections are closed as soon as they are accepted.
///   An admitted connection's handshake slot is freed when it fires ``TLSHandshakeFinished`` on the server channel.
final class ConnectionLimitHandler: ChannelDuplexHandler {
    typealias InboundIn = Channel
    typealias InboundOut = Channel
    typealias OutboundIn = Channel

    private var stateMachine: ConnectionLimitStateMachine
    private let logger: Logger

    /// The callback which retries the `read()` call that the rate limiter previously instructed us to hold back.
    ///
    /// `nil` when no callback is scheduled.
    private var nextTokenCallback: NIOScheduledCallback?

    /// - Parameters:
    ///   - maxConnections: How many accepted connections can be open at once. `nil` means unlimited.
    ///   - newConnectionRateLimit: How many new connections can be accepted per second. `nil` means unlimited.
    ///   - maxConcurrentTLSHandshakes: How many connections can be in the TLS handshake stage at once. `nil` means unlimited.
    ///   - logger: The logger to use.
    init(
        maxConnections: Int? = nil,
        newConnectionRateLimit: Int? = nil,
        maxConcurrentTLSHandshakes: Int? = nil,
        logger: Logger
    ) {
        self.stateMachine = ConnectionLimitStateMachine(
            maxConnections: maxConnections,
            newConnectionRateLimit: newConnectionRateLimit,
            maxConcurrentTLSHandshakes: maxConcurrentTLSHandshakes
        )
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let childChannel = self.unwrapInboundIn(data)

        switch self.stateMachine.connectionAccepted(now: context.eventLoop.now) {
        case .admit:
            let loopBoundSelf = NIOLoopBound(self, eventLoop: context.eventLoop)
            let loopBoundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
            let eventLoop = context.eventLoop
            childChannel.closeFuture.whenComplete { _ in
                eventLoop.execute {
                    let `self` = loopBoundSelf.value
                    let context = loopBoundContext.value

                    let readAction = `self`.stateMachine.connectionClosed(now: eventLoop.now)
                    `self`.handleReadAction(readAction, context: context)
                }
            }

            context.fireChannelRead(data)

        case .reject(let reason):
            self.logger.trace(
                "Closing accepted connection: \(reason)",
                metadata: [LoggingKeys.remoteAddress: "\(childChannel.remoteAddress?.description ?? "unknown")"]
            )
            childChannel.close(promise: nil)
            return
        }
    }

    /// Fired on the server channel's pipeline once an admitted connection's TLS handshake has finished, successfully or
    /// not, to free the connection's handshake slot.
    ///
    /// Must be fired exactly once for each connection admitted when `maxConcurrentTLSHandshakes` is set.
    struct TLSHandshakeFinished: Sendable {}

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is TLSHandshakeFinished:
            self.stateMachine.handshakeFinished()

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func read(context: ChannelHandlerContext) {
        let readAction = self.stateMachine.read(now: context.eventLoop.now)
        self.handleReadAction(readAction, context: context)
    }

    private func handleReadAction(
        _ action: consuming ConnectionLimitStateMachine.ReadAction,
        context: ChannelHandlerContext
    ) {
        switch consume action {
        case .forwardRead:
            context.read()

        case .waitForNextToken(let delay):
            precondition(self.nextTokenCallback == nil, "The next-token callback is already scheduled")

            do {
                self.nextTokenCallback = try context.eventLoop.assumeIsolated().scheduleCallback(
                    in: delay,
                    handler: NextTokenCallbackHandler(connectionLimitHandler: self, context: context)
                )
            } catch {
                // We should only reach here if the event loop is shutting down.
                self.logger.debug("Scheduling the next-token callback failed", error: error)
            }

        case .doNothing:
            ()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        switch self.stateMachine.handlerRemoved() {
        case .cancelNextTokenCallback:
            self.nextTokenCallback?.cancel()
            self.nextTokenCallback = nil

        case .doNothing:
            ()
        }
    }

    fileprivate func nextTokenDue(context: ChannelHandlerContext) {
        self.nextTokenCallback = nil
        let readAction = self.stateMachine.nextTokenDue(now: context.eventLoop.now)
        self.handleReadAction(readAction, context: context)
    }
}

/// Calls ``ConnectionLimitHandler/nextTokenDue(context:)`` when the next-token callback is due.
private struct NextTokenCallbackHandler: NIOScheduledCallbackHandler {
    let connectionLimitHandler: ConnectionLimitHandler
    let context: ChannelHandlerContext

    func handleScheduledCallback(eventLoop: some EventLoop) {
        self.connectionLimitHandler.nextTokenDue(context: self.context)
    }
}
