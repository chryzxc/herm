import Foundation
import Testing
@testable import HermesAgentDock

struct OfficeDaylightTests {
    @Test func sunFollowsTheClock() {
        let noon = OfficeDaylight(dayOfYear: 172, solarHour: 12)
        let midnight = OfficeDaylight(dayOfYear: 172, solarHour: 0)
        let morning = OfficeDaylight(dayOfYear: 172, solarHour: 8)
        let evening = OfficeDaylight(dayOfYear: 172, solarHour: 17)
        #expect(noon.sunElevation > 70)
        #expect(midnight.sunElevation < -20)
        // Rises in the east (+x), sets in the west, and sits south (+z) at noon.
        #expect(morning.sunDirection.x > 0)
        #expect(evening.sunDirection.x < 0)
        #expect(noon.sunDirection.z > 0)
        #expect(!noon.isDark && midnight.isDark)
    }

    @Test func winterDaysAreShorter() {
        let summer = OfficeDaylight(dayOfYear: 172, solarHour: 18.5)
        let winter = OfficeDaylight(dayOfYear: 355, solarHour: 18.5)
        #expect(summer.sunElevation > 0)
        #expect(winter.sunElevation < -10)
    }

    @Test func lightHandsOverFromSunToMoon() {
        let dusk = OfficeDaylight(dayOfYear: 172, solarHour: 19.9)
        let night = OfficeDaylight(dayOfYear: 172, solarHour: 23)
        #expect(night.keyIntensity > 0 && night.keyDirection.y > 0.5)
        #expect(dusk.keyDirection.y > 0)
        #expect(night.stars > 0.9)
    }
}
