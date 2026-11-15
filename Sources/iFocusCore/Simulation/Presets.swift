import CoreGraphics
import Foundation

public enum Rig {
    // Window IDs on deskThree
    public static let deskPortraitTopID: UInt32 = 101
    public static let deskPortraitBottomID: UInt32 = 102
    public static let deskMainLeftID: UInt32 = 103
    public static let deskMainRightID: UInt32 = 104
    public static let deskBuiltinTermID: UInt32 = 105
    public static let deskBrowserID: UInt32 = 106
    public static let deskMainRightTwinID: UInt32 = 107

    // Window IDs on dualExternal
    public static let dualLeftTopID: UInt32 = 201
    public static let dualLeftBottomID: UInt32 = 202
    public static let dualRightLeftID: UInt32 = 203
    public static let dualRightRightID: UInt32 = 204
    public static let dualLeftRightApp2ID: UInt32 = 205

    // Window IDs on mixedApps
    public static let mixedGhosttyID: UInt32 = 301
    public static let mixedChrome1ID: UInt32 = 302
    public static let mixedChrome2ID: UInt32 = 303
    public static let mixedSpotifyID: UInt32 = 304

    public static let deskThree: SimRig = {
        let main = SimDisplay(
            descriptor: DisplayDescriptor(
                id: 1,
                uuid: "disp-main",
                bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                physicalSizeMM: CGSize(width: 699, height: 389),
                isBuiltin: false,
                isMain: true
            ),
            centerMM: Vec3(x: 0, y: 0, z: 650),
            yawDegrees: 0,
            tiltBackDegrees: 0
        )

        let builtin = SimDisplay(
            descriptor: DisplayDescriptor(
                id: 2,
                uuid: "disp-builtin",
                bounds: CGRect(x: 1140, y: -1117, width: 1728, height: 1117),
                physicalSizeMM: CGSize(width: 344, height: 223),
                isBuiltin: true,
                isMain: false
            ),
            centerMM: Vec3(x: 120, y: -260, z: 410),
            yawDegrees: 12,
            tiltBackDegrees: 20
        )

        let portrait = SimDisplay(
            descriptor: DisplayDescriptor(
                id: 3,
                uuid: "disp-portrait",
                bounds: CGRect(x: -1152, y: -188, width: 1152, height: 2048),
                physicalSizeMM: CGSize(width: 340, height: 598),
                isBuiltin: false,
                isMain: false
            ),
            centerMM: Vec3(x: -620, y: 0, z: 540),
            yawDegrees: -35,
            tiltBackDegrees: 0
        )

        let windows: [WindowDescriptor] = [
            WindowDescriptor(
                windowID: deskPortraitTopID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: -1132, y: -168, width: 1112, height: 980),
                zIndex: 0
            ),
            WindowDescriptor(
                windowID: deskBrowserID,
                pid: 2001,
                bundleID: "com.apple.Safari",
                bounds: CGRect(x: 40, y: 60, width: 480, height: 480),
                zIndex: 1
            ),
            WindowDescriptor(
                windowID: deskPortraitBottomID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: -1132, y: 832, width: 1112, height: 1000),
                zIndex: 2
            ),
            WindowDescriptor(
                windowID: deskMainLeftID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: 20, y: 40, width: 1240, height: 1360),
                zIndex: 3
            ),
            WindowDescriptor(
                windowID: deskMainRightID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: 1300, y: 40, width: 1240, height: 1360),
                zIndex: 4
            ),
            WindowDescriptor(
                windowID: deskBuiltinTermID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: 1200, y: -1060, width: 1600, height: 1000),
                zIndex: 5
            ),
            WindowDescriptor(
                windowID: deskMainRightTwinID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: 1300, y: 40, width: 1240, height: 1360),
                zIndex: 6
            ),
        ]

        return SimRig(
            name: "desk-three",
            displays: [main, builtin, portrait],
            eyePositionMM: Vec3(x: 0, y: 0, z: 0),
            windows: windows
        )
    }()

    public static let dualExternal: SimRig = {
        let left = SimDisplay(
            descriptor: DisplayDescriptor(
                id: 10,
                uuid: "disp-left",
                bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
                physicalSizeMM: CGSize(width: 597, height: 336),
                isBuiltin: false,
                isMain: true
            ),
            centerMM: Vec3(x: -310, y: 0, z: 650),
            yawDegrees: -20,
            tiltBackDegrees: 0
        )

        let right = SimDisplay(
            descriptor: DisplayDescriptor(
                id: 11,
                uuid: "disp-right",
                bounds: CGRect(x: 2560, y: 0, width: 2560, height: 1440),
                physicalSizeMM: CGSize(width: 597, height: 336),
                isBuiltin: false,
                isMain: false
            ),
            centerMM: Vec3(x: 310, y: 0, z: 650),
            yawDegrees: 20,
            tiltBackDegrees: 0
        )

        let windows: [WindowDescriptor] = [
            WindowDescriptor(
                windowID: dualLeftTopID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: 20, y: 20, width: 1240, height: 680),
                zIndex: 0
            ),
            WindowDescriptor(
                windowID: dualLeftBottomID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: 20, y: 740, width: 1240, height: 680),
                zIndex: 1
            ),
            WindowDescriptor(
                windowID: dualLeftRightApp2ID,
                pid: 1002,
                bundleID: "com.apple.Terminal",
                bounds: CGRect(x: 1300, y: 20, width: 1240, height: 1400),
                zIndex: 2
            ),
            WindowDescriptor(
                windowID: dualRightLeftID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: 2580, y: 20, width: 1240, height: 1400),
                zIndex: 3
            ),
            WindowDescriptor(
                windowID: dualRightRightID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: 3860, y: 20, width: 1240, height: 1400),
                zIndex: 4
            ),
        ]

        return SimRig(
            name: "dual-external",
            displays: [left, right],
            eyePositionMM: Vec3(x: 0, y: 0, z: 0),
            windows: windows
        )
    }()

    public static let mixedApps: SimRig = {
        let windows: [WindowDescriptor] = [
            WindowDescriptor(
                windowID: mixedGhosttyID,
                pid: 1001,
                bundleID: "com.mitchellh.ghostty",
                bounds: CGRect(x: -1132, y: -168, width: 1112, height: 2000),
                zIndex: 0
            ),
            WindowDescriptor(
                windowID: mixedChrome1ID,
                pid: 3001,
                bundleID: "com.google.Chrome",
                bounds: CGRect(x: 20, y: 40, width: 1240, height: 1360),
                zIndex: 1
            ),
            WindowDescriptor(
                windowID: mixedChrome2ID,
                pid: 3001,
                bundleID: "com.google.Chrome",
                bounds: CGRect(x: 1300, y: 40, width: 1240, height: 1360),
                zIndex: 2
            ),
            WindowDescriptor(
                windowID: mixedSpotifyID,
                pid: 3002,
                bundleID: "com.spotify.client",
                bounds: CGRect(x: 1200, y: -1060, width: 1600, height: 1000),
                zIndex: 3
            ),
        ]

        return SimRig(
            name: "mixed-apps",
            displays: deskThree.displays,
            eyePositionMM: Vec3(x: 0, y: 0, z: 0),
            windows: windows
        )
    }()
}
