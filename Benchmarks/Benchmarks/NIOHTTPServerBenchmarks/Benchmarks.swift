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

import Benchmark
import NIOHTTPServer

let benchmarks: @Sendable () -> Void = {
    Benchmark("Placeholder") { benchmark in
        for _ in benchmark.scaledIterations {
            blackHole(1 + 1)
        }
    }
}
