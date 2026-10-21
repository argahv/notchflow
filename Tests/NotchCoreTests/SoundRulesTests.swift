import XCTest
@testable import NotchCore

final class SoundRulesTests: XCTestCase {
    let speakers = AudioSnapshot(output: 1, outputName: "MacBook Air Speakers", bluetooth: false, devices: [1, 2])

    func testOnlyAChangeOfOutputIsNews() {
        XCTAssertNil(SoundRules.transition(from: nil, to: speakers), "the first look isn't a change")
        XCTAssertNil(SoundRules.transition(from: speakers, to: speakers))
        let display = AudioSnapshot(output: 2, outputName: "Studio Display", bluetooth: false, devices: [1, 2])
        XCTAssertEqual(SoundRules.transition(from: speakers, to: display), .switched(name: "Studio Display", bluetooth: false))
    }

    func testAirPodsArrivingAreAConnectionNotJustASwitch() {
        let airpods = AudioSnapshot(output: 7, outputName: "AirPods Pro", bluetooth: true, devices: [1, 2, 7])
        XCTAssertEqual(SoundRules.transition(from: speakers, to: airpods), .connected(name: "AirPods Pro"))
        let back = AudioSnapshot(output: 7, outputName: "AirPods Pro", bluetooth: true, devices: [1, 2, 7])
        let away = AudioSnapshot(output: 1, outputName: "MacBook Air Speakers", bluetooth: false, devices: [1, 2, 7])
        XCTAssertEqual(SoundRules.transition(from: away, to: back), .switched(name: "AirPods Pro", bluetooth: true),
                       "already connected: switching back to it is a switch")
        XCTAssertNil(SoundRules.transition(from: speakers, to: AudioSnapshot(output: nil, outputName: nil, bluetooth: false, devices: [])),
                     "no output at all says nothing")
    }
}
