import XCTest
@testable import NotchCore

final class ContentRulesTests: XCTestCase {
    func testClipKinds() {
        XCTAssertEqual(ClipClassifier.kind(of: "https://github.com/argahv/notchflow"), .link)
        XCTAssertEqual(ClipClassifier.kind(of: "  #A99BFF \n"), .color)
        XCTAssertEqual(ClipClassifier.kind(of: "someone@example.com"), .email)
        XCTAssertEqual(ClipClassifier.kind(of: "func go() {\n  let x = 1;\n}"), .code)
        XCTAssertEqual(ClipClassifier.kind(of: "Pick up milk on the way home"), .text)
        XCTAssertEqual(ClipClassifier.kind(of: "javascript:alert(1)"), .text, "only web links count as links")
    }

    func testLikelySecretsAreCaughtBestEffort() {
        let secrets = ["ghp_" + String(repeating: "a1B2", count: 9), "sk-proj-abcdefghijklmnopqrstuvwxyz012345",
                       "AKIAIOSFODNN7EXAMPLE", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc", "password = hunter2hunter2",
                       "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
                       "x7#Qm2!vR9@pL4$wK8"]
        for secret in secrets { XCTAssertTrue(ClipClassifier.looksSecret(secret), secret) }
        let ordinary = ["Meeting notes for Tuesday", "https://example.com/a/very/long/path/with/segments", "someone@example.com",
                        "NotchFlowDesignSystem", "1234567890123456", "The quick brown fox"]
        for text in ordinary { XCTAssertFalse(ClipClassifier.looksSecret(text), text) }
    }

    func testMeetingLinksAreConservative() {
        let zoom = MeetingLinks.join(in: [nil, "Room 4", "Join: https://us02web.zoom.us/j/8123456789?pwd=abc"])
        XCTAssertEqual(zoom?.service, "Zoom")
        XCTAssertEqual(zoom?.url.host, "us02web.zoom.us")
        XCTAssertEqual(MeetingLinks.join(in: ["https://meet.google.com/abc-defg-hij"])?.service, "Google Meet")
        XCTAssertEqual(MeetingLinks.join(in: ["https://teams.microsoft.com/l/meetup-join/19%3ameeting"])?.service, "Teams")
        XCTAssertEqual(MeetingLinks.join(in: ["https://acme.webex.com/meet/alex"])?.service, "Webex")
        XCTAssertEqual(MeetingLinks.join(in: ["https://acme.webex.com/join/12345"])?.service, "Webex")
        XCTAssertEqual(MeetingLinks.join(in: ["https://acme.webex.com/j.php?MTID=m12345"])?.service, "Webex")
        XCTAssertEqual(MeetingLinks.join(in: ["https://acme.webex.com/acme/j.php?MTID=m12345"])?.service, "Webex")
        XCTAssertEqual(MeetingLinks.join(in: ["https://whereby.com/team-room"])?.service, "Whereby")
        XCTAssertNil(MeetingLinks.join(in: ["http://zoom.us/j/123"]), "HTTPS only")
        XCTAssertNil(MeetingLinks.join(in: ["https://zoom.us/pricing", "https://evil-zoom.us/j/1", "https://example.com/j/1"]))
        XCTAssertNil(MeetingLinks.join(in: ["https://meet.google.com/"]), "the bare homepage isn't a meeting")
        for url in ["https://www.webex.com/pricing/index.html", "https://webex.com/",
                    "https://www.webex.com/meet/alex", "https://acme.webex.com/pricing",
                    "https://acme.webex.com/join-us",
                    "https://whereby.com/pricing", "https://whereby.com/login",
                    "https://notwebex.com/meet/alex", "https://webex.com.evil.test/meet/alex",
                    "https://whereby.com/", "https://whereby.com/team-room/extra",
                    "https://notwhereby.com/team-room", "https://whereby.com.evil.test/team-room"] {
            XCTAssertNil(MeetingLinks.join(in: [url]), url)
        }
    }

    func testDownloadNames() {
        XCTAssertTrue(DownloadNames.isPartial("Xcode.xip.download"))
        XCTAssertTrue(DownloadNames.isPartial("report.pdf.crdownload"))
        XCTAssertTrue(DownloadNames.isPartial("abc123.part"))
        XCTAssertFalse(DownloadNames.isPartial("report.pdf"))
        XCTAssertEqual(DownloadNames.finalName(forPartial: "report.pdf.crdownload"), "report.pdf")
        XCTAssertEqual(DownloadNames.finalName(forPartial: "Xcode.xip.download"), "Xcode.xip")
        XCTAssertNil(DownloadNames.finalName(forPartial: "abc123.part"), "Firefox's final name can't be predicted")
        XCTAssertTrue(DownloadNames.isIgnored(".DS_Store"))
    }

    func testBatteryThresholdsFireOncePerCrossing() {
        XCTAssertEqual(BatteryAlerts.crossed(from: 21, to: 20, charging: false), 20)
        XCTAssertNil(BatteryAlerts.crossed(from: 20, to: 19, charging: false), "already below 20")
        XCTAssertEqual(BatteryAlerts.crossed(from: 11, to: 9, charging: false), 10)
        XCTAssertEqual(BatteryAlerts.crossed(from: 22, to: 4, charging: false), 5, "a big drop reports the lowest threshold")
        XCTAssertNil(BatteryAlerts.crossed(from: 11, to: 9, charging: true))
        XCTAssertNil(BatteryAlerts.crossed(from: nil, to: 9, charging: false), "no alert at launch")
        XCTAssertNil(BatteryAlerts.crossed(from: 9, to: 11, charging: false))
    }
}
