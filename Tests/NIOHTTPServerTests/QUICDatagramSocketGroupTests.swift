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

#if HTTP3
import Logging
import NIOCore
import NIOPosix
import NIOQUIC
import Synchronization
import Testing

@_spi(QUICDatagramSockets) @testable import NIOHTTPServer

extension Trait where Self == ConditionTrait {
    /// Gates tests that bind a socket group, which needs the singleton MTELG to have more than one event loop.
    // TODO: Remove this when NIOHTTPServer takes an event loop group and these tests can pass their own MTELG.
    static var requiresSeveralEventLoops: Self {
        .enabled(
            if: NIOSingletons.groupLoopCountSuggestion > 1,
            "the server uses the NIO singleton event loop group, which has only one loop on this host"
        )
    }
}

@Suite
struct QUICDatagramSocketGroupTests {
    let serverLogger = Logger(label: "QUICDatagramSocketGroupTests.server")

    @available(anyAppleOS 27.0, *)
    @Test(
        "Every socket in the group is bound once, with indices from zero, each on its own event loop",
        .requiresSeveralEventLoops
    )
    func testSocketGroupBindsEachSocketOnceOnItsOwnEventLoop() async throws {
        let socketGroup = RecordingSocketGroup(socketCount: 2)
        let factory = QUICDatagramSocketGroupFactory { _, _ in socketGroup }

        try await self.withHTTP3Server(socketGroupFactory: factory) { addresses in
            #expect(addresses.count == 1)

            var boundSockets: [(index: Int, eventLoop: ObjectIdentifier)] = []
            for await boundSocket in socketGroup.boundSockets {
                boundSockets.append(boundSocket)
                if boundSockets.count == socketGroup.socketCount { break }
            }

            #expect(boundSockets.map(\.index).sorted() == [0, 1])
            #expect(Set(boundSockets.map(\.eventLoop)).count == 2)
            #expect(socketGroup.connectionIDGeneratorIndices.sorted() == [0, 1])
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test("Multiple HTTP/3 sockets per bind target report one address each", .requiresSeveralEventLoops)
    func testMultipleHTTP3SocketsPerBindTargetReportOneAddressEach() async throws {
        let factory = QUICDatagramSocketGroupFactory { _, _ in RecordingSocketGroup(socketCount: 2) }

        try await self.withHTTP3Server(bindTargetCount: 2, socketGroupFactory: factory) { addresses in
            #expect(addresses.count == 2)

            let ports = try addresses.map { try #require($0.ipv4).port }
            #expect(ports.allSatisfy { $0 != 0 })
            #expect(Set(ports).count == 2)
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test("A group of one socket is still told it bound and still vends its generator")
    func testGroupOfOneSocketIsToldItBoundAndVendsItsGenerator() async throws {
        let socketGroup = RecordingSocketGroup(socketCount: 1)
        let factory = QUICDatagramSocketGroupFactory { _, _ in socketGroup }

        try await self.withHTTP3Server(socketGroupFactory: factory) { addresses in
            #expect(addresses.count == 1)

            var boundSocketIndices: [Int] = []
            for await boundSocket in socketGroup.boundSockets {
                boundSocketIndices.append(boundSocket.index)
                break
            }

            #expect(boundSocketIndices == [0])
            #expect(socketGroup.connectionIDGeneratorIndices == [0])
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test("Each bind target gets its own socket group", .requiresSeveralEventLoops)
    func testEachBindTargetGetsItsOwnSocketGroup() async throws {
        let socketGroups = Mutex<[RecordingSocketGroup]>([])
        let factory = QUICDatagramSocketGroupFactory { _, _ in
            let socketGroup = RecordingSocketGroup(socketCount: 2)
            socketGroups.withLock { $0.append(socketGroup) }
            return socketGroup
        }

        try await self.withHTTP3Server(bindTargetCount: 2, socketGroupFactory: factory) { addresses in
            #expect(addresses.count == 2)

            let built = socketGroups.withLock { $0 }
            #expect(built.count == 2)
            #expect(ObjectIdentifier(built[0]) != ObjectIdentifier(built[1]))
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test("A group need implement only the bound-socket hook", .requiresSeveralEventLoops)
    func testGroupNeedImplementOnlyTheBoundSocketHook() async throws {
        let factory = QUICDatagramSocketGroupFactory { _, _ in MinimalSocketGroup() }

        try await self.withHTTP3Server(socketGroupFactory: factory) { addresses in
            #expect(addresses.count == 1)
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test("Bind targets without a socket group spread across event loops", .requiresSeveralEventLoops)
    func testBindTargetsWithoutASocketGroupSpreadAcrossEventLoops() throws {
        let (configuration, _) = try TestHelpers.makeTLSServerConfiguration(
            supportedHTTPVersions: [.http3(config: .defaults)]
        )
        let server = NIOHTTPServer(logger: self.serverLogger, configuration: configuration)
        // The server is never served, so its listening-address promise has to be completed by hand or NIO
        // traps on the leak when it deinitialises.
        defer { server.addressesBound([]) }

        let first = try server.resolveHTTP3Listeners(using: nil)
        let second = try server.resolveHTTP3Listeners(using: nil)

        #expect(first.eventLoops.count == 1)
        #expect(second.eventLoops.count == 1)
        #expect(first.eventLoops[0] !== second.eventLoops[0])
    }

    @available(anyAppleOS 27.0, *)
    @Test("A socket count outside the available event loops fails server bootstrap")
    func testSocketCountOutsideAvailableEventLoopsFailsServerStart() throws {
        let (configuration, _) = try TestHelpers.makeTLSServerConfiguration(
            supportedHTTPVersions: [.http3(config: .defaults)]
        )
        let server = NIOHTTPServer(logger: self.serverLogger, configuration: configuration)
        // The server is never served, so its listening-address promise has to be completed by hand or NIO
        // traps on the leak when it deinitialises.
        defer { server.addressesBound([]) }

        let available = NIOSingletons.groupLoopCountSuggestion

        for requested in [0, available + 1] {
            let factory = QUICDatagramSocketGroupFactory { _, _ in RecordingSocketGroup(socketCount: requested) }
            let expected = NIOHTTPServerConfigurationError.datagramSocketGroupCountOutOfRange(
                requested: requested,
                available: available
            )
            #expect(throws: expected) { try server.resolveHTTP3Listeners(using: factory) }
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test("A factory that declines binds a single socket")
    func testDecliningFactoryBindsASingleSocket() async throws {
        let availableEventLoops = Mutex(0)
        let factory = QUICDatagramSocketGroupFactory { eventLoops, _ in
            availableEventLoops.withLock { $0 = eventLoops }
            return nil
        }

        try await self.withHTTP3Server(socketGroupFactory: factory) { addresses in
            #expect(addresses.count == 1)
        }

        #expect(availableEventLoops.withLock { $0 } == NIOSingletons.groupLoopCountSuggestion)
    }

    @available(anyAppleOS 27.0, *)
    @Test("A factory that throws fails server bootstrap")
    func testThrowingFactoryFailsServerStart() async throws {
        let factory = QUICDatagramSocketGroupFactory { _, _ in throw SocketGroupTestError() }

        await #expect(throws: SocketGroupTestError.self) {
            try await self.withHTTP3Server(socketGroupFactory: factory) { _ in }
        }
    }

    @available(anyAppleOS 27.0, *)
    @Test(
        "A socket group that throws in bind callback fails server bootstrap",
        .requiresSeveralEventLoops,
        .timeLimit(.minutes(1))
    )
    func testRejectingABoundSocketFailsServerStart() async throws {
        let factory = QUICDatagramSocketGroupFactory { _, _ in
            RecordingSocketGroup(socketCount: 2, failsOnSocketBound: true)
        }

        await #expect(throws: SocketGroupTestError.self) {
            try await self.withHTTP3Server(socketGroupFactory: factory) { _ in }
        }
    }

    /// Serves HTTP/3 on `bindTargetCount` ephemeral ports with `socketGroupFactory`, runs `body` with the
    /// listening addresses, then cancels the server.
    @available(anyAppleOS 27.0, *)
    private func withHTTP3Server(
        bindTargetCount: Int = 1,
        socketGroupFactory: QUICDatagramSocketGroupFactory,
        body: ([NIOHTTPServer.SocketAddress]) async throws -> Void
    ) async throws {
        var http3Configuration = NIOHTTPServerConfiguration.HTTP3.defaults
        http3Configuration.quicConfiguration.datagramSocketGroupFactory = socketGroupFactory

        let (configuration, _) = try TestHelpers.makeTLSServerConfiguration(
            supportedHTTPVersions: [.http3(config: http3Configuration)],
            concurrentListeners: bindTargetCount
        )
        let server = NIOHTTPServer(logger: self.serverLogger, configuration: configuration)

        try await TestHelpers.withServer(
            server: server,
            serverHandler: HTTPServerClosureRequestHandler { _, _, _, _ in },
            body: body
        )
    }
}

struct SocketGroupTestError: Error {}

/// A group implementing only the protocol's requirements, using the default implementations of other methods.
@available(anyAppleOS 27.0, *)
final class MinimalSocketGroup: QUICDatagramSocketGroup {
    let socketCount = 2

    func socketBound(_ socket: NIOBSDSocket.Handle, socketIndex: Int) throws {}
}

/// A socket group that records what the server asked it to do.
@available(anyAppleOS 27.0, *)
final class RecordingSocketGroup: QUICDatagramSocketGroup {
    let socketCount: Int

    let boundSockets: AsyncStream<(index: Int, eventLoop: ObjectIdentifier)>

    private let boundSocketContinuation: AsyncStream<(index: Int, eventLoop: ObjectIdentifier)>.Continuation
    private let failsOnSocketBound: Bool
    private let generatorIndices = Mutex<[Int]>([])

    var connectionIDGeneratorIndices: [Int] {
        self.generatorIndices.withLock { $0 }
    }

    init(socketCount: Int, failsOnSocketBound: Bool = false) {
        self.socketCount = socketCount
        self.failsOnSocketBound = failsOnSocketBound
        (self.boundSockets, self.boundSocketContinuation) = AsyncStream.makeStream(
            of: (index: Int, eventLoop: ObjectIdentifier).self
        )
    }

    func socketBound(_ socket: NIOBSDSocket.Handle, socketIndex: Int) throws {
        if self.failsOnSocketBound { throw SocketGroupTestError() }
        guard let eventLoop = MultiThreadedEventLoopGroup.currentEventLoop else {
            preconditionFailure("socketBound was not called on a NIO event loop")
        }
        self.boundSocketContinuation.yield((index: socketIndex, eventLoop: ObjectIdentifier(eventLoop)))
    }

    func makeConnectionIDGenerator(socketIndex: Int) -> any QUICConnectionID.Generator {
        self.generatorIndices.withLock { $0.append(socketIndex) }
        return QUICConnectionID.RandomGenerator()
    }
}
#endif  // HTTP3
