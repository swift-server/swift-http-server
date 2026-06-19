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

import BasicContainers
import NIOCore
import NIOHTTPTypes
import Testing

@testable import NIOHTTPServer

@Suite
struct NIOHTTPServerResponseSenderTests {
    @Test("Informational header without informational status code")
    @available(anyAppleOS 26.0, *)
    func testInformationalResponseStatusCodePrecondition() async throws {
        // Sending an informational header with a non-1xx status code shouldn't be allowed
        try await #require(processExitsWith: .failure) {
            let (outboundWriter, _) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
            var sender = NIOHTTPServer.ResponseSender(writer: outboundWriter, writerState: .init())

            try await sender.sendInformational(.init(status: .ok, headerFields: [.contentType: "application/json"]))
        }
    }

    @Test("Multiple informational responses before final response")
    @available(anyAppleOS 26.0, *)
    func testSendMultipleInformationalResponses() async throws {
        let (outboundWriter, sink) = NIOAsyncChannelOutboundWriter<HTTPResponsePart>.makeTestingWriter()
        var sender = NIOHTTPServer.ResponseSender(writer: outboundWriter, writerState: .init())

        // Send two informational responses
        let firstInfoHead = HTTPResponse(status: .continue, headerFields: [.contentType: "application/json"])
        let secondInfoHead = HTTPResponse(status: .earlyHints, headerFields: [.contentType: "application/json"])
        try await sender.sendInformational(firstInfoHead)
        try await sender.sendInformational(secondInfoHead)

        // Then send the final response
        let finalResponseHead = HTTPResponse(status: .ok)
        let finalResponseBody = [UInt8]([1, 2])
        let finalResponseTrailer: HTTPFields = [.cookie: "cookie"]

        var buffer = UniqueArray(copying: finalResponseBody)
        try await sender.sendAndFinish(finalResponseHead, buffer: &buffer, trailer: finalResponseTrailer)

        var responseIterator = sink.makeAsyncIterator()
        let firstHead = try #require(await responseIterator.next())
        let secondHead = try #require(await responseIterator.next())
        let finalHead = try #require(await responseIterator.next())
        let body = try #require(await responseIterator.next())
        let trailer = try #require(await responseIterator.next())

        #expect(firstHead == .head(firstInfoHead))
        #expect(secondHead == .head(secondInfoHead))
        #expect(finalHead == .head(finalResponseHead))
        #expect(body == .body(ByteBuffer(bytes: finalResponseBody)))
        #expect(trailer == .end(finalResponseTrailer))
    }
}
