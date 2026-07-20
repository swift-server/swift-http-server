//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTPTypes
import Synchronization

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    public struct ResponseSender: HTTPResponseSender, ~Copyable {
        let writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>
        let writerState: WriterState

        public mutating func sendInformational(_ response: HTTPResponse) async throws {
            precondition(response.status.kind == .informational)
            try await self.writer.write(.head(response))
        }

        public consuming func send(_ response: HTTPResponse) async throws -> Writer {
            precondition(response.status.kind != .informational)
            try await self.writer.write(.head(response))
            return Writer(writer: self.writer, writerState: self.writerState)
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer.ResponseSender {
    final class WriterState: Sendable {
        struct Wrapped: ~Copyable {
            var finishedWriting: Bool = false
        }

        let wrapped: Mutex<Wrapped> = .init(.init())
    }

    public struct Writer: CallerAsyncWriter, ~Copyable {
        public typealias WriteElement = UInt8

        public typealias WriteFailure = any Error

        public typealias FinalElement = HTTPFields?

        /// The underlying NIO writer for HTTP response parts.
        let writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>

        let writerState: WriterState

        public mutating func write(
            buffer: inout some RangeReplaceableContainer<UInt8> & ~Copyable
        ) async throws(WriteFailure) {
            var byteBuffer = ByteBuffer()
            byteBuffer.reserveCapacity(buffer.count)

            var consumer = buffer.consumeAll()
            // `while !done { ... }` instead of `while true { ... break }` to
            // dodge a SIL ownership-verifier crash on the nightly main
            // toolchain (https://github.com/swiftlang/swift/issues/89639).
            var done = false
            while !done {
                let span = consumer.drainNext()
                if span.isEmpty {
                    done = true
                } else {
                    byteBuffer.writeBytes(span.span.bytes)
                }
            }

            try await self.writer.write(.body(byteBuffer))
        }

        public consuming func finish(
            buffer: inout some RangeReplaceableContainer<UInt8> & ~Copyable,
            finalElement: consuming HTTPFields?
        ) async throws(WriteFailure) {
            if !buffer.isEmpty {
                var byteBuffer = ByteBuffer()
                byteBuffer.reserveCapacity(buffer.count)

                var consumer = buffer.consumeAll()
                // `while !done { ... }` instead of `while true { ... break }` to
                // dodge a SIL ownership-verifier crash on the nightly main
                // toolchain (https://github.com/swiftlang/swift/issues/89639).
                var done = false
                while !done {
                    let span = consumer.drainNext()
                    if span.isEmpty {
                        done = true
                    } else {
                        byteBuffer.writeBytes(span.span.bytes)
                    }
                }

                try await self.writer.write(.body(byteBuffer))
            }
            try await self.writer.write(.end(finalElement))
            self.writerState.wrapped.withLock { $0.finishedWriting = true }
        }
    }
}

@available(*, unavailable)
extension NIOHTTPServer.ResponseSender: Sendable {}

@available(*, unavailable)
extension NIOHTTPServer.ResponseSender.Writer: Sendable {}
