import CoreGraphics
import Testing
@testable import HermesAgentDock

struct PhosphorIconsTests {
    @Test func everyIconPathParsesInsideTheGrid() {
        let grid = CGRect(x: -1, y: -1, width: 258, height: 258)
        for icon in Ph.allCases {
            let bounds = icon.cgPath(.regular).boundingBoxOfPath
            #expect(!bounds.isEmpty && grid.contains(bounds), "\(icon)")
            if icon.fillPath != nil {
                let fill = icon.cgPath(.fill).boundingBoxOfPath
                #expect(!fill.isEmpty && grid.contains(fill), "\(icon) fill")
            }
        }
    }
}
