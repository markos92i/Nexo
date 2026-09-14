import Testing
@testable import Nexo

@Test func activityKindRoundTrips() {
    let kind = ActivityKind("sudoku")
    #expect(kind.rawValue == "sudoku")
}
