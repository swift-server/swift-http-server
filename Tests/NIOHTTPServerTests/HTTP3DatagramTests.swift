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

import BasicContainers
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP3
import NIOQUIC
import NIOQUICHelpers
import Testing

@testable import NIOHTTPServer

@Suite
struct HTTP3DatagramTests {
    static let serverLogger = Logger(label: "HTTP3DatagramTests.server")
    static let clientLogger = Logger(label: "HTTP3DatagramTests.client")

    @Test("Datagrams are routed to the request stream they belong to")
    @available(anyAppleOS 26.0, *)
    func datagramsAreRoutedByStreamID() async throws {
        let channel = EmbeddedChannel()
        let datagramsNegotiatedPromise = channel.eventLoop.makePromise(of: Void.self)

        let manager = HTTP3ConnectionManager(
            eventLoop: channel.eventLoop,
            logger: Self.serverLogger,
            datagramsNegotiatedPromise: datagramsNegotiatedPromise
        )
        try channel.pipeline.syncOperations.addHandler(manager)
        channel.pipeline.syncOperations.fireUserInboundEventTriggered(ReceivedSettings(datagramsSupported: true))

        let first = HTTP3UnreliableDatagramStream(streamID: 0, connectionChannel: channel, maxBufferedDatagrams: 16)
        let second = HTTP3UnreliableDatagramStream(streamID: 2, connectionChannel: channel, maxBufferedDatagrams: 16)
        manager.register(datagramStream: first)
        manager.register(datagramStream: second)

        var firstReader = NIOHTTPServer.DatagramReader(iterator: first.inbound.makeAsyncIterator())
        var secondReader = NIOHTTPServer.DatagramReader(iterator: second.inbound.makeAsyncIterator())

        try channel.writeInbound(HTTP3Datagram(streamID: 0, payload: ByteBuffer([1, 2, 3])))
        try channel.writeInbound(HTTP3Datagram(streamID: 2, payload: ByteBuffer([4, 5, 6])))
        // Nothing is registered for stream 4, so this datagram should be dropped.
        try channel.writeInbound(HTTP3Datagram(streamID: 4, payload: ByteBuffer([2])))

        #expect(try await TestHelpers.readDatagram(&firstReader) == [1, 2, 3])
        #expect(try await TestHelpers.readDatagram(&secondReader) == [4, 5, 6])
    }

    @Test("Datagrams delivered after deregistering are dropped")
    @available(anyAppleOS 26.0, *)
    func datagramsAfterDeregisteringAreDropped() async throws {
        let channel = EmbeddedChannel()
        let datagramsNegotiatedPromise = channel.eventLoop.makePromise(of: Void.self)
        let manager = HTTP3ConnectionManager(
            eventLoop: channel.eventLoop,
            logger: Self.serverLogger,
            datagramsNegotiatedPromise: datagramsNegotiatedPromise
        )
        try channel.pipeline.syncOperations.addHandler(manager)
        channel.pipeline.syncOperations.fireUserInboundEventTriggered(ReceivedSettings(datagramsSupported: true))

        let stream = HTTP3UnreliableDatagramStream(streamID: 0, connectionChannel: channel, maxBufferedDatagrams: 16)
        manager.register(datagramStream: stream)
        var reader = NIOHTTPServer.DatagramReader(iterator: stream.inbound.makeAsyncIterator())

        manager.deregister(streamID: stream.streamID)
        try channel.writeInbound(HTTP3Datagram(streamID: 0, payload: ByteBuffer([1])))
        stream.finish()

        #expect(try await TestHelpers.readDatagram(&reader) == nil)
    }

    @Test("Closing the connection ends every registered datagram stream")
    @available(anyAppleOS 26.0, *)
    func closingTheConnectionEndsEveryDatagramStream() async throws {
        let channel = EmbeddedChannel()
        let datagramsNegotiatedPromise = channel.eventLoop.makePromise(of: Void.self)
        let manager = HTTP3ConnectionManager(
            eventLoop: channel.eventLoop,
            logger: Self.serverLogger,
            datagramsNegotiatedPromise: datagramsNegotiatedPromise
        )
        try channel.pipeline.syncOperations.addHandler(manager)
        channel.pipeline.syncOperations.fireUserInboundEventTriggered(ReceivedSettings(datagramsSupported: true))

        let first = HTTP3UnreliableDatagramStream(streamID: 0, connectionChannel: channel, maxBufferedDatagrams: 16)
        let second = HTTP3UnreliableDatagramStream(streamID: 16, connectionChannel: channel, maxBufferedDatagrams: 16)
        manager.register(datagramStream: first)
        manager.register(datagramStream: second)

        var firstReader = NIOHTTPServer.DatagramReader(iterator: first.inbound.makeAsyncIterator())
        var secondReader = NIOHTTPServer.DatagramReader(iterator: second.inbound.makeAsyncIterator())

        let leftOverState = try channel.finish()

        #expect(leftOverState.isClean)
        #expect(try await TestHelpers.readDatagram(&firstReader) == nil)
        #expect(try await TestHelpers.readDatagram(&secondReader) == nil)
    }

    @Test("The oldest datagram is dropped once the buffer is full")
    @available(anyAppleOS 26.0, *)
    func oldestDatagramIsDroppedOnceTheBufferIsFull() async throws {
        let channel = EmbeddedChannel()
        let stream = HTTP3UnreliableDatagramStream(streamID: 0, connectionChannel: channel, maxBufferedDatagrams: 2)

        for byte in UInt8(1)...4 {
            stream.receive(ByteBuffer([byte]))
        }

        // The two newest datagrams are kept.
        var reader = NIOHTTPServer.DatagramReader(iterator: stream.inbound.makeAsyncIterator())
        #expect(try await TestHelpers.readDatagram(&reader) == [3])
        #expect(try await TestHelpers.readDatagram(&reader) == [4])
    }

    @Test("Each write is sent as one datagram containing the stream's ID")
    @available(anyAppleOS 26.0, *)
    func eachWriteIsSentAsOneDatagram() async throws {
        let channel = EmbeddedChannel()

        var streamZeroWriter = NIOHTTPServer.DatagramWriter(
            unreliableStream: .init(streamID: 0, connectionChannel: channel, maxBufferedDatagrams: 16)
        )
        var streamFourWriter = NIOHTTPServer.DatagramWriter(
            unreliableStream: .init(streamID: 4, connectionChannel: channel, maxBufferedDatagrams: 16)
        )

        var streamZeroFirstBuffer = UniqueArray<UInt8>(copying: [1])
        var streamZeroSecondBuffer = UniqueArray<UInt8>(copying: [2])
        try await streamZeroWriter.write(buffer: &streamZeroFirstBuffer)
        try await streamZeroWriter.write(buffer: &streamZeroSecondBuffer)

        var streamTwoFirstBuffer = UniqueArray<UInt8>(copying: [3])
        var streamTwoSecondBuffer = UniqueArray<UInt8>(copying: [4])
        try await streamFourWriter.write(buffer: &streamTwoFirstBuffer)
        try await streamFourWriter.write(buffer: &streamTwoSecondBuffer)

        let streamZeroFirstDatagram = try channel.readOutbound(as: HTTP3Datagram.self)
        let streamZeroSecondDatagram = try channel.readOutbound(as: HTTP3Datagram.self)

        let streamFourFirstDatagram = try channel.readOutbound(as: HTTP3Datagram.self)
        let streamFourSecondDatagram = try channel.readOutbound(as: HTTP3Datagram.self)

        #expect(streamZeroFirstDatagram?.streamID == 0)
        #expect(streamZeroFirstDatagram?.payload == .init([1]))
        #expect(streamZeroSecondDatagram?.streamID == 0)
        #expect(streamZeroSecondDatagram?.payload == .init([2]))

        #expect(streamFourFirstDatagram?.streamID == 4)
        #expect(streamFourFirstDatagram?.payload == .init([3]))
        #expect(streamFourSecondDatagram?.streamID == 4)
        #expect(streamFourSecondDatagram?.payload == .init([4]))
    }

    @Test("Finishing flushes any remaining bytes as a final datagram")
    @available(anyAppleOS 26.0, *)
    func finishingWritesRemainingBytes() async throws {
        let channel = EmbeddedChannel()
        let writer = NIOHTTPServer.DatagramWriter(
            unreliableStream: .init(streamID: 0, connectionChannel: channel, maxBufferedDatagrams: 16)
        )

        var buffer = UniqueArray<UInt8>(copying: [7, 8])
        try await writer.finish(buffer: &buffer, finalElement: ())

        let datagram = try channel.readOutbound(as: HTTP3Datagram.self)
        #expect(datagram?.streamID == 0)
        #expect(datagram?.payload == ByteBuffer([7, 8]))
    }

    @Test("Finishing with an empty buffer writes no datagram")
    @available(anyAppleOS 26.0, *)
    func finishingWithAnEmptyBufferWritesNoDatagram() async throws {
        let channel = EmbeddedChannel()
        let writer = NIOHTTPServer.DatagramWriter(
            unreliableStream: .init(streamID: 0, connectionChannel: channel, maxBufferedDatagrams: 16)
        )

        var buffer = UniqueArray<UInt8>()
        try await writer.finish(buffer: &buffer, finalElement: ())

        #expect(try channel.readOutbound(as: HTTP3Datagram.self) == nil)
    }

    @Test("Reading and writing datagrams are independent of each other")
    @available(anyAppleOS 26.0, *)
    func readingAndWritingAreIndependent() async throws {
        let channel = EmbeddedChannel()
        let stream = HTTP3UnreliableDatagramStream(streamID: 4, connectionChannel: channel, maxBufferedDatagrams: 16)
        var reader = NIOHTTPServer.DatagramReader(iterator: stream.inbound.makeAsyncIterator())
        var writer = NIOHTTPServer.DatagramWriter(unreliableStream: stream)

        stream.receive(ByteBuffer([1]))
        var buffer = UniqueArray<UInt8>(copying: [2])
        try await writer.write(buffer: &buffer)

        #expect(try await TestHelpers.readDatagram(&reader) == [1])

        let datagram = try channel.readOutbound(as: HTTP3Datagram.self)
        #expect(datagram?.streamID == 4)
        #expect(datagram?.payload == ByteBuffer([2]))
    }

    @Test("Read and write datagrams")
    @available(anyAppleOS 26.2, *)
    func readAndWriteDatagrams() async throws {
        let (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .http3,
            clientLogger: Self.clientLogger,
            serverLogger: Self.serverLogger
        )

        let streamOpenedPromise = server.eventLoopGroup.any().makePromise(of: Void.self)

        try await TestHelpers.withHTTP3ClientServerConnectionAndRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                streamOpenedPromise.succeed()

                var reader = reader
                var datagramReader = await reader.takeDatagramReader()!

                // Read the datagram.
                let collectedDatagram = try #require(await TestHelpers.readDatagram(&datagramReader))
                #expect(collectedDatagram == .init(buffer: .testData))

                // Echo the datagram back.
                var writer = try await responseSender.send(.init(status: .ok))
                var datagramWriter = await writer.takeDatagramWriter()!
                var writeBuffer = UniqueArray<UInt8>(copying: collectedDatagram)
                try await datagramWriter.write(buffer: &writeBuffer)

                try await writer.finish()
            }
        ) { _, streamID, connectionChannel, streamChannel in
            try await connectionChannel.executeThenClose { connectionInbound, connectionOutbound in
                try await streamChannel.executeThenClose { streamInbound, streamOutbound in
                    // Start the request.
                    try await streamOutbound.write(.testHead(method: .post, for: .http3))

                    // Wait for the stream to be opened.
                    try await streamOpenedPromise.futureResult.get()

                    // Now write a datagram.
                    try await connectionOutbound.write(HTTP3Datagram(streamID: streamID, payload: .testData))

                    var inboundDatagramIterator = connectionInbound.makeAsyncIterator()

                    let collectedDatagram = try await inboundDatagramIterator.next()
                    #expect(collectedDatagram?.streamID == streamID)
                    #expect(collectedDatagram?.payload == .testData)

                    // Now end the request.
                    try await streamOutbound.write(.end(nil))

                    try await TestHelpers.validateResponse(
                        streamInbound,
                        expectedHead: [.makeResponse(status: .ok, for: .http3)],
                        expectedBody: []
                    )
                }
            }
        }
    }

    @Test("Writing a datagram larger than the max_datagram_frame_size fails")
    @available(anyAppleOS 26.2, *)
    func writingDatagramLargerThanMaxFrameSizeFails() async throws {
        let clientMaxDatagramFrameSize = 150

        var (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .http3,
            clientLogger: Self.clientLogger,
            serverLogger: Self.serverLogger
        )
        clientConfiguration.quicConfiguration = .makeClientQUICConfig(
            caPath: clientConfiguration.trustRootsPEMPath,
            maxDatagramFrameSize: clientMaxDatagramFrameSize
        )

        let streamOpenedPromise = server.eventLoopGroup.any().makePromise(of: Void.self)

        try await TestHelpers.withHTTP3ClientServerConnectionAndRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                streamOpenedPromise.succeed()

                var reader = reader
                var datagramReader = await reader.takeDatagramReader()!

                // Read the datagram.
                let collectedDatagram = try #require(await TestHelpers.readDatagram(&datagramReader))
                #expect(collectedDatagram == .init(buffer: .testData))

                // Try to write a datagram larger than 150 bytes.
                var writer = try await responseSender.send(.init(status: .ok))
                var datagramWriter = await writer.takeDatagramWriter()!

                let largerThanMaxFrameSize = [UInt8](repeating: 1, count: clientMaxDatagramFrameSize + 50)
                var bufferOne = UniqueArray<UInt8>(copying: largerThanMaxFrameSize.span)

                await #expect(throws: QUICError.datagramTooLarge) {
                    try await datagramWriter.write(buffer: &bufferOne)
                }

                // But writing a datagram whose size is within the limit should be successful.
                let smallerThanMaxFrameSize = [UInt8](repeating: 1, count: clientMaxDatagramFrameSize - 50)
                var bufferTwo = UniqueArray<UInt8>(copying: smallerThanMaxFrameSize.span)
                await #expect(throws: Never.self) {
                    try await datagramWriter.write(buffer: &bufferTwo)
                }

                try await writer.finish()
            }
        ) { _, streamID, connectionChannel, streamChannel in
            try await connectionChannel.executeThenClose { connectionInbound, connectionOutbound in
                try await streamChannel.executeThenClose { streamInbound, streamOutbound in
                    // Start the request.
                    try await streamOutbound.write(.testHead(method: .get, for: .http3))

                    // Wait for the stream to be opened.
                    try await streamOpenedPromise.futureResult.get()

                    // Write a datagram.
                    try await connectionOutbound.write(HTTP3Datagram(streamID: streamID, payload: .testData))

                    var inboundDatagramIterator = connectionInbound.makeAsyncIterator()

                    // Now read the smaller datagram the server sent (the larger one will have failed).
                    let collectedDatagram = try await inboundDatagramIterator.next()
                    #expect(collectedDatagram?.streamID == streamID)
                    #expect(collectedDatagram?.payload == .init(repeating: 1, count: clientMaxDatagramFrameSize - 50))

                    // Now end the request.
                    try await streamOutbound.write(.end(nil))

                    try await TestHelpers.validateResponse(
                        streamInbound,
                        expectedHead: [.makeResponse(status: .ok, for: .http3)],
                        expectedBody: []
                    )
                }
            }
        }
    }

    @Test("Datagram reader and writer not vended when client does not support datagrams")
    @available(anyAppleOS 26.2, *)
    func datagramReaderAndWriterNotVendedWhenNotSupportedByClient() async throws {
        var (server, clientConfiguration) = try TestHelpers.makeServerAndClientConfiguration(
            for: .http3,
            clientLogger: Self.clientLogger,
            serverLogger: Self.serverLogger
        )
        // The client advertises that it does not support receiving datagrams.
        clientConfiguration.quicConfiguration = .makeClientQUICConfig(
            caPath: clientConfiguration.trustRootsPEMPath,
            maxDatagramFrameSize: 0
        )
        clientConfiguration.http3ConnectionSettings = .init(h3Datagram: false)

        try await TestHelpers.withHTTP3ClientServerConnectionAndRequestChannel(
            clientConfiguration: clientConfiguration,
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, reader, responseSender in
                var reader = reader

                // The datagram reader and writer should not be available because the client does not support receiving
                // datagrams.
                let datagramReaderIsNotAvailable = await reader.takeDatagramReader() == nil
                #expect(datagramReaderIsNotAvailable)

                var reliableStreamWriter = try await responseSender.send(.init(status: .ok))
                let datagramWriterIsNotAvailable = await reliableStreamWriter.takeDatagramWriter() == nil
                #expect(datagramWriterIsNotAvailable)

                try await reliableStreamWriter.finish()
            }
        ) { _, streamID, connectionChannel, streamChannel in
            try await connectionChannel.executeThenClose { connectionInbound, connectionOutbound in
                try await streamChannel.executeThenClose { streamInbound, streamOutbound in
                    try await streamOutbound.write(.testHead(method: .post, for: .http3))
                    try await streamOutbound.write(.testBody)
                    try await streamOutbound.write(.end(nil))

                    try await TestHelpers.validateResponse(
                        streamInbound,
                        expectedHead: [.makeResponse(status: .ok, for: .http3)],
                        expectedBody: []
                    )
                }
            }
        }
    }
}
#endif  // HTTP3 && UnstableHTTPDatagrams
