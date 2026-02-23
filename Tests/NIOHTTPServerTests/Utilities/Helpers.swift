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
import NIOEmbedded

extension NIOAsyncTestingChannel {
    /// Forwards all of our outbound writes to `other` and vice-versa.
    func glueTo(_ other: NIOAsyncTestingChannel) async throws {
        try await withThrowingDiscardingTaskGroup { group in
            // 1. Forward all `self` writes to `other`
            group.addTask {
                while !Task.isCancelled {
                    do {
                        let ourPart = try await self.waitForOutboundWrite(as: ByteBuffer.self)
                        try await other.writeInbound(ourPart)
                    } catch ChannelError.ioOnClosedChannel {
                        // We only reach here if the channel has closed. `waitForOutboundWrite` uses a continuation
                        // without `withTaskCancellationHandler`, so this error is the only shutdown signal; returning
                        // allows the task group and `glueTo` to complete cleanly.
                        return
                    }
                }
            }

            // 2. Forward all `other` writes to `self`
            group.addTask {
                while !Task.isCancelled {
                    do {
                        let otherPart = try await other.waitForOutboundWrite(as: ByteBuffer.self)
                        try await self.writeInbound(otherPart)
                    } catch ChannelError.ioOnClosedChannel {
                        // Same reasoning as above: the channel has closed, and returning allows the task group and
                        // `glueTo` to complete cleanly.
                        return
                    }
                }
            }
        }
    }

    /// Returns a `NIOAsyncTestingChannel` that is set to the `active` state.
    static func createActiveChannel() async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()

        let setToActivePromise = channel.eventLoop.makePromise(of: Void.self)
        // The `to` address has no significance here: it is just a random address. We are only interested in making the
        // channel *active*; calling `connect` is the way to achieve that.
        channel.connect(
            to: try .init(ipAddress: "127.0.0.1", port: 8000),
            promise: setToActivePromise
        )
        try await setToActivePromise.futureResult.get()

        return channel
    }
}
