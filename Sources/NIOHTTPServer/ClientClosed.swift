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

import NIOConcurrencyHelpers
import NIOCore


/// This channel handler detects a client going away and yields into a continuation that results in the request handler being
/// cancelled. This allows the request handler to be prevented from doing unnecessary work after the peer has gone away.
final class ClientClosedMonitor: ChannelInboundHandler, RemovableChannelHandler, Sendable {
    typealias InboundIn = NIOAny
    typealias InboundOut = NIOAny

    private let clientClosed: AsyncStream<Void>.Continuation

    init(clientClosed: AsyncStream<Void>.Continuation) {
        self.clientClosed = clientClosed
    }

    // - TODO: HTTP/1.1 on Darwin does not report a socket closing, as NIO registers for EOF
    // notifications only when `isEarlyEOFDeliveryWorkingOnThisOS` is true, which is hard-coded `false`
    // on Darwin (rdar://53656794). This means that this handler has no effect on H1 on Darwin until
    // that bug is resolved.
    func channelInactive(context: ChannelHandlerContext) {
        self.clientClosed.yield()
        context.fireChannelInactive()
    }
}


/// Runs `operation` and cancels it if the client stops waiting for the response first.
///
/// - Note: `operation` is a whole HTTP/1.1 request loop or a whole HTTP/2 or HTTP/3 stream.
func withCancellationWhenClientCloses(
    signalledBy clientClosed: AsyncStream<Void>,
    operation: @escaping @Sendable () async throws -> Void
) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await operation()
        }

        group.addTask {
            for await _ in clientClosed { break }
        }

        try await group.next()

        group.cancelAll()
    }
}
