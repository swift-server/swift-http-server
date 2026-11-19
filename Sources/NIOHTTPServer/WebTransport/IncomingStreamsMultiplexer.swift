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
import NIOQUICHelpers
import Synchronization

/// Routes the WebTransport streams a peer opens on an HTTP/3 connection to the session they belong to.
final class WebTransportIncomingStreamsMultiplexer: Sendable {
    private struct SessionStreams {
        let incomingUnidirectionalStreamsContinuation: AsyncStream<NIOAsyncChannel<ByteBuffer, Never>>.Continuation
        let incomingBidirectionalStreamsContinuation: AsyncStream<NIOAsyncChannel<ByteBuffer, ByteBuffer>>.Continuation
    }

    private let sessions: Mutex<[QUICStreamID: SessionStreams]> = .init([:])

    func addSession(
        id: QUICStreamID,
        unidirectionalStreamsContinuation: AsyncStream<NIOAsyncChannel<ByteBuffer, Never>>.Continuation,
        bidirectionalStreamsContinuation: AsyncStream<NIOAsyncChannel<ByteBuffer, ByteBuffer>>.Continuation
    ) {
        let sessionStreams = SessionStreams(
            incomingUnidirectionalStreamsContinuation: unidirectionalStreamsContinuation,
            incomingBidirectionalStreamsContinuation: bidirectionalStreamsContinuation
        )
        self.sessions.withLock { $0[id] = sessionStreams }
    }

    func yieldUnidirectionalStream(_ stream: NIOAsyncChannel<ByteBuffer, Never>, sessionID: QUICStreamID) {
        self.sessions.withLock { _ = $0[sessionID]?.incomingUnidirectionalStreamsContinuation.yield(stream) }
    }

    func yieldBidirectionalStream(_ stream: NIOAsyncChannel<ByteBuffer, ByteBuffer>, sessionID: QUICStreamID) {
        self.sessions.withLock { _ = $0[sessionID]?.incomingBidirectionalStreamsContinuation.yield(stream) }
    }
}

#endif
