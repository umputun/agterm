import Testing
@testable import agtermCore

struct TitleAdmissionTests {
    @Test func aDuplicateIsSkippedWhileTheFirstIsPending() {
        var admission = TitleAdmission()
        #expect(["build", "build", "build"].map { admission.admit($0) } == [true, false, false])
    }

    @Test func aChangedTitleBetweenTwoEqualOnesQueuesAllThree() {
        var admission = TitleAdmission()
        #expect(["T", "U", "T"].map { admission.admit($0) } == [true, true, true])
    }

    @Test func theSameTitleQueuesAgainOnceTheQueueDrains() {
        var admission = TitleAdmission()
        let queued = ["T", "U"].map { admission.admit($0) }
        admission.complete()
        let whilePending = admission.admit("U")
        admission.complete()
        let afterDrain = admission.admit("U")
        #expect(queued == [true, true])
        #expect(!whilePending)
        #expect(afterDrain)
    }

    @Test func eachPaneDecidesOnItsOwnTitles() {
        var left = TitleAdmission()
        var right = TitleAdmission()
        let first = [left.admit("T"), right.admit("T"), left.admit("T")]
        right.complete()
        let rightAgain = right.admit("T")
        #expect(first == [true, true, false])
        #expect(rightAgain)
    }

    @Test func anExtraCompleteNeverReadmitsAPendingDuplicate() {
        var admission = TitleAdmission()
        admission.complete()
        #expect(["T", "T"].map { admission.admit($0) } == [true, false])
    }
}
