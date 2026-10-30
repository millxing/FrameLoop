import Testing
@testable import FrameLoop2Kit

@Test("Clean titles", arguments: [
    ("Buy milk", "Buy milk"),
    ("  Buy   milk \n", "Buy milk"),
    ("", "New Item"),
    ("   ", "New Item"),
])
func cleans(_ input: String, expected: String) {
    #expect(ItemTitle.clean(input) == expected)
}
