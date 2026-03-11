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

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension NIOHTTPServer {
    /// Abstracts over the two types of server channels ``NIOHTTPServer`` can create: plaintext HTTP/1.1 and Secure
    /// Upgrade.
    enum ServerChannel {
        case plaintextHTTP1_1(NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>)
        case secureUpgrade(NIOAsyncChannel<EventLoopFuture<NegotiatedChannel>, Never>)
    }
}
