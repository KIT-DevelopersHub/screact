import Foundation

/// Direct port of Android's MarkerStabilityTracker. Confirms a stable calibration only when the
/// four expected ArUco IDs (10=TL, 11=TR, 12=BR, 13=BL) form a convex, sufficiently large
/// quadrilateral and their centers stay within `maxCenterMovement` for `requiredFrames` frames.
final class MarkerStabilityTracker {
    static let idTopLeft = 10
    static let idTopRight = 11
    static let idBottomRight = 12
    static let idBottomLeft = 13
    static let expectedIds: Set<Int> = [idTopLeft, idTopRight, idBottomRight, idBottomLeft]

    static let defaultRequiredStableFrames = 5
    static let defaultToleratedInvalidFrames = 2
    static let defaultMaxCenterMovement: Float = 0.02
    static let minQuadrilateralArea: Float = 0.01
    static let minTurnCrossProduct: Float = 0.00001

    private let requiredFrames: Int
    private let maxCenterMovement: Float
    private let toleratedInvalidFrames: Int

    private var history: [[Int: NormalizedPoint]] = []
    private var consecutiveInvalidFrames = 0

    var stableFrameCount: Int { history.count }

    init(requiredFrames: Int = defaultRequiredStableFrames,
         maxCenterMovement: Float = defaultMaxCenterMovement,
         toleratedInvalidFrames: Int = defaultToleratedInvalidFrames) {
        self.requiredFrames = requiredFrames
        self.maxCenterMovement = maxCenterMovement
        self.toleratedInvalidFrames = toleratedInvalidFrames
    }

    @discardableResult
    func update(_ markers: [DetectedMarker]) -> Bool {
        if !hasExpectedLayout(markers) {
            consecutiveInvalidFrames += 1
            if consecutiveInvalidFrames > toleratedInvalidFrames { history.removeAll() }
            return false
        }

        consecutiveInvalidFrames = 0
        let centers = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, $0.center) })
        if let first = history.first, !centersAreStable(first, centers) {
            history.removeAll()
        }
        history.append(centers)
        while history.count > requiredFrames { history.removeFirst() }
        if history.count < requiredFrames { return false }

        return Self.expectedIds.allSatisfy { id in
            let points = history.compactMap { $0[id] }
            guard points.count == requiredFrames, let firstPoint = points.first else { return false }
            return points.allSatisfy { point in
                hypot(Double(point.x - firstPoint.x), Double(point.y - firstPoint.y)) <= Double(maxCenterMovement)
            }
        }
    }

    func reset() {
        history.removeAll()
        consecutiveInvalidFrames = 0
    }

    private func centersAreStable(_ reference: [Int: NormalizedPoint],
                                  _ candidate: [Int: NormalizedPoint]) -> Bool {
        Self.expectedIds.allSatisfy { id in
            guard let first = reference[id], let current = candidate[id] else { return false }
            return hypot(Double(current.x - first.x), Double(current.y - first.y)) <= Double(maxCenterMovement)
        }
    }

    private func hasExpectedLayout(_ markers: [DetectedMarker]) -> Bool {
        let ids = Set(markers.map { $0.id })
        if ids != Self.expectedIds || markers.count != Self.expectedIds.count { return false }
        let centers = Dictionary(uniqueKeysWithValues: markers.map { ($0.id, $0.center) })
        guard let tl = centers[Self.idTopLeft],
              let tr = centers[Self.idTopRight],
              let br = centers[Self.idBottomRight],
              let bl = centers[Self.idBottomLeft] else { return false }
        let ordered = [tl, tr, br, bl]
        let turns: [Float] = ordered.indices.map { index in
            let first = ordered[index]
            let second = ordered[(index + 1) % ordered.count]
            let third = ordered[(index + 2) % ordered.count]
            return (second.x - first.x) * (third.y - second.y) - (second.y - first.y) * (third.x - second.x)
        }
        return polygonArea(ordered) >= Self.minQuadrilateralArea
            && turns.allSatisfy { $0 > Self.minTurnCrossProduct }
    }

    private func polygonArea(_ points: [NormalizedPoint]) -> Float {
        var twiceArea: Float = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            twiceArea += current.x * next.y - next.x * current.y
        }
        return abs(twiceArea) / 2
    }
}
