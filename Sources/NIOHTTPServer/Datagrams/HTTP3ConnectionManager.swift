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

#if HTTP3
import Logging
import NIOCore
import NIOHTTP3
import NIOQUICHelpers

/// Routes inbound HTTP/3 datagrams to registered ``HTTP3DatagramStream`` instances.
@available(anyAppleOS 26.0, *)
final class HTTP3ConnectionManager: ChannelInboundHandler {
    typealias InboundIn = HTTP3Datagram

    /// The event loop of the connection channel.
    private let eventLoop: any EventLoop

    private let logger: Logger

    init(eventLoop: any EventLoop, logger: Logger) {
        self.eventLoop = eventLoop
        self.logger = logger
    }

    #if UnstableHTTPDatagrams
    private struct DatagramContext {
        /// The promise for the outcome of datagram negotiation.
        ///
        /// Set to `nil` once the promise is fulfilled.
        private var datagramsNegotiatedPromise: EventLoopPromise<Void>?

        /// The registered ``HTTP3DatagramStream`` instance for each open request stream.
        var datagramStreams: [QUICStreamID: HTTP3UnreliableDatagramStream] = [:]

        init(datagramsNegotiatedPromise: EventLoopPromise<Void>) {
            self.datagramsNegotiatedPromise = datagramsNegotiatedPromise
        }

        mutating func receive(datagram: HTTP3Datagram) {
            self.datagramStreams[datagram.streamID]?.receive(datagram.payload)
        }

        mutating func register(datagramStream: HTTP3UnreliableDatagramStream) {
            self.datagramStreams[datagramStream.streamID] = datagramStream
        }

        mutating func deregister(streamID: QUICStreamID) {
            self.datagramStreams[streamID]?.finish()
            self.datagramStreams.removeValue(forKey: streamID)
        }

        mutating func finish() {
            // The connection is going away, so datagrams will never be negotiated if they haven't been already.
            self.completeNegotiation(datagramsSupported: false)

            for datagramStream in self.datagramStreams.values {
                datagramStream.finish()
            }
            self.datagramStreams.removeAll()
        }

        mutating func receivedSettings(datagramsSupported: Bool) {
            self.completeNegotiation(datagramsSupported: datagramsSupported)
        }

        /// Completes the negotiation promise, if it has not been completed already.
        private mutating func completeNegotiation(datagramsSupported: Bool) {
            guard let promise = self.datagramsNegotiatedPromise else {
                // We fulfilled the promise earlier.
                return
            }
            self.datagramsNegotiatedPromise = nil

            if datagramsSupported {
                promise.succeed()
            } else {
                promise.fail(DatagramsNotSupported())
            }
        }
    }

    struct DatagramsNotSupported: Error {}

    private var datagramContext: DatagramContext?

    init(eventLoop: any EventLoop, logger: Logger, datagramsNegotiatedPromise: EventLoopPromise<Void>?) {
        self.eventLoop = eventLoop
        self.logger = logger

        if let datagramsNegotiatedPromise {
            self.datagramContext = .init(datagramsNegotiatedPromise: datagramsNegotiatedPromise)
        } else {
            self.datagramContext = nil
        }
    }

    /// Starts routing datagrams received for `datagramStream.streamID` to the provided `datagramStream`.
    ///
    /// - Precondition: Must only be called on the connection channel's event loop.
    func register(datagramStream: HTTP3UnreliableDatagramStream) {
        self.eventLoop.preconditionInEventLoop()
        self.datagramContext?.register(datagramStream: datagramStream)
    }

    /// Stops routing datagrams to `streamID`.
    ///
    /// - Precondition: Must only be called on the connection channel's event loop.
    func deregister(streamID: QUICStreamID) {
        self.eventLoop.preconditionInEventLoop()
        self.datagramContext?.deregister(streamID: streamID)
    }
    #endif  // UnstableHTTPDatagrams

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        #if UnstableHTTPDatagrams
        let datagram = self.unwrapInboundIn(data)
        self.datagramContext?.receive(datagram: datagram)
        #endif

        context.fireChannelRead(data)
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as ReceivedSettings:
            #if UnstableHTTPDatagrams
            self.datagramContext?.receivedSettings(datagramsSupported: event.datagramsSupported)
            #endif
            context.fireUserInboundEventTriggered(event)

        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        self.logger.debug("Closing HTTP/3 connection due to connection error", error: error)
        context.close(mode: .all, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        #if UnstableHTTPDatagrams
        self.datagramContext?.finish()
        self.datagramContext = nil
        #endif

        context.fireChannelInactive()
    }
}

#endif  // HTTP3 && UnstableHTTPDatagrams
