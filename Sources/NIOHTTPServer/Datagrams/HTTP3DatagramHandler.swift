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

import NIOCore
import NIOHTTP3

/// A stub for the HTTP/3 datagram handler which `swift-nio-http3` will provide.
@available(anyAppleOS 26.0, *)
final class HTTP3DatagramHandler: ChannelDuplexHandler {
    typealias InboundIn = HTTP3Datagram
    typealias InboundOut = HTTP3Datagram

    typealias OutboundIn = HTTP3Datagram
    typealias OutboundOut = HTTP3Datagram
}

#endif  // HTTP3 && UnstableHTTPDatagrams
