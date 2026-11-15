import CoreGraphics
import Foundation

public enum CalibrationPass: String, Sendable, Equatable, Codable {
    case natural
    case eyesOnly
}

public struct CalibrationTarget: Sendable, Equatable, Codable {
    public var displayUUID: String
    public var u: Double
    public var v: Double
    public var pass: CalibrationPass

    public init(displayUUID: String, u: Double, v: Double, pass: CalibrationPass = .natural) {
        self.displayUUID = displayUUID
        self.u = u
        self.v = v
        self.pass = pass
    }
}

public struct CalibrationSample: Sendable, Equatable {
    public var target: CalibrationTarget
    public var features: GazeFeatures

    public init(target: CalibrationTarget, features: GazeFeatures) {
        self.target = target
        self.features = features
    }
}

public enum CalibrationError: Error, Sendable, Equatable, CustomStringConvertible {
    case tooFewTargets
    case collinearTargets
    case nonFinite
    case poorFit(Double)
    case insufficientSamples
    case solverFailed
    case emptyTopology

    public var description: String {
        switch self {
        case .tooFewTargets:
            return "Calibration requires at least 4 distinct targets per display"
        case .collinearTargets:
            return "Calibration targets are nearly collinear (hull area below 0.05)"
        case .nonFinite:
            return "Calibration samples contain a non-finite value"
        case .poorFit(let rms):
            return String(format: "Calibration leave-one-target-out RMS error %.3f exceeds 0.20", rms)
        case .insufficientSamples:
            return "Not enough valid calibration samples captured"
        case .solverFailed:
            return "Ridge regression Cholesky solver failed"
        case .emptyTopology:
            return "No active displays available for calibration"
        }
    }
}

public enum CalibrationSolver {
    public static let ridgeLambda: Double = 0.05
    public static let minHullArea: Double = 0.05
    public static let maxCrossValidationRMS: Double = 0.20
    public static let minHeadRangeRadians: Double = 0.02

    private struct TargetCoordKey: Hashable {
        let uBucket: Int64
        let vBucket: Int64

        init(u: Double, v: Double) {
            self.uBucket = Int64((u * 1_000_000.0).rounded())
            self.vBucket = Int64((v * 1_000_000.0).rounded())
        }
    }

    private struct TargetPassKey: Hashable {
        let coord: TargetCoordKey
        let pass: CalibrationPass
    }

    private struct ExtractedSample {
        let coord: TargetCoordKey
        let pass: CalibrationPass
        let u: Double
        let v: Double
        let yaw: Double
        let pitch: Double
        let eyeX: Double
        let eyeY: Double
    }

    private struct FittedWeights {
        let means: [Double]
        let stds: [Double]
        let weightsU: [Double]
        let weightsV: [Double]
        let headOnlyWeightsU: [Double]
        let headOnlyWeightsV: [Double]
        let centroid: [Double]
    }

    public static func solve(
        samples: [CalibrationSample],
        cameraUniqueID: String,
        createdAt: TimeInterval,
        config: Config = Config()
    ) -> Result<CalibrationProfile, CalibrationError> {
        guard createdAt.isFinite else { return .failure(.nonFinite) }
        guard !samples.isEmpty else { return .failure(.tooFewTargets) }

        for sample in samples {
            guard sample.target.u.isFinite,
                  sample.target.v.isFinite,
                  sample.features.yaw.isFinite,
                  sample.features.pitch.isFinite,
                  sample.features.roll.isFinite else {
                return .failure(.nonFinite)
            }
            if let ex = sample.features.eyeX, !ex.isFinite { return .failure(.nonFinite) }
            if let ey = sample.features.eyeY, !ey.isFinite { return .failure(.nonFinite) }
        }

        let byDisplay = Dictionary(grouping: samples, by: { $0.target.displayUUID })
        var models: [String: DisplayModel] = [:]
        var naturalPitches: [Double] = []
        var fallbackPitches: [Double] = []

        for (uuid, displaySamples) in byDisplay {
            switch solveDisplay(samples: displaySamples, config: config) {
            case .failure(let error):
                return .failure(error)
            case .success(let outcome):
                models[uuid] = outcome.model
                naturalPitches.append(contentsOf: outcome.naturalMedianPitches)
                fallbackPitches.append(contentsOf: outcome.allMedianPitches)
            }
        }

        let pitchDownLimit = naturalPitches.max() ?? fallbackPitches.max()
        let profile = CalibrationProfile(
            cameraUniqueID: cameraUniqueID,
            createdAt: createdAt,
            models: models,
            pitchDownLimit: pitchDownLimit
        )
        return .success(profile)
    }

    private struct DisplaySolveOutcome {
        let model: DisplayModel
        let naturalMedianPitches: [Double]
        let allMedianPitches: [Double]
    }

    private static func solveDisplay(
        samples: [CalibrationSample],
        config: Config
    ) -> Result<DisplaySolveOutcome, CalibrationError> {
        let hasAnyEye = samples.contains { $0.features.eyeX != nil && $0.features.eyeY != nil }
        let usable = samples.filter { sample in
            guard sample.features.faceCount == 1,
                  sample.features.confidence >= config.minConfidence else {
                return false
            }
            if hasAnyEye {
                return sample.features.eyeX != nil && sample.features.eyeY != nil
            }
            return true
        }

        let distinctCoords = Set(usable.map { TargetCoordKey(u: $0.target.u, v: $0.target.v) })
        guard distinctCoords.count >= 4 else {
            return .failure(.tooFewTargets)
        }

        let distinctPoints: [CGPoint] = Dictionary(
            grouping: usable,
            by: { TargetCoordKey(u: $0.target.u, v: $0.target.v) }
        ).values.compactMap { group in
            guard let first = group.first else { return nil }
            return CGPoint(x: first.target.u, y: first.target.v)
        }
        guard convexHullArea(points: distinctPoints) >= minHullArea else {
            return .failure(.collinearTargets)
        }

        let extracted: [ExtractedSample] = usable.map { sample in
            ExtractedSample(
                coord: TargetCoordKey(u: sample.target.u, v: sample.target.v),
                pass: sample.target.pass,
                u: sample.target.u,
                v: sample.target.v,
                yaw: sample.features.yaw,
                pitch: sample.features.pitch,
                eyeX: sample.features.eyeX ?? 0,
                eyeY: sample.features.eyeY ?? 0
            )
        }

        let filtered = rejectOutliersByMAD(extracted)
        let filteredDistinct = Set(filtered.map(\.coord))
        guard filteredDistinct.count >= 4 else {
            return .failure(.tooFewTargets)
        }

        let groupedByTargetPass = Dictionary(
            grouping: filtered,
            by: { TargetPassKey(coord: $0.coord, pass: $0.pass) }
        )

        var naturalMedianPitches: [Double] = []
        var allMedianPitches: [Double] = []
        var targetMedianYaws: [Double] = []
        var targetMedianPitches: [Double] = []

        for (key, group) in groupedByTargetPass {
            let medYaw = median(group.map(\.yaw))
            let medPitch = median(group.map(\.pitch))
            targetMedianYaws.append(medYaw)
            targetMedianPitches.append(medPitch)
            allMedianPitches.append(medPitch)
            if key.pass == .natural {
                naturalMedianPitches.append(medPitch)
            }
        }

        let yawRange = (targetMedianYaws.max() ?? 0) - (targetMedianYaws.min() ?? 0)
        let pitchRange = (targetMedianPitches.max() ?? 0) - (targetMedianPitches.min() ?? 0)
        let headBarelyMoved = (yawRange < minHeadRangeRadians && pitchRange < minHeadRangeRadians)

        // Leave-one-target-out cross-validation across distinct (u, v) coordinates.
        var squaredErrorSum = 0.0
        var cvCount = 0
        for heldOutCoord in filteredDistinct {
            let train = filtered.filter { $0.coord != heldOutCoord }
            let test = filtered.filter { $0.coord == heldOutCoord }
            guard !train.isEmpty, !test.isEmpty else { continue }
            guard let foldWeights = fitWeights(samples: train) else {
                return .failure(.solverFailed)
            }
            let byPass = Dictionary(grouping: test, by: \.pass)
            for passGroup in byPass.values {
                var sumU = 0.0
                var sumV = 0.0
                for item in passGroup {
                    let z0 = (item.yaw - foldWeights.means[0]) / foldWeights.stds[0]
                    let z1 = (item.pitch - foldWeights.means[1]) / foldWeights.stds[1]
                    let z2 = (item.eyeX - foldWeights.means[2]) / foldWeights.stds[2]
                    let z3 = (item.eyeY - foldWeights.means[3]) / foldWeights.stds[3]
                    sumU += foldWeights.weightsU[0]
                        + foldWeights.weightsU[1] * z0
                        + foldWeights.weightsU[2] * z1
                        + foldWeights.weightsU[3] * z2
                        + foldWeights.weightsU[4] * z3
                    sumV += foldWeights.weightsV[0]
                        + foldWeights.weightsV[1] * z0
                        + foldWeights.weightsV[2] * z1
                        + foldWeights.weightsV[3] * z2
                        + foldWeights.weightsV[4] * z3
                }
                let meanU = sumU / Double(passGroup.count)
                let meanV = sumV / Double(passGroup.count)
                let du = meanU - passGroup[0].u
                let dv = meanV - passGroup[0].v
                squaredErrorSum += du * du + dv * dv
                cvCount += 1
            }
        }

        guard cvCount > 0 else { return .failure(.insufficientSamples) }
        let cvRMS = sqrt(squaredErrorSum / Double(cvCount))
        guard cvRMS.isFinite else { return .failure(.nonFinite) }
        if cvRMS > maxCrossValidationRMS {
            return .failure(.poorFit(cvRMS))
        }

        guard let fullWeights = fitWeights(samples: filtered) else {
            return .failure(.solverFailed)
        }

        let model = DisplayModel(
            featureMeans: fullWeights.means,
            featureStds: fullWeights.stds,
            weightsU: fullWeights.weightsU,
            weightsV: fullWeights.weightsV,
            headOnlyWeightsU: fullWeights.headOnlyWeightsU,
            headOnlyWeightsV: fullWeights.headOnlyWeightsV,
            centroid: fullWeights.centroid,
            crossValidationError: cvRMS,
            sampleCount: filtered.count,
            headBarelyMoved: headBarelyMoved
        )

        if let validationErr = model.validate(displayUUID: "candidate") {
            switch validationErr {
            case .nonFiniteValue:
                return .failure(.nonFinite)
            case .invalidCrossValidationError(_, let err):
                return .failure(.poorFit(err))
            default:
                return .failure(.solverFailed)
            }
        }

        return .success(DisplaySolveOutcome(
            model: model,
            naturalMedianPitches: naturalMedianPitches,
            allMedianPitches: allMedianPitches
        ))
    }

    private static func fitWeights(samples: [ExtractedSample]) -> FittedWeights? {
        guard !samples.isEmpty else { return nil }
        let n = Double(samples.count)
        let yaws = samples.map(\.yaw)
        let pitches = samples.map(\.pitch)
        let eyeXs = samples.map(\.eyeX)
        let eyeYs = samples.map(\.eyeY)

        let meanYaw = yaws.reduce(0, +) / n
        let meanPitch = pitches.reduce(0, +) / n
        let meanEyeX = eyeXs.reduce(0, +) / n
        let meanEyeY = eyeYs.reduce(0, +) / n

        let stdYaw = max(standardDeviation(yaws, mean: meanYaw), 0.01)
        let stdPitch = max(standardDeviation(pitches, mean: meanPitch), 0.01)
        let stdEyeX = max(standardDeviation(eyeXs, mean: meanEyeX), 0.005)
        let stdEyeY = max(standardDeviation(eyeYs, mean: meanEyeY), 0.005)

        let means = [meanYaw, meanPitch, meanEyeX, meanEyeY]
        let stds = [stdYaw, stdPitch, stdEyeX, stdEyeY]

        var fullPhi: [[Double]] = []
        var headPhi: [[Double]] = []
        var uTargets: [Double] = []
        var vTargets: [Double] = []
        fullPhi.reserveCapacity(samples.count)
        headPhi.reserveCapacity(samples.count)
        uTargets.reserveCapacity(samples.count)
        vTargets.reserveCapacity(samples.count)

        for item in samples {
            let z0 = (item.yaw - meanYaw) / stdYaw
            let z1 = (item.pitch - meanPitch) / stdPitch
            let z2 = (item.eyeX - meanEyeX) / stdEyeX
            let z3 = (item.eyeY - meanEyeY) / stdEyeY
            fullPhi.append([1.0, z0, z1, z2, z3])
            headPhi.append([1.0, z0, z1])
            uTargets.append(item.u)
            vTargets.append(item.v)
        }

        guard let fullSolved = RidgeSolver.solveMulti(
            designMatrix: fullPhi,
            targetColumns: [uTargets, vTargets],
            lambda: ridgeLambda
        ),
              let headSolved = RidgeSolver.solveMulti(
            designMatrix: headPhi,
            targetColumns: [uTargets, vTargets],
            lambda: ridgeLambda
        ) else {
            return nil
        }

        // Centroid in standardised units across distinct targets
        let byCoord = Dictionary(grouping: samples, by: \.coord)
        var sumZ = [0.0, 0.0, 0.0, 0.0]
        for group in byCoord.values {
            let m0 = (median(group.map(\.yaw)) - meanYaw) / stdYaw
            let m1 = (median(group.map(\.pitch)) - meanPitch) / stdPitch
            let m2 = (median(group.map(\.eyeX)) - meanEyeX) / stdEyeX
            let m3 = (median(group.map(\.eyeY)) - meanEyeY) / stdEyeY
            sumZ[0] += m0
            sumZ[1] += m1
            sumZ[2] += m2
            sumZ[3] += m3
        }
        let targetCount = Double(max(byCoord.count, 1))
        let centroid = sumZ.map { $0 / targetCount }

        return FittedWeights(
            means: means,
            stds: stds,
            weightsU: fullSolved[0],
            weightsV: fullSolved[1],
            headOnlyWeightsU: headSolved[0],
            headOnlyWeightsV: headSolved[1],
            centroid: centroid
        )
    }

    private static func rejectOutliersByMAD(_ samples: [ExtractedSample]) -> [ExtractedSample] {
        let grouped = Dictionary(grouping: samples, by: { TargetPassKey(coord: $0.coord, pass: $0.pass) })
        var kept: [ExtractedSample] = []
        kept.reserveCapacity(samples.count)

        for group in grouped.values {
            guard group.count >= 3 else {
                kept.append(contentsOf: group)
                continue
            }
            let medYaw = median(group.map(\.yaw))
            let medPitch = median(group.map(\.pitch))
            let medEyeX = median(group.map(\.eyeX))
            let medEyeY = median(group.map(\.eyeY))

            let tolYaw = 3.0 * max(1.4826 * mad(group.map(\.yaw), around: medYaw), 0.025)
            let tolPitch = 3.0 * max(1.4826 * mad(group.map(\.pitch), around: medPitch), 0.025)
            let tolEyeX = 3.0 * max(1.4826 * mad(group.map(\.eyeX), around: medEyeX), 0.02)
            let tolEyeY = 3.0 * max(1.4826 * mad(group.map(\.eyeY), around: medEyeY), 0.02)

            let inliers = group.filter { item in
                abs(item.yaw - medYaw) <= tolYaw
                    && abs(item.pitch - medPitch) <= tolPitch
                    && abs(item.eyeX - medEyeX) <= tolEyeX
                    && abs(item.eyeY - medEyeY) <= tolEyeY
            }
            if inliers.isEmpty {
                kept.append(contentsOf: group)
            } else {
                kept.append(contentsOf: inliers)
            }
        }
        return kept
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return 0.5 * (sorted[mid - 1] + sorted[mid])
        }
        return sorted[mid]
    }

    private static func mad(_ values: [Double], around center: Double) -> Double {
        median(values.map { abs($0 - center) })
    }

    private static func standardDeviation(_ values: [Double], mean: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let variance = values.reduce(0.0) { acc, v in
            let d = v - mean
            return acc + d * d
        } / Double(values.count)
        return sqrt(max(variance, 0))
    }

    private static func convexHullArea(points: [CGPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        let sorted = points.sorted { a, b in
            if a.x != b.x { return a.x < b.x }
            return a.y < b.y
        }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
            Double((a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x))
        }

        var lower: [CGPoint] = []
        for p in sorted {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }

        var upper: [CGPoint] = []
        for p in sorted.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }

        let hull = Array(lower.dropLast()) + Array(upper.dropLast())
        guard hull.count >= 3 else { return 0 }

        var area2 = 0.0
        for i in 0..<hull.count {
            let p1 = hull[i]
            let p2 = hull[(i + 1) % hull.count]
            area2 += Double(p1.x * p2.y - p2.x * p1.y)
        }
        return abs(area2) * 0.5
    }
}
