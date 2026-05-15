import XCTest
@testable import LidSwitch

final class PowerInspectorTests: XCTestCase {
    func testParsesACPowerSource() {
        let output = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=25165923)	35%; charging; 1:05 remaining present: true
        """

        XCTAssertEqual(PowerInspector.parsePowerSource(from: output), .ac)
    }

    func testParsesBatteryPowerSourceAndPercent() {
        let output = """
        Now drawing from 'Battery Power'
         -InternalBattery-0 (id=25165923)	35%; discharging; 1:05 remaining present: true
        """

        XCTAssertEqual(PowerInspector.parsePowerSource(from: output), .battery(percent: 35))
    }

    func testParsesSleepDisabled() {
        let output = """
        System-wide power settings:
         SleepDisabled		1
        Currently in use:
         sleep                0
        """

        XCTAssertTrue(PowerInspector.parseSleepDisabled(from: output))
    }

    func testParsesACIdleSleep() {
        let output = """
        Battery Power:
         sleep                1
        AC Power:
         displaysleep         10
         sleep                0
        """

        XCTAssertEqual(PowerInspector.parseACIdleSleep(from: output), 0)
    }
}
