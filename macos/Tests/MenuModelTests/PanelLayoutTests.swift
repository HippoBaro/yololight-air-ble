import Foundation
import Testing
@testable import YoloLightMenu

struct PanelLayoutTests {
    @Test func reservesOneCompactRowBeforeDiscoveryCompletes() {
        #expect(PanelLayout(lightCount: 0).size == CGSize(width: 300, height: 147))
        #expect(PanelLayout(lightCount: 0) == PanelLayout(lightCount: 1))
    }

    @Test func sizesForTheOpeningPopulationAndCapsLongLists() {
        #expect(PanelLayout(lightCount: 2).size == CGSize(width: 300, height: 295))
        #expect(PanelLayout(lightCount: 3).size == CGSize(width: 300, height: 443))
        #expect(PanelLayout(lightCount: 4).size == CGSize(width: 300, height: 444))
        #expect(PanelLayout(lightCount: 100).size == CGSize(width: 300, height: 444))
    }

    @Test func negativeCountCannotCollapseTheViewport() {
        #expect(PanelLayout(lightCount: -1) == PanelLayout(lightCount: 1))
    }
}
