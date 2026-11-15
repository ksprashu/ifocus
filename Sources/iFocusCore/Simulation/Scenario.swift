import CoreGraphics
import Foundation

public enum ScenarioLookTarget: Sendable, Equatable {
    case window(UInt32)
    case globalPoint(CGPoint)
    case sweep(from: CGPoint, to: CGPoint, start: TimeInterval, end: TimeInterval)
    case worldPoint(Vec3)
    case noFace
}

public struct ScenarioSegment: Sendable, Equatable {
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var target: ScenarioLookTarget
    public var eyesOpen: Bool
    public var faceCount: Int
    public var confidence: Double

    public init(
        startTime: TimeInterval,
        endTime: TimeInterval,
        target: ScenarioLookTarget,
        eyesOpen: Bool = true,
        faceCount: Int = 1,
        confidence: Double = 0.95
    ) {
        self.startTime = startTime
        self.endTime = endTime
        self.target = target
        self.eyesOpen = eyesOpen
        self.faceCount = faceCount
        self.confidence = confidence
    }
}

public enum ScenarioInputEvent: Sendable, Equatable {
    case keyDown(at: TimeInterval)
    case flagsChanged(at: TimeInterval)
    case pointerMove(at: TimeInterval)
    case pointerClick(at: TimeInterval)
    case scroll(at: TimeInterval)
    case pointerButton(down: Bool, at: TimeInterval)
    case modifierHeld(Bool, at: TimeInterval)
    case paused(Bool, at: TimeInterval)
    case sessionActive(Bool, at: TimeInterval)
    case secureInput(Bool, at: TimeInterval)
}

public struct Scenario: Sendable, Equatable {
    public var name: String
    public var rig: SimRig
    public var initialFocusedWindowID: UInt32
    public var duration: TimeInterval
    public var fps: Double
    public var segments: [ScenarioSegment]
    public var inputEvents: [ScenarioInputEvent]
    public var expectedSwitches: [UInt32]
    public var noise: Bool

    public init(
        name: String,
        rig: SimRig,
        initialFocusedWindowID: UInt32,
        duration: TimeInterval,
        fps: Double = 20.0,
        segments: [ScenarioSegment],
        inputEvents: [ScenarioInputEvent] = [],
        expectedSwitches: [UInt32],
        noise: Bool = true
    ) {
        self.name = name
        self.rig = rig
        self.initialFocusedWindowID = initialFocusedWindowID
        self.duration = duration
        self.fps = fps
        self.segments = segments
        self.inputEvents = inputEvents
        self.expectedSwitches = expectedSwitches
        self.noise = noise
    }

    public static func deskThree60s() -> Scenario {
        // 60-second realistic desk session visiting all 5 terminals across 3 displays,
        // with typing bursts and brief glances, plus return visits.
        let segments: [ScenarioSegment] = [
            ScenarioSegment(startTime: 0.0, endTime: 4.0, target: .window(Rig.deskPortraitTopID)),
            ScenarioSegment(startTime: 4.0, endTime: 10.0, target: .window(Rig.deskPortraitBottomID)),
            ScenarioSegment(startTime: 10.0, endTime: 18.0, target: .window(Rig.deskMainLeftID)),
            ScenarioSegment(startTime: 18.0, endTime: 26.0, target: .window(Rig.deskMainRightID)),
            ScenarioSegment(startTime: 26.0, endTime: 35.0, target: .window(Rig.deskBuiltinTermID)),
            ScenarioSegment(startTime: 35.0, endTime: 43.0, target: .window(Rig.deskMainLeftID)),
            ScenarioSegment(startTime: 43.0, endTime: 51.0, target: .window(Rig.deskPortraitTopID)),
            ScenarioSegment(startTime: 51.0, endTime: 60.0, target: .window(Rig.deskMainRightID)),
        ]

        var inputs: [ScenarioInputEvent] = []
        // Type after switching into each window (well outside dwell windows)
        let burstStarts: [TimeInterval] = [6.0, 12.0, 20.0, 28.0, 37.0, 45.0, 53.0]
        for start in burstStarts {
            for k in 0..<8 {
                inputs.append(.keyDown(at: start + Double(k) * 0.15))
            }
        }

        let expected: [UInt32] = [
            Rig.deskPortraitBottomID,
            Rig.deskMainLeftID,
            Rig.deskMainRightID,
            Rig.deskBuiltinTermID,
            Rig.deskMainLeftID,
            Rig.deskPortraitTopID,
            Rig.deskMainRightID,
        ]

        return Scenario(
            name: "desk-three",
            rig: Rig.deskThree,
            initialFocusedWindowID: Rig.deskPortraitTopID,
            duration: 60.0,
            fps: 20.0,
            segments: segments,
            inputEvents: inputs,
            expectedSwitches: expected,
            noise: true
        )
    }

    public static func dualExternalSwitchBeforeTyping() -> Scenario {
        // T36: focused on top-left of left monitor, look at right half of right monitor,
        // start typing after 2.00 s -> switch must precede the first key.
        let segments: [ScenarioSegment] = [
            ScenarioSegment(startTime: 0.0, endTime: 3.0, target: .window(Rig.dualRightRightID)),
        ]
        let inputs: [ScenarioInputEvent] = [
            .keyDown(at: 2.00),
            .keyDown(at: 2.15),
            .keyDown(at: 2.30),
        ]
        return Scenario(
            name: "dual-external-before-typing",
            rig: Rig.dualExternal,
            initialFocusedWindowID: Rig.dualLeftTopID,
            duration: 3.0,
            fps: 20.0,
            segments: segments,
            inputEvents: inputs,
            expectedSwitches: [Rig.dualRightRightID],
            noise: true
        )
    }

    public static func dualExternalTypingThenQuiet() -> Scenario {
        // T37: typing starts at 150 ms while looking at right-right -> no switch during typing
        // or the 2.5 s quiet window; switch occurs after quiet window + 1.2 s fresh dwell (>= 5.05 s).
        let segments: [ScenarioSegment] = [
            ScenarioSegment(startTime: 0.0, endTime: 7.0, target: .window(Rig.dualRightRightID)),
        ]
        var inputs: [ScenarioInputEvent] = []
        var t = 0.15
        while t <= 1.35 + 1e-9 {
            inputs.append(.keyDown(at: t))
            t += 0.15
        }
        return Scenario(
            name: "dual-external-typing-then-quiet",
            rig: Rig.dualExternal,
            initialFocusedWindowID: Rig.dualLeftTopID,
            duration: 7.0,
            fps: 20.0,
            segments: segments,
            inputEvents: inputs,
            expectedSwitches: [Rig.dualRightRightID],
            noise: true
        )
    }

    public static func dualExternalMultiMonitorTour() -> Scenario {
        let segments: [ScenarioSegment] = [
            ScenarioSegment(startTime: 0.0, endTime: 2.0, target: .window(Rig.dualRightRightID)),
            ScenarioSegment(startTime: 2.0, endTime: 4.0, target: .window(Rig.dualLeftBottomID)),
            ScenarioSegment(startTime: 4.0, endTime: 6.0, target: .window(Rig.dualLeftRightApp2ID)),
            ScenarioSegment(startTime: 6.0, endTime: 8.0, target: .window(Rig.dualRightLeftID)),
            ScenarioSegment(startTime: 8.0, endTime: 10.0, target: .window(Rig.dualLeftTopID)),
        ]
        return Scenario(
            name: "dual-external",
            rig: Rig.dualExternal,
            initialFocusedWindowID: Rig.dualLeftTopID,
            duration: 10.0,
            fps: 20.0,
            segments: segments,
            inputEvents: [],
            expectedSwitches: [
                Rig.dualRightRightID,
                Rig.dualLeftBottomID,
                Rig.dualLeftRightApp2ID,
                Rig.dualRightLeftID,
                Rig.dualLeftTopID,
            ],
            noise: true
        )
    }

    public static func dualExternalFlyover() -> Scenario {
        // T44: sweep across 3 intermediate terminals (leftTop -> leftRightApp2 -> rightLeft -> rightRight) in 250 ms.
        let startPt = CGPoint(x: 640, y: 360)   // dualLeftTop
        let endPt = CGPoint(x: 4480, y: 720)    // dualRightRight
        let segments: [ScenarioSegment] = [
            ScenarioSegment(startTime: 0.0, endTime: 0.40, target: .window(Rig.dualLeftTopID)),
            ScenarioSegment(startTime: 0.40, endTime: 0.65, target: .sweep(from: startPt, to: endPt, start: 0.40, end: 0.65)),
            ScenarioSegment(startTime: 0.65, endTime: 2.50, target: .window(Rig.dualRightRightID)),
        ]
        return Scenario(
            name: "dual-external-flyover",
            rig: Rig.dualExternal,
            initialFocusedWindowID: Rig.dualLeftTopID,
            duration: 2.50,
            fps: 20.0,
            segments: segments,
            inputEvents: [],
            expectedSwitches: [Rig.dualRightRightID],
            noise: false
        )
    }

    public static func mixedAppsTour() -> Scenario {
        // T89: Ghostty -> Spotify (cross-PID) -> Chrome 2 (cross-PID) -> Chrome 1 (same-PID) -> Ghostty (cross-PID).
        let segments: [ScenarioSegment] = [
            ScenarioSegment(startTime: 0.0, endTime: 2.0, target: .window(Rig.mixedGhosttyID)),
            ScenarioSegment(startTime: 2.0, endTime: 5.0, target: .window(Rig.mixedSpotifyID)),
            ScenarioSegment(startTime: 5.0, endTime: 8.0, target: .window(Rig.mixedChrome2ID)),
            ScenarioSegment(startTime: 8.0, endTime: 11.0, target: .window(Rig.mixedChrome1ID)),
            ScenarioSegment(startTime: 11.0, endTime: 14.0, target: .window(Rig.mixedGhosttyID)),
        ]
        return Scenario(
            name: "mixed-apps-tour",
            rig: Rig.mixedApps,
            initialFocusedWindowID: Rig.mixedGhosttyID,
            duration: 14.0,
            fps: 20.0,
            segments: segments,
            inputEvents: [],
            expectedSwitches: [
                Rig.mixedSpotifyID,
                Rig.mixedChrome2ID,
                Rig.mixedChrome1ID,
                Rig.mixedGhosttyID,
            ],
            noise: true
        )
    }

    public static func mixedAppsTypingWhileReading() -> Scenario {
        // T90: 10 s typing in Ghostty while reading Chrome, 1.5 s pause, 0.9 s more typing, then idle.
        let segments: [ScenarioSegment] = [
            ScenarioSegment(startTime: 0.0, endTime: 18.0, target: .window(Rig.mixedChrome1ID)),
        ]
        var inputs: [ScenarioInputEvent] = []
        var t = 0.0
        while t <= 10.0 + 1e-9 {
            inputs.append(.keyDown(at: t))
            t += 0.15
        }
        t = 11.50
        while t <= 12.40 + 1e-9 {
            inputs.append(.keyDown(at: t))
            t += 0.15
        }
        return Scenario(
            name: "mixed-apps-typing-while-reading",
            rig: Rig.mixedApps,
            initialFocusedWindowID: Rig.mixedGhosttyID,
            duration: 18.0,
            fps: 20.0,
            segments: segments,
            inputEvents: inputs,
            expectedSwitches: [Rig.mixedChrome1ID],
            noise: true
        )
    }

    public static func dualExternalTypeTooSoon() -> Scenario {
        // T91: typing begins 0.6 s after gaze lands and runs 5 s -> zero switches (look-then-type trade-off).
        let segments: [ScenarioSegment] = [
            ScenarioSegment(startTime: 0.0, endTime: 6.5, target: .window(Rig.dualRightRightID)),
        ]
        var inputs: [ScenarioInputEvent] = []
        var t = 0.60
        while t <= 5.60 + 1e-9 {
            inputs.append(.keyDown(at: t))
            t += 0.15
        }
        return Scenario(
            name: "dual-external-type-too-soon",
            rig: Rig.dualExternal,
            initialFocusedWindowID: Rig.dualLeftTopID,
            duration: 6.5,
            fps: 20.0,
            segments: segments,
            inputEvents: inputs,
            expectedSwitches: [],
            noise: true
        )
    }
}
