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

#if UnstableWebTransport

import NIOCore
import NIOHTTP3
import NIOQUIC
import NIOQUICHelpers

/// Wraps a stream channel in a `NIOAsyncChannel` and hands it to the router once the session ID has been read.
final class WebTransportIncomingUnidirectionalStreamsChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    let multiplexer: WebTransportIncomingStreamsMultiplexer
    private var didReadSessionID = false

    init(multiplexer: WebTransportIncomingStreamsMultiplexer) {
        self.multiplexer = multiplexer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !self.didReadSessionID else {
            context.fireChannelRead(data)
            return
        }
        var buffer = self.unwrapInboundIn(data)
        guard let rawSessionID = buffer.readEncodedInteger(as: UInt64.self, strategy: .quic) else {
            context.fireChannelRead(data)
            return
        }
        self.didReadSessionID = true

        let sessionID = QUICStreamID(rawValue: rawSessionID)

        let asyncChannel: NIOAsyncChannel<ByteBuffer, Never>
        do {
            asyncChannel = try NIOAsyncChannel<ByteBuffer, Never>(
                wrappingChannelSynchronously: context.channel,
                configuration: .init(isOutboundHalfClosureEnabled: true)
            )
        } catch {
            context.fireErrorCaught(error)
            return
        }
        self.multiplexer.yieldUnidirectionalStream(asyncChannel, sessionID: sessionID)

        if buffer.readableBytes > 0 {
            context.fireChannelRead(self.wrapInboundOut(buffer))
        }
    }
}

/// Decides whether a client-initiated bidirectional stream is a WebTransport stream or an HTTP/3 request stream.
final class WebTransportIncomingBidirectionalStreamsChannelHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer

    let multiplexer: WebTransportIncomingStreamsMultiplexer
    private var didReadSessionID = false

    init(multiplexer: WebTransportIncomingStreamsMultiplexer) {
        self.multiplexer = multiplexer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !self.didReadSessionID else {
            context.fireChannelRead(data)
            return
        }
        var buffer = self.unwrapInboundIn(data)
        guard
            let signalValue = buffer.readEncodedInteger(as: UInt64.self, strategy: .quic),
            signalValue == 0x41,
            let sessionID = buffer.readEncodedInteger(as: UInt64.self, strategy: .quic)
        else {
            guard #available(anyAppleOS 27, *) else { fatalError("WebTransport requires anyAppleOS 27 or later") }
            context.channel.parent!.pipeline.handler(type: HTTP3ConnectionHandler<NIOQUIC.QUICStreamCreator>.self)
                .assumeIsolated()
                .whenComplete { result in
                    switch result {
                    case .success(let http3Handler):
                        _ = http3Handler.inboundStreamReceived(context.channel)
                    case .failure(let error):
                        context.fireErrorCaught(error)
                        return
                    }
                }

            context.fireChannelRead(data)
            return
        }
        self.didReadSessionID = true

        let asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            asyncChannel = try NIOAsyncChannel<ByteBuffer, ByteBuffer>(
                wrappingChannelSynchronously: context.channel,
                configuration: .init(isOutboundHalfClosureEnabled: true)
            )
        } catch {
            context.fireErrorCaught(error)
            return
        }
        self.multiplexer.yieldBidirectionalStream(asyncChannel, sessionID: QUICStreamID(rawValue: sessionID))

        if buffer.readableBytes > 0 {
            context.fireChannelRead(self.wrapInboundOut(buffer))
        }
    }
}

#endif
