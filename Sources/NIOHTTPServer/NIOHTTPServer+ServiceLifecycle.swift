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

#if ServiceLifecycle
public import HTTPServer
import HTTPTypes
import Logging
import NIOExtras

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOHTTPServer: GracefulShutdownService {
    /// Initiates graceful shutdown of the HTTP server.
    public func beginGracefulShutdown() {
        self.close()
        self.serverQuiescingHelper.initiateShutdown(promise: nil)
    }
}
#endif  // ServiceLifecycle
