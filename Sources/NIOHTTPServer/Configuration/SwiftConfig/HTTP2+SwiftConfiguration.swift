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

#if Configuration
public import Configuration

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP2 {
    /// Initialize an HTTP/2 configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `maxFrameSize` (int, optional, default: 2^14): The maximum frame size to be used in an HTTP/2 connection.
    /// - `targetWindowSize` (int, optional, default: 2^16 - 1): The target window size to be used in an HTTP/2
    ///    connection.
    /// - `maxConcurrentStreams` (int, optional, default: 100): The maximum number of concurrent streams in an HTTP/2
    ///    connection.
    /// - `gracefulShutdown.maximumDuration` (int, optional, default: nil): The maximum amount of time (in seconds) that
    ///   the connection has to close gracefully.
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) {
        self.init(
            maxFrameSize: config.int(
                forKey: "maxFrameSize",
                default: NIOHTTPServerConfiguration.HTTP2.defaultMaxFrameSize
            ),
            targetWindowSize: config.int(
                forKey: "targetWindowSize",
                default: NIOHTTPServerConfiguration.HTTP2.defaultTargetWindowSize
            ),
            maxConcurrentStreams: config.int(forKey: "maxConcurrentStreams", default: 100),
            gracefulShutdown: .init(config: config.scoped(to: "gracefulShutdown"))
        )
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP2.GracefulShutdownConfiguration {
    /// Initialize a HTTP/2 graceful shutdown configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `maximumDuration` (int, optional, default: nil): The maximum amount of time (in seconds) that the connection
    ///   has to close gracefully.
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) {
        self.init(
            maximumGracefulShutdownDuration: config.int(forKey: "maximumDuration").map { .seconds($0) }
        )
    }
}
#endif  // Configuration
