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

import HTTPTypes

enum BenchmarkError: Error, CustomStringConvertible {
    case noListeningAddress
    case unexpectedResponseStatus(HTTPResponse.Status?)
    case responseEndedEarly

    var description: String {
        switch self {
        case .noListeningAddress: "the server started without reporting a listening address"
        case .unexpectedResponseStatus(let status): "the server responded with \(status.map { "\($0)" } ?? "no head")"
        case .responseEndedEarly: "the response stream finished before the end of the response"
        }
    }
}
