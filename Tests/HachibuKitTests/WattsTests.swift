import Testing
@testable import HachibuKit

@Test("Watts read with one decimal below 10, whole above, dash when missing", arguments: [
    (nil, "–"), (0.0, "0 W"), (0.04, "0 W"), (9.2, "9.2 W"), (9.96, "10 W"),
    (28.4, "28 W"), (-7.25, "7.3 W"), (Double.nan, "–"),
] as [(Double?, String)])
func wattsText(value: Double?, expected: String) {
    #expect(Watts.text(value) == expected)
}
