import Testing
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
}
