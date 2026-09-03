import Testing
@testable import agtermctlKit

struct HudCommandHelpTests {
    @Test func updateHelpSaysOmissionClearsPaneScope() {
        let help = Session.Hud.Update.helpMessage(columns: 200)

        #expect(help.contains("omit to return to whole-session placement"))
        #expect(help.contains("repeat it on update to keep pane scope"))
    }
}
