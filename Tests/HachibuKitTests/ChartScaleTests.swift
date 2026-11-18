import Testing
@testable import HachibuKit

@Test("Chart bounds sit on round numbers and hold every value")
func chartBoundsHoldValues() {
    #expect(ChartScale.bounds(for: [72, 80, 78], including: [80], step: 10, minimumSpan: 20) == 70...90)
    #expect(ChartScale.bounds(for: [31.2, 36.8], step: 5, minimumSpan: 10) == 30...40)
}

@Test("A flat series still gets a readable span")
func chartBoundsMinimumSpan() {
    let bounds = ChartScale.bounds(for: [82, 82, 82], step: 1, minimumSpan: 4)
    #expect(bounds.upperBound - bounds.lowerBound == 4)
    #expect(bounds.contains(82))
}

@Test("No values gives a harmless scale")
func chartBoundsEmpty() {
    #expect(ChartScale.bounds(for: [], step: 10, minimumSpan: 20) == 0...20)
}
