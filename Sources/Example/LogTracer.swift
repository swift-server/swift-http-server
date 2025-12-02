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

import Tracing

struct LogTracer: Tracer {
    typealias Span = NoOpSpan

    init() {}

    func startAnySpan<Instant: TracerInstant>(
        _ operationName: String,
        context: @autoclosure () -> ServiceContext,
        ofKind kind: SpanKind,
        at instant: @autoclosure () -> Instant,
        function: String,
        file fileID: String,
        line: UInt
    ) -> any Tracing.Span {
        print("Starting span")
        return NoOpSpan(context: context())
    }

    func forceFlush() {
        print("Flushing")
    }

    func inject<Carrier, Inject>(_ context: ServiceContext, into carrier: inout Carrier, using injector: Inject)
    where Inject: Injector, Carrier == Inject.Carrier {
        // no-op
    }

    func extract<Carrier, Extract>(
        _ carrier: Carrier,
        into context: inout ServiceContext,
        using extractor: Extract
    )
    where Extract: Extractor, Carrier == Extract.Carrier {
        // no-op
    }

    struct NoOpSpan: Tracing.Span {
        let context: ServiceContext
        var isRecording: Bool {
            false
        }

        var operationName: String {
            get {
                "noop"
            }
            nonmutating set {
                // ignore
            }
        }

        init(context: ServiceContext) {
            self.context = context
        }

        func setStatus(_ status: SpanStatus) {}

        func addLink(_ link: SpanLink) {}

        func addEvent(_ event: SpanEvent) {}

        func recordError<Instant: TracerInstant>(
            _ error: any Error,
            attributes: SpanAttributes,
            at instant: @autoclosure () -> Instant
        ) {}

        var attributes: SpanAttributes {
            get {
                [:]
            }
            nonmutating set {
                // ignore
            }
        }

        func end<Instant: TracerInstant>(at instant: @autoclosure () -> Instant) {
            print("Ending span")
        }
    }
}
