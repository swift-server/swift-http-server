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

/// This channel handler keeps a connection's ``NIOHTTPServer/ConnectionContext`` current with the events fired into the
/// connection channel's pipeline, and reports them through the context's
/// ``NIOHTTPServer/ConnectionContext/connectionEvents``, which it finishes once the connection closes.
@available(anyAppleOS 27.0, *)
final class ConnectionEventsHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny

    private let connectionContext: NIOHTTPServer.ConnectionContext

    init(connectionContext: NIOHTTPServer.ConnectionContext) {
        self.connectionContext = connectionContext
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        // TODO: Translate the QUIC stack's own events (for example, the peer migrating the connection to a new path, or
        // a new path being validated) into `ConnectionEvent`s, once it fires them into the connection channel.
        if let event = event as? NIOHTTPServer.ConnectionEvent {
            self.connectionContext.apply(event)
        }

        context.fireUserInboundEventTriggered(event)
    }

    func channelInactive(context: ChannelHandlerContext) {
        self.connectionContext.finishConnectionEvents()
        context.fireChannelInactive()
    }
}
