//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

@testable import HTTPServer

extension HTTPServer.SocketAddress {
    var host: String {
        switch self.base {
        case .ipv4(let ipv4):
            return ipv4.host
        case .ipv6(let ipv6):
            return ipv6.host
        }
    }

    var port: Int {
        switch self.base {
        case .ipv4(let ipv4):
            return ipv4.port
        case .ipv6(let ipv6):
            return ipv6.port
        }
    }
}
