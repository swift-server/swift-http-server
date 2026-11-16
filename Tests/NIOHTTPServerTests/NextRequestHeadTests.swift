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
import Logging
import NIOCore
import NIOHTTPTypes
import Testing

@testable import NIOHTTPServer

@Suite
struct NextRequestHeadTests {
    static let logger = Logger(label: "NextRequestHeadTests")

    @available(anyAppleOS 27.0, *)
    static var maxDiscardedBodyBytes: Int {
        NIOAsyncChannelInboundStream<HTTPRequestPart>.AsyncIterator.maxDiscardedBodyBytes
    }

    @available(anyAppleOS 27.0, *)
    @Test("Leftover body within the limit is discarded and the next head is returned")
    func testLeftoverBodyWithinLimitIsDiscarded() async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()
        source.yield(.body(ByteBuffer(repeating: 0, count: Self.maxDiscardedBodyBytes / 2)))
        source.yield(.body(ByteBuffer(repeating: 0, count: Self.maxDiscardedBodyBytes / 2)))
        source.yield(.end(nil))
        source.yield(.head(.next))
        source.finish()

        var iterator = stream.makeAsyncIterator()

        #expect(try await iterator.nextRequestHead(logger: Self.logger) == .next)
    }

    @available(anyAppleOS 27.0, *)
    @Test("Leftover body over the limit, split across parts, ends the connection")
    func testLeftoverBodyOverLimitEndsConnection() async throws {
        let (stream, source) = NIOAsyncChannelInboundStream<HTTPRequestPart>.makeTestingStream()
        source.yield(.body(ByteBuffer(repeating: 0, count: Self.maxDiscardedBodyBytes)))
        source.yield(.body(ByteBuffer(repeating: 0, count: 1)))
        source.yield(.end(nil))
        source.yield(.head(.next))
        source.finish()

        var iterator = stream.makeAsyncIterator()
        let head = try await iterator.nextRequestHead(logger: Self.logger)

        withKnownIssue("Leftover body bytes are not bounded yet") {
            #expect(head == nil)
        }
    }
}

extension HTTPRequest {
    fileprivate static let next = HTTPRequest(method: .get, scheme: "http", authority: "", path: "/next")
}
