import ArgumentParser
import Testing
import agtermCore
@testable import agtermctlKit

struct HudCommandHelpTests {
    @Test func updateHelpSaysOmissionClearsPaneScope() {
        let help = Session.Hud.Update.helpMessage(columns: 200)

        #expect(help.contains("omit to return to whole-session placement"))
        #expect(help.contains("repeat it on update to keep pane scope"))
    }

    @Test func openHelpNamesTheMarkdownCapTheSoftBreakAndTheFixedFontSize() {
        let help = Session.Hud.Open.helpMessage(columns: 200)

        #expect(help.contains("up to 4096 characters"))
        #expect(help.contains("soft break"))
        #expect(help.contains("Fixed for the panel's life"))
        #expect(help.contains("--file"))
    }

    private func request(_ argv: [String]) throws -> ControlRequest {
        let command = try #require(try Agtermctl.parseAsRoot(argv) as? any RequestCommand)
        return try command.makeRequest()
    }

    @Test(arguments: [["session", "hud"], ["session", "hud", "update"]])
    func stickyAndNoFrameAreSentOnlyWhenAsked(verb: [String]) throws {
        let asked = try request(verb + ["caption", "--sticky", "--no-frame", "--size-percent", "100"]).args
        let plain = try request(verb + ["caption"]).args

        #expect(asked?.sticky == true)
        #expect(asked?.frame == false)
        #expect(asked?.sizePercent == 100)
        #expect(plain?.sticky == nil)
        #expect(plain?.frame == nil)
    }

    @Test func helpNamesTheTwoFlagsAndTheWidthAStickyPanelMayTake() {
        for help in [Session.Hud.Open.helpMessage(columns: 200), Session.Hud.Update.helpMessage(columns: 200)] {
            #expect(help.contains("--sticky"))
            #expect(help.contains("--no-frame"))
            #expect(help.contains("flush against the edge or corner"))
            #expect(help.contains("up to 100 with --sticky off center"))
        }
    }
}
