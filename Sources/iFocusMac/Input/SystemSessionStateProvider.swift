import AppKit
import CoreGraphics
import Foundation
import os
import iFocusCore

public final class SystemSessionStateProvider: SessionStateProvider, Sendable {
    private struct InternalState {
        var systemSleeping: Bool = false
        var displaysSleeping: Bool = false
        var cachedActive: Bool
        var lastQueryTime: TimeInterval
        var lastPublishedActive: Bool
    }

    private let stateLock: OSAllocatedUnfairLock<InternalState>
    private let continuationsLock = OSAllocatedUnfairLock<[UUID: AsyncStream<Bool>.Continuation]>(initialState: [:])
    private let clock: any MonotonicClock
    private let queryCacheTTL: TimeInterval = 0.25

    @MainActor
    private var tokens: [NSObjectProtocol] = []
    @MainActor
    private var heartbeatTask: Task<Void, Never>?

    public init(clock: any MonotonicClock = SystemClock()) {
        self.clock = clock
        let now = clock.now()
        let initialSignals = Self.readSignals(systemSleeping: false, displaysSleeping: false)
        let initialActive = SessionActivity.isActive(initialSignals)
        self.stateLock = OSAllocatedUnfairLock(initialState: InternalState(
            systemSleeping: false,
            displaysSleeping: false,
            cachedActive: initialActive,
            lastQueryTime: now,
            lastPublishedActive: initialActive
        ))
    }

    @MainActor
    public func startObserving() {
        guard tokens.isEmpty else { return }
        let wsCenter = NSWorkspace.shared.notificationCenter
        let distCenter = DistributedNotificationCenter.default()

        tokens.append(wsCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.updateSleepFlags(systemSleeping: true, displaysSleeping: nil)
        })
        tokens.append(wsCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.updateSleepFlags(systemSleeping: false, displaysSleeping: nil)
        })
        tokens.append(wsCenter.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.updateSleepFlags(systemSleeping: nil, displaysSleeping: true)
        })
        tokens.append(wsCenter.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.updateSleepFlags(systemSleeping: nil, displaysSleeping: false)
        })

        // Treat session / distributed lock notifications purely as triggers to re-query WindowServer.
        for name in [NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            tokens.append(wsCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                _ = self?.refreshNow()
            })
        }
        for rawName in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            tokens.append(distCenter.addObserver(forName: Notification.Name(rawName), object: nil, queue: nil) { [weak self] _ in
                _ = self?.refreshNow()
            })
        }

        _ = refreshNow()
        ensureHeartbeatIfInactive()
    }

    @MainActor
    public func stopObserving() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let wsCenter = NSWorkspace.shared.notificationCenter
        let distCenter = DistributedNotificationCenter.default()
        for token in tokens {
            wsCenter.removeObserver(token)
            distCenter.removeObserver(token)
        }
        tokens.removeAll()
    }

    public func isSessionActive() -> Bool {
        let now = clock.now()
        let cached = stateLock.withLock { st -> Bool? in
            if (now - st.lastQueryTime) < queryCacheTTL {
                return st.cachedActive
            }
            return nil
        }
        if let cached {
            return cached
        }
        return refreshNow()
    }

    public func updates() -> AsyncStream<Bool> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(8))
        continuation.onTermination = { [weak self] _ in
            self?.continuationsLock.withLock { _ = $0.removeValue(forKey: id) }
        }
        continuationsLock.withLock { $0[id] = continuation }
        return stream
    }

    private func updateSleepFlags(systemSleeping: Bool?, displaysSleeping: Bool?) {
        let flags = stateLock.withLock { st -> (Bool, Bool) in
            if let s = systemSleeping { st.systemSleeping = s }
            if let d = displaysSleeping { st.displaysSleeping = d }
            return (st.systemSleeping, st.displaysSleeping)
        }
        let signals = Self.readSignals(systemSleeping: flags.0, displaysSleeping: flags.1)
        applyActive(SessionActivity.isActive(signals))
    }

    @discardableResult
    private func refreshNow() -> Bool {
        let flags = stateLock.withLock { st in (st.systemSleeping, st.displaysSleeping) }
        let signals = Self.readSignals(systemSleeping: flags.0, displaysSleeping: flags.1)
        let active = SessionActivity.isActive(signals)
        applyActive(active)
        return active
    }

    private func applyActive(_ active: Bool) {
        let now = clock.now()
        let shouldPublish = stateLock.withLock { st -> Bool in
            st.cachedActive = active
            st.lastQueryTime = now
            guard st.lastPublishedActive != active else { return false }
            st.lastPublishedActive = active
            return true
        }
        if shouldPublish {
            let snapshot = continuationsLock.withLock { Array($0.values) }
            for cont in snapshot {
                cont.yield(active)
            }
        }
        Task { @MainActor [weak self] in
            self?.syncHeartbeat(active: active)
        }
    }

    @MainActor
    private func ensureHeartbeatIfInactive() {
        let active = isSessionActive()
        syncHeartbeat(active: active)
    }

    @MainActor
    private func syncHeartbeat(active: Bool) {
        if active {
            heartbeatTask?.cancel()
            heartbeatTask = nil
        } else if heartbeatTask == nil && !tokens.isEmpty {
            heartbeatTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    guard !Task.isCancelled, let self else { break }
                    if self.refreshNow() {
                        break
                    }
                }
            }
        }
    }

    public static func readSignals(systemSleeping: Bool, displaysSleeping: Bool) -> SessionSignals {
        guard let cfDict = CGSessionCopyCurrentDictionary(),
              let dict = cfDict as? [String: Any] else {
            return SessionSignals(
                dictionaryAvailable: false,
                onConsole: false,
                screenLocked: true,
                systemSleeping: systemSleeping,
                displaysSleeping: displaysSleeping
            )
        }
        let onConsole = (dict[kCGSessionOnConsoleKey as String] as? Bool) ?? true
        let screenLocked = (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
        return SessionSignals(
            dictionaryAvailable: true,
            onConsole: onConsole,
            screenLocked: screenLocked,
            systemSleeping: systemSleeping,
            displaysSleeping: displaysSleeping
        )
    }
}
