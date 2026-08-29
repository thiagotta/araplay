import Testing
@testable import AraPlay

struct FormatTests {
    @Test func timeUnderAnHourDropsHours() {
        #expect(Format.time(0) == "0:00")
        #expect(Format.time(59.9) == "0:59")
        #expect(Format.time(61) == "1:01")
        #expect(Format.time(600) == "10:00")
    }

    @Test func timeOverAnHourShowsHours() {
        #expect(Format.time(3600) == "1:00:00")
        #expect(Format.time(3661) == "1:01:01")
    }

    @Test func timeRejectsNonsense() {
        #expect(Format.time(.nan) == "--:--")
        #expect(Format.time(.infinity) == "--:--")
        #expect(Format.time(-5) == "--:--")
    }

    @Test func remainingCountsDown() {
        #expect(Format.remaining(60, 200) == "-2:20")
        // Never goes positive past the end, even if the playhead overshoots.
        #expect(Format.remaining(250, 200) == "-0:00")
    }

    @Test func remainingWithoutDurationIsPlaceholder() {
        #expect(Format.remaining(10, 0) == "--:--")
    }
}
