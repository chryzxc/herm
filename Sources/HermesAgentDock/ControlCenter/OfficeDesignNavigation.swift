import Foundation

/// Navigation captured from the same authored furniture and walls that are rendered.
struct OfficeDesignNavigation {
    enum LeisureAction { case coffee, arcade, reading, strolling, socializing }
    struct LeisureSpot {
        let station: Station
        let action: LeisureAction
    }
    struct Station {
        let position: SIMD3<Float>
        let approach: SIMD3<Float>
        let yaw: Float
        var seated = true
    }
    var stations: [OfficePreviewLocation: [Station]] = [:]
    var obstacles: [OfficePreviewLayout.Footprint] = []
    var front: Float = 18
    var minX: Float = -19
    var maxX: Float = 23
    var back: Float = -16
    var leisureSpots: [LeisureSpot] = []

    func station(slot: Int, location: OfficePreviewLocation) -> Station {
        if let candidates = stations[location], candidates.indices.contains(slot) { return candidates[slot] }
        // Overflow agents stand in distinct garden positions, never share a chair.
        let p = SIMD3<Float>(maxX - 2, 0, back + 3 + Float(slot) * 0.75)
        return Station(position: p, approach: p + [1, 0, 0], yaw: -.pi / 2, seated: false)
    }
}
