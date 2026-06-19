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
import NIOExtras
import NIOHTTPTypes

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    /// Abstracts over the two types of server channels ``NIOHTTPServer`` can create: plaintext HTTP/1.1 and Secure
    /// Upgrade.
    enum ServerChannel {
        case plaintextHTTP1_1(
            channel: NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>,
            quiescingHelper: ServerQuiescingHelper
        )

        case secureUpgrade(
            channel: NIOAsyncChannel<EventLoopFuture<NegotiatedChannel>, Never>,
            quiescingHelper: ServerQuiescingHelper
        )
    }
}
