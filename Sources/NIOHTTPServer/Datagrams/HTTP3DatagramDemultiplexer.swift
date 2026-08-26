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

#if HTTP3 && UnstableHTTPDatagrams

import NIOCore
import NIOHTTP3
import NIOQUICHelpers

/// Routes inbound HTTP/3 datagrams to registered ``HTTP3DatagramStream`` instances.
@available(anyAppleOS 26.0, *)
final class HTTP3DatagramDemultiplexer: ChannelInboundHandler {
    typealias InboundIn = HTTP3Datagram

    /// The event loop of the connection channel.
    private let eventLoop: any EventLoop

    /// The registered ``HTTP3DatagramStream`` instance for each open request stream.
    private var datagramStreams: [QUICStreamID: HTTP3UnreliableDatagramStream] = [:]

    init(eventLoop: any EventLoop) {
        self.eventLoop = eventLoop
    }

    /// Starts routing datagrams received for `datagramStream.streamID` to the provided `datagramStream`.
    ///
    /// - Precondition: Must only be called on the connection channel's event loop.
    func register(datagramStream: HTTP3UnreliableDatagramStream) {
        self.eventLoop.preconditionInEventLoop()
        self.datagramStreams[datagramStream.streamID] = datagramStream
    }

    /// Stops routing datagrams to `streamID`.
    ///
    /// - Precondition: Must only be called on the connection channel's event loop.
    func deregister(streamID: QUICStreamID) {
        self.eventLoop.preconditionInEventLoop()
        self.datagramStreams.removeValue(forKey: streamID)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let datagram = self.unwrapInboundIn(data)
        self.datagramStreams[datagram.streamID]?.receive(datagram.payload)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        for datagramStream in self.datagramStreams.values {
            datagramStream.finish()
        }
        self.datagramStreams.removeAll()
    }
}

#endif  // HTTP3 && UnstableHTTPDatagrams
