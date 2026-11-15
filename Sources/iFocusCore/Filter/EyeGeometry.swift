import CoreGraphics
import Foundation

public enum EyeGeometry {
    public static func deRollAngle(leftContour: [CGPoint]?, rightContour: [CGPoint]?) -> Double {
        let validLeft = leftContour.flatMap { $0.isEmpty ? nil : $0 }
        let validRight = rightContour.flatMap { $0.isEmpty ? nil : $0 }

        var dx: Double = 0
        var dy: Double = 0

        if let lc = validLeft, let rc = validRight {
            let c1 = centroid(lc)
            let c2 = centroid(rc)
            dx = Double(c2.x - c1.x)
            dy = Double(c2.y - c1.y)
        } else if let single = validLeft ?? validRight, single.count >= 2 {
            var bestDistSq: Double = -1
            for i in 0..<single.count {
                for j in (i + 1)..<single.count {
                    let vx = Double(single[j].x - single[i].x)
                    let vy = Double(single[j].y - single[i].y)
                    let dSq = vx * vx + vy * vy
                    if dSq > bestDistSq {
                        bestDistSq = dSq
                        dx = vx
                        dy = vy
                    }
                }
            }
        } else {
            return 0
        }

        // Normalise to point toward +x so de-roll is invariant to eye ordering.
        if dx < 0 || (dx == 0 && dy < 0) {
            dx = -dx
            dy = -dy
        }
        guard hypot(dx, dy) > 1e-6 else { return 0 }
        let angle = atan2(dy, dx)
        return angle.isFinite ? angle : 0
    }

    public static func eyeOffset(
        leftContour: [CGPoint]?,
        leftPupil: [CGPoint]?,
        rightContour: [CGPoint]?,
        rightPupil: [CGPoint]?
    ) -> EyeOffset? {
        let angle = deRollAngle(leftContour: leftContour, rightContour: rightContour)
        let left = singleEyeOffset(contour: leftContour, pupil: leftPupil, angle: angle)
        let right = singleEyeOffset(contour: rightContour, pupil: rightPupil, angle: angle)

        switch (left, right) {
        case (.some(let l), .some(let r)):
            return EyeOffset(x: 0.5 * (l.x + r.x), y: 0.5 * (l.y + r.y))
        case (.some(let l), .none):
            return l
        case (.none, .some(let r)):
            return r
        case (.none, .none):
            return nil
        }
    }

    private static func singleEyeOffset(
        contour: [CGPoint]?,
        pupil: [CGPoint]?,
        angle: Double
    ) -> EyeOffset? {
        guard let contour, !contour.isEmpty, let pupil, !pupil.isEmpty else {
            return nil
        }

        let cosA = cos(-angle)
        let sinA = sin(-angle)

        func rotate(_ p: CGPoint) -> (x: Double, y: Double) {
            let x = Double(p.x)
            let y = Double(p.y)
            return (x * cosA - y * sinA, x * sinA + y * cosA)
        }

        var minX = Double.infinity
        var maxX = -Double.infinity
        var minY = Double.infinity
        var maxY = -Double.infinity

        for p in contour {
            let r = rotate(p)
            minX = min(minX, r.x)
            maxX = max(maxX, r.x)
            minY = min(minY, r.y)
            maxY = max(maxY, r.y)
        }

        let eyeWidth = maxX - minX
        let eyeHeight = maxY - minY
        guard eyeWidth > 1e-3, (eyeHeight / eyeWidth) >= 0.15 else {
            return nil
        }

        let centerX = 0.5 * (minX + maxX)
        let centerY = 0.5 * (minY + maxY)

        var sumPX = 0.0
        var sumPY = 0.0
        for p in pupil {
            let r = rotate(p)
            sumPX += r.x
            sumPY += r.y
        }
        let px = sumPX / Double(pupil.count)
        let py = sumPY / Double(pupil.count)

        let offX = (px - centerX) / eyeWidth
        let offY = (py - centerY) / eyeWidth
        guard offX.isFinite, offY.isFinite else { return nil }
        return EyeOffset(x: offX, y: offY)
    }

    private static func centroid(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        var sx: CGFloat = 0
        var sy: CGFloat = 0
        for p in points {
            sx += p.x
            sy += p.y
        }
        let n = CGFloat(points.count)
        return CGPoint(x: sx / n, y: sy / n)
    }
}
