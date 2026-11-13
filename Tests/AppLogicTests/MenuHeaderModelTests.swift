import AppKit
import Foundation
import Testing
import SesameEngine
@testable import Sesame

@MainActor
func mhDotName(_ model: MenuModel) -> String {
    if model.headerDot == .ready { return "ready" }
    if model.headerDot == .active { return "active" }
    if model.headerDot == .neutral { return "neutral" }
    if model.headerDot == .failed { return "failed" }
    return "other"
}

extension MenuHeaderTests {

    @Test func theHeaderTitleDetailAndDotOfEveryStateAreTheHandCopiedTable() {
        for c in mhCases {
            #expect(c.model.headerTitle == c.title, "\(c.name): title \(c.model.headerTitle.debugDescription), want \(c.title.debugDescription)")
            #expect(c.model.headerDetail == c.detail, "\(c.name): detail \(String(describing: c.model.headerDetail)), want \(String(describing: c.detail))")
            #expect(mhDotName(c.model) == c.dot, "\(c.name): dot \(mhDotName(c.model)), want \(c.dot)")
        }
    }

    @Test func theFourDotKindsAreDistinctValuesAndTheOldMembersKeepTheirTexts() {
        let dots = Set(mhCases.map { mhDotName($0.model) })
        #expect(dots == ["ready", "active", "neutral", "failed"], "the dot kinds in use are \(dots)")
        for c in mhCases {
            #expect(c.model.statusLine == c.statusLine, "\(c.name): the status line is \(c.model.statusLine.debugDescription), want \(c.statusLine.debugDescription)")
        }
        #expect(mhCases[2].model.detailLine == "4,520 files left \u{00B7} about 12 min left", "the detail line of Indexing 62%")
        #expect(mhCases[2].model.statusItemLabel == "Sesame: indexing, 62 percent", "the status item label of Indexing 62%")
        #expect(mhCases[0].model.permissionLine == nil, "Ready before Start has a permission line")
    }

    @Test func theHeaderDetailOfIndexingIsTheDetailLineAndTheTitleIsTheStatusLineForTheLargestCounts() {
        let huge = mhModel(counts: mhCounts(done: 100, pending: ["photo": 1_234_567]), done: mhDone)
        #expect(huge.headerTitle == huge.statusLine, "the title is \(huge.headerTitle.debugDescription), the status line \(huge.statusLine.debugDescription)")
        #expect(huge.headerDetail == huge.detailLine, "the detail is \(String(describing: huge.headerDetail)), the detail line \(String(describing: huge.detailLine))")
        #expect(huge.headerDetail?.hasPrefix("1,234,567 files left") == true, "the detail is \(String(describing: huge.headerDetail))")
    }
}
