import Foundation
import Testing
@testable import agtermCore

struct DocumentPageTests {
    @Test(arguments: [
        ("<h1>héllo</h1>", "§<h1>héllo</h1>"),
        ("<!DOCTYPE html><title>t</title>", "<!DOCTYPE html>§<title>t</title>"),
        ("\u{FEFF}\n  <!doctype html>\n<p>x", "\n  <!doctype html>§\n<p>x"),
        ("<!-- c --><!doctype html>", "§<!-- c --><!doctype html>"),
        ("<!doctype html", "§<!doctype html"),
        ("\u{A0}<!doctype html><p>x", "§\u{A0}<!doctype html><p>x"),
        ("\r\n\t<!doctype html>", "\r\n\t<!doctype html>§"),
        ("<!doctype html>\u{0301}<p>x</p>", "<!doctype html>§\u{0301}<p>x</p>"),
    ] as [(String, String)])
    func thePolicyGoesRightAfterALeadingDoctypeOrFirst(_ html: String, _ expected: String) {
        #expect(DocumentPage.page(Data(html.utf8)) == expected.replacingOccurrences(of: "§", with: DocumentPage.policy, options: .literal))
    }

    @Test(arguments: [Data([0x3C, 0x68, 0x00, 0x3E]), Data([0xFF, 0xFE, 0x3C])])
    func binaryOrNonUtf8IsRefused(_ data: Data) {
        #expect(DocumentPage.page(data) == nil)
    }
}
