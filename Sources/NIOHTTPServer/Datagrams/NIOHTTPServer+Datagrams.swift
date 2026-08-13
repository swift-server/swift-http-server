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

/// Errors from reading/writing on the unreliable datagram.
@available(anyAppleOS 26.0, *)
public enum DatagramsError: Error, Sendable {
    /// The unreliable datagram transport is not yet implemented.
    case notImplemented
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// A reader for the unreliable datagram stream.
    public struct DatagramReader: AsyncReader, ~Copyable {
        public typealias ReadElement = UInt8
        public typealias Buffer = UniqueArray<UInt8>
        public typealias ReadFailure = any Error
        public typealias FinalElement = Void

        public mutating func read<Return: ~Copyable, Failure: Error>(
            body: (inout Buffer, consuming FinalElement?) async throws(Failure) -> Return
        ) async throws(EitherError<ReadFailure, Failure>) -> Return {
            // TODO: The datagram transport is not yet implemented.
            throw .first(DatagramsError.notImplemented)
        }
    }

    /// A writer for the unreliable datagram stream.
    public struct DatagramWriter: CallerAsyncWriter, ~Copyable {
        public typealias WriteElement = UInt8
        public typealias WriteFailure = any Error
        public typealias FinalElement = Void

        public mutating func write<Buffer: RangeReplaceableContainer<WriteElement> & ~Copyable>(
            buffer: inout Buffer
        ) async throws where Buffer.Element: ~Copyable {
            // TODO: The datagram transport is not yet implemented.
            throw DatagramsError.notImplemented
        }

        public consuming func finish<Buffer: RangeReplaceableContainer<WriteElement> & ~Copyable>(
            buffer: inout Buffer,
            finalElement: consuming Void
        ) async throws where Buffer.Element: ~Copyable {
            // TODO: The datagram transport is not yet implemented.
            throw DatagramsError.notImplemented
        }
    }
}

@available(*, unavailable)
extension NIOHTTPServer.DatagramReader: Sendable {}

@available(*, unavailable)
extension NIOHTTPServer.DatagramWriter: Sendable {}

#endif  // HTTP3 && UnstableHTTPDatagrams
