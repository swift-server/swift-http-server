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

enum RequestBodyReadError: Error, CustomStringConvertible {
    case streamEnded
    case readAfterRequestEnd

    var description: String {
        switch self {
        case .streamEnded:
            "The request stream unexpectedly ended before the request end part was received."

        case .readAfterRequestEnd:
            "Attempted to read after the request end part was already received."
        }
    }
}
