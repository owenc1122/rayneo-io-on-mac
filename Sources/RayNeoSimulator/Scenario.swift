import Foundation

/// Local metres, east/north. Demo data is synthetic, never a user's route.
struct Scenario: Decodable {
    struct Road: Decodable { let `class`: UInt8; let points: [[Double]] }
    struct Feature: Decodable { let kind: String; let position: [Double]; let name: String? }
    let road: String
    let instruction: String
    let distance: UInt32
    let remaining: UInt32
    let eta: String
    let heading: Double
    let position: [Double]
    let metersPerPixel: Double
    let route: [[Double]]
    let roads: [Road]
    let features: [Feature]

    func scene() throws -> SGNScene {
        func point(_ p: [Double]) throws -> SGNPoint {
            guard p.count == 2, p.allSatisfy({ $0.isFinite && abs($0) <= 16_000 }) else { throw ScenarioError.invalid("Coordinates must be two finite numbers within ±16000 metres") }
            return SGNPoint(x: Int16((p[0]*2).rounded()), y: Int16((p[1]*2).rounded()))
        }
        guard heading.isFinite, metersPerPixel.isFinite, (0.1...20).contains(metersPerPixel) else { throw ScenarioError.invalid("Invalid heading or scale") }
        var s = SGNScene()
        s.road = road; s.instr = instruction; s.maneuverDistM = distance; s.remainDistM = remaining; s.eta = eta
        s.headingCd = UInt16(((heading.truncatingRemainder(dividingBy: 360)+360).truncatingRemainder(dividingBy: 360)*100).rounded()) % 36000
        s.pos = try point(position); s.zoomMilli = UInt16((metersPerPixel*1000).rounded()); s.icon = 2
        s.route = try route.map(point); s.man = s.route.count > 1 ? s.route[1] : s.pos
        s.roads = try roads.map { SGNRoad(cls: $0.class, points: try $0.points.map(point)) }
        s.features = try features.map { f in
            guard let kind: UInt8 = ["stop": 1, "signal": 2, "building": 3][f.kind] else { throw ScenarioError.invalid("Unknown feature kind: \(f.kind)") }
            return SGNFeature(kind: kind, point: try point(f.position), name: f.name ?? "")
        }
        _ = try SGN1.encodePayload(s)
        return s
    }
}
enum ScenarioError: Error, LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case let .invalid(s) = self { return s }; return nil }
}
