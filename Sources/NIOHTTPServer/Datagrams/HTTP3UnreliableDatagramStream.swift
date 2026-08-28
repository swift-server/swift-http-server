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

@available(anyAppleOS 26.0, *)
struct HTTP3UnreliableDatagramStream: Sendable {
    // The QUIC stream ID.
    let streamID: QUICStreamID

    /// The inbound datagram stream.
    let inbound: AsyncStream<ByteBuffer>

    /// The continuation associated with `inbound`.
    private let inboundContinuation: AsyncStream<ByteBuffer>.Continuation

    /// The connection channel.
    private let connectionChannel: any Channel

    /// - Parameters:
    ///   - streamID: The QUIC stream ID.
    ///   - connectionChannel: The HTTP/3 connection channel.
    ///   - maxBufferedDatagrams: The maximum number of received but not yet consumed datagrams to buffer.
    init(streamID: QUICStreamID, connectionChannel: any Channel, maxBufferedDatagrams: Int) {
        self.streamID = streamID
        self.connectionChannel = connectionChannel

        (self.inbound, self.inboundContinuation) = AsyncStream<ByteBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(maxBufferedDatagrams)
        )
    }

    /// Delivers an inbound datagram to the request stream's datagram reader.
    func receive(_ payload: ByteBuffer) {
        _ = self.inboundContinuation.yield(payload)
    }

    /// Ends the datagram stream.
    func finish() {
        self.inboundContinuation.finish()
    }

    /// Writes `payload` as a datagram for this request stream.
    ///
    /// - Throws: `NIOQUIC.QUICError.datagramTooLarge` when attempting to write a datagram larger than the
    ///   `max_datagram_frame_size` advertised by the client.
    func write(_ payload: ByteBuffer) async throws {
        try await self.connectionChannel.writeAndFlush(HTTP3Datagram(streamID: self.streamID, payload: payload))
    }
}
#endif  // HTTP3 && UnstableHTTPDatagrams
