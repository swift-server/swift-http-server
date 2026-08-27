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

        // Initializes a new response sender.
        init(
            writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>,
            writerState: WriterState
        ) {
            self.writer = writer
            self.writerState = writerState
        }

        #if HTTP3 && UnstableHTTPDatagrams
        private var datagramStreamFuture: EventLoopFuture<HTTP3UnreliableDatagramStream>?

        /// Initializes a response sender that can also vend an unreliable datagram writer if the underlying transport
        /// supports unreliable datagrams.
        init(
            writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>,
            writerState: WriterState,
            datagramStreamFuture: EventLoopFuture<HTTP3UnreliableDatagramStream>? = nil
        ) {
            self.writer = writer
            self.writerState = writerState
            self.datagramStreamFuture = datagramStreamFuture
        }
        #endif

        public mutating func sendInformational(_ response: HTTPResponse) async throws {
            precondition(response.status.kind == .informational)
            try await self.writer.write(.head(response))
        }

        public consuming func send(_ response: HTTPResponse) async throws -> sending Writer {
            precondition(response.status.kind != .informational)
            try await self.writer.write(.head(response))

            #if HTTP3 && UnstableHTTPDatagrams
            return Writer(
                writer: self.writer,
                writerState: self.writerState,
                datagramStreamFuture: self.datagramStreamFuture
            )
            #else
            return Writer(writer: self.writer, writerState: self.writerState)
            #endif
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

        init(
            writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>,
            writerState: WriterState
        ) {
            self.writer = writer
            self.writerState = writerState
        }

        #if HTTP3 && UnstableHTTPDatagrams
        /// The unreliable datagram writer, present when the underlying transport supports unreliable datagrams.
        private var datagramStreamFuture: EventLoopFuture<HTTP3UnreliableDatagramStream>?

        init(
            writer: NIOAsyncChannelOutboundWriter<HTTPResponsePart>,
            writerState: WriterState,
            datagramStreamFuture: EventLoopFuture<HTTP3UnreliableDatagramStream>? = nil
        ) {
            self.writer = writer
            self.writerState = writerState
            self.datagramStreamFuture = datagramStreamFuture
        }
        #endif

        public mutating func write(
            buffer: inout some RangeReplaceableContainer<UInt8> & ~Copyable
        ) async throws(WriteFailure) {
            try await self.writer.write(.body(ByteBuffer(draining: &buffer)))
        }

        public consuming func finish(
            buffer: inout some RangeReplaceableContainer<UInt8> & ~Copyable,
            finalElement: consuming HTTPFields?
        ) async throws(WriteFailure) {
            if !buffer.isEmpty {
                try await self.writer.write(.body(ByteBuffer(draining: &buffer)))
            }
            try await self.writer.write(.end(finalElement))
            self.writerState.wrapped.withLock { $0.finishedWriting = true }
        }

        #if HTTP3 && UnstableHTTPDatagrams
        /// Returns the unreliable datagram writer for this stream, if both the server and the client have advertised
        /// support for receiving datagrams.
        ///
        /// - Note: This function will suspend until the server has received the SETTINGS frame from the client. This is
        ///   because the server must send _and_ receive the `SETTINGS_H3_DATAGRAMS` setting with value 1 before sending
        ///   or receiving unreliable datagrams. See https://datatracker.ietf.org/doc/html/rfc9297#section-2.1.1-3.
        ///
        /// - Important: This function can only be called once. Any successive calls will result in a runtime crash.
        public mutating func takeDatagramWriter() async -> sending NIOHTTPServer.DatagramWriter? {
            guard let streamFuture = self.datagramStreamFuture else {
                // The peer did not agree to receiving datagrams.
                return nil
            }

            do {
                return NIOHTTPServer.DatagramWriter(unreliableStream: try await streamFuture.get())
            } catch {
                // The peer did not agree to receiving datagrams.
                return nil
            }
        }
        #endif  // HTTP3 && UnstableHTTPDatagrams
    }
}

@available(*, unavailable)
extension NIOHTTPServer.ResponseSender: Sendable {}

@available(*, unavailable)
extension NIOHTTPServer.ResponseSender.Writer: Sendable {}

extension ByteBuffer {
    /// Drains `buffer` into a newly allocated `ByteBuffer`.
    init<Buffer: RangeReplaceableContainer<UInt8> & ~Copyable>(
        draining buffer: inout Buffer
    ) where Buffer.Element: ~Copyable {
        self.init()
        self.reserveCapacity(buffer.count)

        var consumer = buffer.consumeAll()
        // `while !done { ... }` instead of `while true { ... break }` to dodge a SIL ownership-verifier crash on the
        // nightly main toolchain (https://github.com/swiftlang/swift/issues/89639).
        var done = false
        while !done {
            let span = consumer.drainNext()
            if span.isEmpty {
                done = true
            } else {
                self.writeBytes(span.span.bytes)
            }
        }
    }
}
