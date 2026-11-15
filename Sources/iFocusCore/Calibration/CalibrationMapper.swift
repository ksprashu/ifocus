import CoreGraphics
import Foundation

public enum CalibrationMapper {
    private struct DisplayProjection {
        let display: DisplayDescriptor
        let u: Double
        let v: Double
        let dxMM: Double
        let overTopMM: Double
        let overBottomMM: Double
        let distMM: Double
        let centroidDistSq: Double
        let usedHeadOnly: Bool
    }

    public static func map(
        _ features: ConditionedFeatures,
        topology: DisplayTopology,
        profile: CalibrationProfile?,
        previousDisplayUUID: String?,
        config: Config
    ) -> GazeObservation {
        if topology.displays.isEmpty {
            return .offScreen
        }
        guard let profile else {
            return .uncalibrated
        }

        let calibratedPairs: [(DisplayDescriptor, DisplayModel)] = topology.displays.compactMap { display in
            guard let model = profile.models[display.uuid] else { return nil }
            return (display, model)
        }
        guard !calibratedPairs.isEmpty else {
            return .uncalibrated
        }

        guard features.yaw.isFinite, features.pitch.isFinite else {
            return .noFace
        }

        let useHeadOnly = (features.eye == nil)
        var projections: [DisplayProjection] = []
        projections.reserveCapacity(calibratedPairs.count)

        for (display, model) in calibratedPairs {
            let zYaw = (features.yaw - model.featureMeans[0]) / model.featureStds[0]
            let zPitch = (features.pitch - model.featureMeans[1]) / model.featureStds[1]

            let u: Double
            let v: Double
            let centroidDistSq: Double

            if useHeadOnly {
                u = model.headOnlyWeightsU[0]
                    + model.headOnlyWeightsU[1] * zYaw
                    + model.headOnlyWeightsU[2] * zPitch
                v = model.headOnlyWeightsV[0]
                    + model.headOnlyWeightsV[1] * zYaw
                    + model.headOnlyWeightsV[2] * zPitch
                let d0 = zYaw - model.centroid[0]
                let d1 = zPitch - model.centroid[1]
                centroidDistSq = d0 * d0 + d1 * d1
            } else if let eye = features.eye {
                let zEyeX = (eye.x - model.featureMeans[2]) / model.featureStds[2]
                let zEyeY = (eye.y - model.featureMeans[3]) / model.featureStds[3]
                u = model.weightsU[0]
                    + model.weightsU[1] * zYaw
                    + model.weightsU[2] * zPitch
                    + model.weightsU[3] * zEyeX
                    + model.weightsU[4] * zEyeY
                v = model.weightsV[0]
                    + model.weightsV[1] * zYaw
                    + model.weightsV[2] * zPitch
                    + model.weightsV[3] * zEyeX
                    + model.weightsV[4] * zEyeY
                let d0 = zYaw - model.centroid[0]
                let d1 = zPitch - model.centroid[1]
                let d2 = zEyeX - model.centroid[2]
                let d3 = zEyeY - model.centroid[3]
                centroidDistSq = d0 * d0 + d1 * d1 + d2 * d2 + d3 * d3
            } else {
                continue
            }

            guard u.isFinite, v.isFinite else { continue }

            let widthMM = display.physicalSizeMM.width >= 1.0
                ? Double(display.physicalSizeMM.width)
                : max(Double(display.bounds.width) * 0.25, 1.0)
            let heightMM = display.physicalSizeMM.height >= 1.0
                ? Double(display.physicalSizeMM.height)
                : max(Double(display.bounds.height) * 0.25, 1.0)

            let overLeftMM = max(0.0, -u) * widthMM
            let overRightMM = max(0.0, u - 1.0) * widthMM
            let dxMM = max(overLeftMM, overRightMM)
            let overTopMM = max(0.0, -v) * heightMM
            let overBottomMM = max(0.0, v - 1.0) * heightMM
            let dyMM = max(overTopMM, overBottomMM)
            let distMM = hypot(dxMM, dyMM)

            projections.append(DisplayProjection(
                display: display,
                u: u,
                v: v,
                dxMM: dxMM,
                overTopMM: overTopMM,
                overBottomMM: overBottomMM,
                distMM: distMM,
                centroidDistSq: centroidDistSq,
                usedHeadOnly: useHeadOnly
            ))
        }

        guard !projections.isEmpty else {
            return .offScreen
        }

        let chosen: DisplayProjection
        let insideDisplays = projections.filter { $0.distMM == 0 }
        if !insideDisplays.isEmpty {
            if let prevUUID = previousDisplayUUID,
               let sticky = insideDisplays.first(where: { $0.display.uuid == prevUUID }) {
                chosen = sticky
            } else {
                chosen = insideDisplays.min(by: { $0.centroidDistSq < $1.centroidDistSq }) ?? insideDisplays[0]
            }
        } else {
            chosen = projections.min(by: { a, b in
                if abs(a.distMM - b.distMM) > 1e-6 {
                    return a.distMM < b.distMM
                }
                if a.display.uuid == previousDisplayUUID && b.display.uuid != previousDisplayUUID {
                    return true
                }
                if b.display.uuid == previousDisplayUUID && a.display.uuid != previousDisplayUUID {
                    return false
                }
                return a.centroidDistSq < b.centroidDistSq
            }) ?? projections[0]
        }

        if chosen.dxMM > config.offscreenMarginMM
            || chosen.overTopMM > config.offscreenMarginMM
            || chosen.overBottomMM > config.offscreenMarginBottomMM {
            return .offScreen
        }

        let cu = min(max(chosen.u, 0.0), 1.0)
        let cv = min(max(chosen.v, 0.0), 1.0)
        let px = chosen.display.bounds.minX + CGFloat(cu) * chosen.display.bounds.width
        let py = chosen.display.bounds.minY + CGFloat(cv) * chosen.display.bounds.height

        return .point(GazePoint(
            point: CGPoint(x: px, y: py),
            displayUUID: chosen.display.uuid,
            confidence: features.confidence,
            timestamp: features.timestamp,
            usedHeadOnlyModel: chosen.usedHeadOnly
        ))
    }
}
