import Foundation

public enum Watched<Element: Sendable>: Sendable {
    case event(Element)
    case stalled
}

public struct WatchedStream<Element: Sendable>: Sendable {
    private actor State {
        private var lastEventTime: TimeInterval
        private var finished = false

        init(startAt: TimeInterval) {
            self.lastEventTime = startAt
        }

        func recordEvent(at now: TimeInterval) -> Bool {
            guard !finished else { return false }
            lastEventTime = now
            return true
        }

        func finishIfLive() -> Bool {
            guard !finished else { return false }
            finished = true
            return true
        }

        func stallIfTimedOut(now: TimeInterval, timeout: TimeInterval) -> (stalled: Bool, alreadyFinished: Bool) {
            if finished {
                return (false, true)
            }
            if (now - lastEventTime) + 1e-9 >= timeout {
                finished = true
                return (true, true)
            }
            return (false, false)
        }
    }

    public let stream: AsyncStream<Watched<Element>>
    private let continuation: AsyncStream<Watched<Element>>.Continuation
    private let state: State
    private let forwardTask: Task<Void, Never>
    private let watchdogTask: Task<Void, Never>

    public init(
        source: AsyncStream<Element>,
        timeout: TimeInterval,
        clock: any MonotonicClock,
        sleeper: any Sleeper,
        pollInterval: TimeInterval = 0.5
    ) {
        let (outStream, outCont) = AsyncStream.makeStream(of: Watched<Element>.self, bufferingPolicy: .unbounded)
        let state = State(startAt: clock.now())

        let forward = Task {
            for await item in source {
                if Task.isCancelled { break }
                if await state.recordEvent(at: clock.now()) {
                    outCont.yield(.event(item))
                }
            }
            if await state.finishIfLive() {
                outCont.finish()
            }
        }

        let watchdog = Task {
            let safePoll = max(pollInterval, 0.01)
            while !Task.isCancelled {
                await sleeper.sleep(seconds: safePoll)
                if Task.isCancelled { break }
                let verdict = await state.stallIfTimedOut(now: clock.now(), timeout: timeout)
                if verdict.stalled {
                    outCont.yield(.stalled)
                    outCont.finish()
                    break
                }
                if verdict.alreadyFinished {
                    break
                }
            }
        }

        outCont.onTermination = { _ in
            forward.cancel()
            watchdog.cancel()
        }

        self.stream = outStream
        self.continuation = outCont
        self.state = state
        self.forwardTask = forward
        self.watchdogTask = watchdog
    }

    public func cancel() {
        forwardTask.cancel()
        watchdogTask.cancel()
        let cont = continuation
        let st = state
        Task {
            _ = await st.finishIfLive()
            cont.finish()
        }
        cont.finish()
    }
}
