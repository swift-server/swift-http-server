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

public import BasicContainers
public import HTTPAPIs
import NIOCore
import NIOHTTPTypes
import Synchronization

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// A reader for the unreliable datagram stream.
    public struct DatagramReader: AsyncReader, ~Copyable {
        public typealias ReadElement = UInt8
        public typealias Buffer = UniqueArray<UInt8>
        public typealias ReadFailure = any Error
        public typealias FinalElement = Void

        /// The iterator over the inbound datagrams.
        private var iterator: AsyncStream<ByteBuffer>.AsyncIterator

        /// A reusable buffer handed to the body closure on each call to ``read(body:)``.
        private var buffer: UniqueArray<UInt8>

        init(iterator: AsyncStream<ByteBuffer>.AsyncIterator) {
            self.iterator = iterator
            self.buffer = UniqueArray<UInt8>()
        }

        public mutating func read<Return: ~Copyable, Failure: Error>(
            body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
        ) async throws(EitherError<ReadFailure, Failure>) -> Return {
            let payload = await self.iterator.next(isolation: #isolation)

            self.buffer.removeAll(keepingCapacity: true)
            let finalElement: Void?
            if let payload {
                self.buffer.reserveCapacity(payload.readableBytes)
                self.buffer.append(copying: payload.readableBytesUInt8Span)
                finalElement = nil
            } else {
                // No more datagrams will be delivered on this stream.
                finalElement = ()
            }

            do {
                return try await body(&self.buffer, finalElement)
            } catch {
                throw .second(error)
            }
        }
    }

    /// A writer for the unreliable datagram stream.
    public struct DatagramWriter: CallerAsyncWriter, ~Copyable {
        public typealias WriteElement = UInt8
        public typealias WriteFailure = any Error
        public typealias FinalElement = Void

        /// The unreliable datagram stream to write to.
        private let unreliableStream: HTTP3UnreliableDatagramStream

        init(unreliableStream: HTTP3UnreliableDatagramStream) {
            self.unreliableStream = unreliableStream
        }

        public mutating func write<Buffer: RangeReplaceableContainer<WriteElement> & ~Copyable>(
            buffer: inout Buffer
        ) async throws where Buffer.Element: ~Copyable {
            try await self.unreliableStream.write(ByteBuffer(draining: &buffer))
        }

        public consuming func finish<Buffer: RangeReplaceableContainer<WriteElement> & ~Copyable>(
            buffer: inout Buffer,
            finalElement: consuming Void
        ) async throws where Buffer.Element: ~Copyable {
            if !buffer.isEmpty {
                try await self.unreliableStream.write(ByteBuffer(draining: &buffer))
            }
        }
    }
}

@available(*, unavailable)
extension NIOHTTPServer.DatagramReader: Sendable {}

@available(*, unavailable)
extension NIOHTTPServer.DatagramWriter: Sendable {}

#endif  // HTTP3 && UnstableHTTPDatagrams
