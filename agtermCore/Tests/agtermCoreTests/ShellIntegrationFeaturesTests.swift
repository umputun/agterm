import Foundation
import Testing
@testable import agtermCore

struct ShellIntegrationFeaturesTests {
    private let sshFlags: Set<String> = ["ssh-env", "ssh-terminfo"]

    /// cursor | title | path, ghostty's own defaults for this struct.
    private let defaultBits: UInt32 = 0b100101

    @Test func defaultsRenderWithBothSSHFlagsOff() {
        #expect(ShellIntegrationFeatures.overrideValue(resolvedBits: defaultBits, disabled: sshFlags)
            == "cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path")
    }

    @Test func aResolvedSSHFlagIsForcedOffWhileEveryOtherFlagSurvives() {
        // defaults with no-cursor and ssh-terminfo, the reporter's config in #463
        let bits: UInt32 = 0b110100
        #expect(ShellIntegrationFeatures.overrideValue(resolvedBits: bits, disabled: sshFlags)
            == "no-cursor,no-sudo,title,no-ssh-env,no-ssh-terminfo,path")
    }

    @Test func everyFlagOnStillLosesOnlyTheSSHPair() {
        #expect(ShellIntegrationFeatures.overrideValue(resolvedBits: 0b111111, disabled: sshFlags)
            == "cursor,sudo,title,no-ssh-env,no-ssh-terminfo,path")
    }

    @Test func everyFlagOffStaysOff() {
        #expect(ShellIntegrationFeatures.overrideValue(resolvedBits: 0, disabled: sshFlags)
            == "no-cursor,no-sudo,no-title,no-ssh-env,no-ssh-terminfo,no-path")
    }

    @Test func nothingDisabledLeavesAResolvedSSHFlagOn() {
        #expect(ShellIntegrationFeatures.overrideValue(resolvedBits: defaultBits | (1 << 4), disabled: [])
            == "cursor,no-sudo,title,no-ssh-env,ssh-terminfo,path")
    }

    @Test func flagOrderMatchesLibghosttysFieldOrder() {
        #expect(ShellIntegrationFeatures.ordered == ["cursor", "sudo", "title", "ssh-env", "ssh-terminfo", "path"])
    }
}
