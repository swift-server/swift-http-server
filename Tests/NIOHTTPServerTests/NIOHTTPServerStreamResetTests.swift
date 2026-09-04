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

import Logging
import NIOCore
import NIOEmbedded
import NIOHPACK
import NIOHTTP2
import NIOHTTPTypes
import Testing

@testable import NIOHTTPServer

#if HTTP3
import HTTP3
import NIOQUICHelpers
#endif

/// An error that maps to protocol-specific codes, as a request handler author would write.
enum StreamResetTestError: Error {
    case connectFailed
}

extension StreamResetTestError: HTTPServerHTTP2StreamResetErrorConvertible {
    // The protocol takes the raw on-the-wire value, so derive it from NIO's code type.
    var http2StreamResetCode: UInt32 { UInt32(HTTP2ErrorCode.connectError.networkCode) }
}

#if HTTP3
extension StreamResetTestError: HTTPServerHTTP3StreamResetErrorConvertible {
    var http3StreamResetCode: UInt64 { HTTPTypes.HTTP3ErrorCode.connectError.rawValue }
    var http3StopSendingCode: UInt64 { HTTPTypes.HTTP3ErrorCode.connectError.rawValue }
}
#endif

@Suite
struct NIOHTTPServerStreamResetTests {
    let clientLogger = Logger(label: "NIOHTTPServerStreamResetTests.client")
    let serverLogger = Logger(label: "NIOHTTPServerStreamResetTests.server")

    // MARK: - HTTP/1.1

    @Test("Aborting while the response head is still buffered flushes it with Connection: close and no response end")
    @available(anyAppleOS 26.0, *)
    func testHTTP1AbortWhileResponseHeadIsBuffered() throws {
        let channel = EmbeddedChannel()
        try channel.connect(to: try .init(ipAddress: "127.0.0.1", port: 0)).wait()
        try channel.pipeline.syncOperations.addHandler(HTTPKeepAliveHandler())

        // The request head arrives but not its `.end`, so a response head gets buffered rather than streamed.
        try channel.writeInbound(
            HTTPRequestPart.head(.init(method: .post, scheme: "http", authority: "test", path: "/"))
        )

        // Write (without flushing) the handler's own response head so it lands in the keep-alive handler's buffer.
        _ = channel.write(HTTPResponsePart.head(.init(status: .ok)))

        NIOHTTPServer.abortRequest(
            requestContext: .init(connectionContext: .init(httpVersion: .plaintextHTTP1_1), channel: channel),
            error: TestError.intentional
        )
        channel.embeddedEventLoop.run()

        // The buffered head still reaches the wire, amended with `Connection: close`.
        switch try channel.readOutbound(as: HTTPResponsePart.self) {
        case .head(let response):
            #expect(response.status == .ok)
            #expect(
                response.headerFields[.connection] == "close",
                "Expected Connection: close, got headers: \(response.headerFields)"
            )

        case let other:
            Issue.record("Expected the buffered response head, got \(String(describing: other))")
        }

        // Crucially, no response `.end` is synthesized. Under chunked encoding `.end` writes the terminating chunk,
        // which would tell the client the abandoned response was complete. Omitting it truncates the response, which is
        // the signal we want.
        if let unexpected = try channel.readOutbound(as: HTTPResponsePart.self) {
            Issue.record("Expected no further response parts, got \(unexpected)")
        }

        _ = try? channel.finish()
    }

    @Test("Aborting after the response head reached the wire sends no second head and no response end")
    @available(anyAppleOS 26.0, *)
    func testHTTP1AbortWhileStreaming() throws {
        let channel = EmbeddedChannel()
        try channel.connect(to: try .init(ipAddress: "127.0.0.1", port: 0)).wait()
        try channel.pipeline.syncOperations.addHandler(HTTPKeepAliveHandler())

        // A fully received request means the response streams directly instead of being buffered.
        try channel.writeInbound(
            HTTPRequestPart.head(.init(method: .get, scheme: "http", authority: "test", path: "/"))
        )
        try channel.writeInbound(HTTPRequestPart.end(nil))
        try channel.writeOutbound(HTTPResponsePart.head(.init(status: .ok)))

        switch try channel.readOutbound(as: HTTPResponsePart.self) {
        case .head:
            ()

        case let other:
            Issue.record("Expected the response head, got \(String(describing: other))")
        }

        NIOHTTPServer.abortRequest(
            requestContext: .init(connectionContext: .init(httpVersion: .plaintextHTTP1_1), channel: channel),
            error: TestError.intentional
        )
        channel.embeddedEventLoop.run()

        // The head is already on the wire and cannot be recalled, so nothing further is written: no second head
        // (which would corrupt the framing) and no fabricated `.end` (which would claim the abandoned response was
        // complete). The client is left observing a truncated response.
        if let unexpected = try channel.readOutbound(as: HTTPResponsePart.self) {
            Issue.record("Expected no further response parts, got \(unexpected)")
        }

        _ = try? channel.finish()
    }

    @Test(
        "HTTP/1.1: throwing before the response head sends 500 with Connection: close",
        arguments: [NIOHTTPServer.HTTPVersion.plaintextHTTP1_1, .http1_1]
    )
    @available(anyAppleOS 26.0, *)
    func testHTTP1ThrowingBeforeResponseHeadSendsInternalServerError(
        http1Variant: NIOHTTPServer.HTTPVersion
    ) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: http1Variant,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await TestHelpers.withClientServerRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in
                throw StreamResetTestError.connectFailed
            }
        ) { _, inbound, outbound in
            try await outbound.write(.testHead(method: .get, for: http1Variant))
            try await outbound.write(.end(nil))

            try await TestHelpers.validateResponse(
                inbound,
                expectedHead: [
                    .init(
                        status: .internalServerError,
                        headerFields: [.contentLength: "0", .connection: "close"]
                    )
                ],
                expectedBody: [],
                expectStreamEnd: true
            )
        }
    }

    // MARK: - HTTP/2

    @Test("HTTP/2: throwing a conforming error resets the stream with that error's code")
    @available(anyAppleOS 26.0, *)
    func testHTTP2ThrowingConformingErrorResetsStream() async throws {
        try await self.assertHTTP2Reset(
            throwing: StreamResetTestError.connectFailed,
            expectedCode: .connectError
        )
    }

    @Test("HTTP/2: throwing a non-conforming error resets the stream with INTERNAL_ERROR")
    @available(anyAppleOS 26.0, *)
    func testHTTP2ThrowingNonConformingErrorResetsStreamWithInternalError() async throws {
        try await self.assertHTTP2Reset(
            throwing: TestError.intentional,
            expectedCode: .internalError
        )
    }

    /// Runs a handler that throws `error` over HTTP/2 and asserts the client observes `RST_STREAM(expectedCode)`.
    @available(anyAppleOS 26.0, *)
    private func assertHTTP2Reset(
        throwing error: any Error,
        expectedCode: NIOHTTP2.HTTP2ErrorCode,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .http2,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await TestHelpers.withClientServerConnection(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in
                throw error
            }
        ) { _, clientConnection in
            let rawStream = try await clientConnection.makeRawHTTP2RequestStream()
            try await rawStream.executeThenClose { inbound, outbound in
                let requestHeaders: HPACKHeaders = [
                    ":method": "GET",
                    ":scheme": "https",
                    ":authority": "test",
                    ":path": "/",
                ]
                try await outbound.write(.headers(.init(headers: requestHeaders, endStream: true)))

                var observedCode: NIOHTTP2.HTTP2ErrorCode?
                for try await payload in inbound {
                    if case .rstStream(let code) = payload {
                        observedCode = code
                        break
                    }
                }

                #expect(
                    observedCode == expectedCode,
                    "Expected RST_STREAM(\(expectedCode)), got \(String(describing: observedCode)).",
                    sourceLocation: sourceLocation
                )
            }
        }
    }

    @Test("HTTP/2: throwing after the response head still resets the stream")
    @available(anyAppleOS 26.0, *)
    func testHTTP2ThrowingAfterResponseHeadResetsStream() async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .http2,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await TestHelpers.withClientServerConnection(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, sender in
                // Establish the response, as a CONNECT tunnel would, then fail before concluding it.
                _ = try await sender.send(.init(status: .ok))
                throw StreamResetTestError.connectFailed
            }
        ) { _, clientConnection in
            let rawStream = try await clientConnection.makeRawHTTP2RequestStream()
            try await rawStream.executeThenClose { inbound, outbound in
                let requestHeaders: HPACKHeaders = [
                    ":method": "GET",
                    ":scheme": "https",
                    ":authority": "test",
                    ":path": "/",
                ]
                try await outbound.write(.headers(.init(headers: requestHeaders, endStream: true)))

                var sawResponseHeaders = false
                var resetCode: NIOHTTP2.HTTP2ErrorCode?
                for try await payload in inbound {
                    switch payload {
                    case .headers:
                        sawResponseHeaders = true
                    case .rstStream(let code):
                        resetCode = code
                    default:
                        ()
                    }

                    // Stop at the reset: continuing to iterate surfaces the stream's terminal
                    // `NIOHTTP2Errors.StreamClosed`, which carries the same code.
                    if resetCode != nil { break }
                }

                #expect(sawResponseHeaders, "Expected the response head the handler sent.")
                #expect(
                    resetCode == .connectError,
                    "Expected RST_STREAM(connectError), got \(String(describing: resetCode))."
                )
            }
        }
    }

    #if HTTP3
    // MARK: - HTTP/3

    @Test("Aborting an HTTP/3 stream emits RESET_STREAM and STOP_SENDING carrying the resolved codes")
    @available(anyAppleOS 26.0, *)
    func testHTTP3AbortEmitsResetStreamAndStopSending() throws {
        let channel = EmbeddedChannel()
        try channel.connect(to: try .init(ipAddress: "127.0.0.1", port: 0)).wait()
        let recorder = OutboundUserEventRecorder()
        try channel.pipeline.syncOperations.addHandler(recorder)

        NIOHTTPServer.abortRequest(
            requestContext: .init(connectionContext: .init(httpVersion: .http3), channel: channel),
            error: StreamResetTestError.connectFailed
        )
        channel.embeddedEventLoop.run()

        let resetEvents = recorder.events.compactMap { $0 as? QUICResetStreamEvent }
        let stopSendingEvents = recorder.events.compactMap { $0 as? QUICStopSendingEvent }

        #expect(resetEvents.count == 1, "Expected exactly one RESET_STREAM.")
        #expect(stopSendingEvents.count == 1, "Expected exactly one STOP_SENDING.")

        let expectedCode = QUICApplicationErrorCode(0x010f)
        #expect(resetEvents.first?.code == expectedCode)
        #expect(stopSendingEvents.first?.code == expectedCode)

        _ = try? channel.finish()
    }

    @Test("Aborting an HTTP/3 stream with an error describing no codes uses H3_INTERNAL_ERROR")
    @available(anyAppleOS 26.0, *)
    func testHTTP3AbortWithNonConformingErrorUsesInternalError() throws {
        let channel = EmbeddedChannel()
        try channel.connect(to: try .init(ipAddress: "127.0.0.1", port: 0)).wait()
        let recorder = OutboundUserEventRecorder()
        try channel.pipeline.syncOperations.addHandler(recorder)

        NIOHTTPServer.abortRequest(
            requestContext: .init(connectionContext: .init(httpVersion: .http3), channel: channel),
            error: TestError.intentional
        )
        channel.embeddedEventLoop.run()

        let expectedCode = QUICApplicationErrorCode(HTTPTypes.HTTP3ErrorCode.internalError.rawValue)
        #expect(recorder.events.compactMap { $0 as? QUICResetStreamEvent }.first?.code == expectedCode)
        #expect(recorder.events.compactMap { $0 as? QUICStopSendingEvent }.first?.code == expectedCode)

        _ = try? channel.finish()
    }

    @Test("HTTP/3: throwing from the handler resets the stream, failing the client's read")
    @available(anyAppleOS 26.0, *)
    func testHTTP3ThrowingResetsStream() async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .http3,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        // The stream is reset rather than completed, so draining the response fails instead of ending cleanly.
        let httpError = try await #require(throws: HTTP3Error.self) {
            try await TestHelpers.withClientServerRequestChannel(
                clientConfiguration: clientConfiguration,
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in
                    throw StreamResetTestError.connectFailed
                }
            ) { _, inbound, outbound in
                try await outbound.write(.testHead(method: .get, for: .http3))
                try await outbound.write(.end(nil))

                for try await _ in inbound {}
            }
        }

        #expect(httpError.code == .remoteStreamError)
        #expect(httpError.h3ErrorCode == .connectError)
    }
    @Test("HTTP/3: throwing after the response head still resets the stream")
    @available(anyAppleOS 26.0, *)
    func testHTTP3ThrowingAfterResponseHeadResetsStream() async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .http3,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        // The response is abandoned after its head, so draining it fails instead of ending cleanly.
        let httpError = try await #require(throws: HTTP3Error.self) {
            try await TestHelpers.withClientServerRequestChannel(
                clientConfiguration: clientConfiguration,
                server: server,
                serverHandler: HTTPServerClosureRequestHandler { _, _, _, sender in
                    // Establish the response, as a CONNECT tunnel would, then fail before concluding it.
                    _ = try await sender.send(.init(status: .ok))
                    throw StreamResetTestError.connectFailed
                }
            ) { _, inbound, outbound in
                try await outbound.write(.testHead(method: .get, for: .http3))
                try await outbound.write(.end(nil))

                for try await _ in inbound {}
            }
        }

        #expect(httpError.code == .remoteStreamError)
        #expect(httpError.h3ErrorCode == .connectError)
    }

    #endif
    // MARK: - All versions

    @Test(
        "Throwing after the response is concluded still delivers the full response",
        arguments: NIOHTTPServer.HTTPVersion.allCases
    )
    @available(anyAppleOS 26.0, *)
    func testThrowingAfterConcludedResponseDeliversFullResponse(
        httpVersion: NIOHTTPServer.HTTPVersion
    ) async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: httpVersion,
            clientLogger: self.clientLogger,
            serverLogger: self.serverLogger
        )

        try await TestHelpers.withClientServerRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, sender in
                // Conclude the response fully, then fail.
                try await sender.sendAndFinish(.init(status: .ok, headerFields: [.contentLength: "0"]))
                throw StreamResetTestError.connectFailed
            }
        ) { _, inbound, outbound in
            try await outbound.write(.testHead(method: .get, for: httpVersion))
            try await outbound.write(.end(nil))

            try await TestHelpers.validateResponse(
                inbound,
                expectedHead: [.init(status: .ok, headerFields: [.contentLength: "0"])],
                expectedBody: [],
                expectStreamEnd: true
            )
        }
    }
}

/// Records user outbound events (QUIC `RESET_STREAM` / `STOP_SENDING`) passing through it, so tests can assert exactly
/// which control events an abort emits.
final class OutboundUserEventRecorder: ChannelOutboundHandler, @unchecked Sendable {
    typealias OutboundIn = Any

    private(set) var events: [Any] = []

    func triggerUserOutboundEvent(context: ChannelHandlerContext, event: Any, promise: EventLoopPromise<Void>?) {
        self.events.append(event)
        context.triggerUserOutboundEvent(event, promise: promise)
    }
}
