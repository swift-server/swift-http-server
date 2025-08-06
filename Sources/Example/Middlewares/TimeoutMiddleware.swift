import Middleware

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct TimeoutMiddleware<Input>: Middleware {
    func intercept(input: Input, next: (Input) async throws -> Void) async throws {
        try await withoutActuallyEscaping(next) { next in
            try await withTimeout(in: .seconds(10), clock: .continuous) {
                try await next(input)
            }
        }
    }
}

private enum TaskResult<T: Sendable>: Sendable {
    case success(T)
    case error(any Error)
    case timedOut
    case cancelled
}

package struct TimeOutError: Error {
    var underlying: any Error
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public func withTimeout<T: Sendable, Clock: _Concurrency.Clock>(
    in timeout: Clock.Duration,
    clock: Clock,
    isolation: isolated (any Actor)? = #isolation,
    body: @escaping () async throws -> T
) async throws -> T {
    nonisolated(unsafe) let bodyFunc = { body }
    let result: Result<T, any Error> = await withTaskGroup(of: TaskResult<T>.self) { group in
        let body = bodyFunc()
        group.addTask {
            do {
                return .success(try await body())
            } catch {
                return .error(error)
            }
        }
        group.addTask {
            do {
                try await clock.sleep(for: timeout, tolerance: .zero)
                return .timedOut
            } catch {
                return .cancelled
            }
        }

        switch await group.next() {
        case .success(let result):
            // Work returned a result. Cancel the timer task and return
            group.cancelAll()
            return .success(result)
        case .error(let error):
            // Work threw. Cancel the timer task and rethrow
            group.cancelAll()
            return .failure(error)
        case .timedOut:
            // Timed out, cancel the work task.
            group.cancelAll()

            switch await group.next() {
            case .success(let result):
                return .success(result)
            case .error(let error):
                return .failure(TimeOutError(underlying: error))
            case .timedOut, .cancelled, .none:
                // We already got a result from the sleeping task so we can't get another one or none.
                fatalError("Unexpected task result")
            }
        case .cancelled:
            switch await group.next() {
            case .success(let result):
                return .success(result)
            case .error(let error):
                return .failure(TimeOutError(underlying: error))
            case .timedOut, .cancelled, .none:
                // We already got a result from the sleeping task so we can't get another one or none.
                fatalError("Unexpected task result")
            }
        case .none:
            fatalError("Unexpected task result")
        }
    }
    return try result.get()
}
