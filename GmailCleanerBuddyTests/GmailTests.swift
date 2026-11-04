// As regras puras da camada Gmail, as mesmas que test/*.test.ts guardam no
// Android. Roda no Xcode com ⌘U.
import XCTest
@testable import GmailCleanerBuddy

final class GmailTests: XCTestCase {
    func testAccountKeyIgnoresGmailVariations() {
        let own = "marlon.bastida@gmail.com"
        XCTAssertTrue(isOwnAddress("marlonbastida@gmail.com", own))
        XCTAssertTrue(isOwnAddress("Marlon.Bastida+x@googlemail.com", own))
        XCTAssertFalse(isOwnAddress("marlon.bastida@outlook.com", own))
        // Fora do Gmail, ponto e +sufixo contam.
        XCTAssertFalse(isOwnAddress("a.b@empresa.com", "ab@empresa.com"))
        // Sem saber a própria conta, ninguém é "próprio".
        XCTAssertFalse(isOwnAddress("x@gmail.com", ""))
    }

    func testParseSender() {
        XCTAssertEqual(parseSender("Fulano <Fulano@Exemplo.com>"), "fulano@exemplo.com")
        XCTAssertEqual(parseSender("fulano@exemplo.com"), "fulano@exemplo.com")
        XCTAssertEqual(parseSender("Equipe x@y.com (via)"), "x@y.com")
        XCTAssertEqual(parseSender(nil), "")
        XCTAssertEqual(parseSender("<a b\"c@x.com>"), "") // não passa na validação
    }

    func testFormEncodeKeepsPlusAsPlus() {
        XCTAssertEqual(formEncode([("q", "from:\"a+b@x.com\"")]), "q=from%3A%22a%2Bb%40x.com%22")
    }

    /// A invariante do app: a soma dos remetentes + sem remetente fecha com a
    /// caixa, e cada mensagem conta uma vez.
    func testAnalysisAddsUp() {
        var facts: [String: MsgFacts] = [:]
        for i in 0..<100 { facts["\(i)"] = MsgFacts(sender: i % 10 == 0 ? "" : "s\(i % 3)@x.com", size: i) }
        facts["own"] = MsgFacts(sender: "eu@gmail.com", size: 1)
        let d = buildAnalysis(facts: facts, ownEmail: "e.u@gmail.com", failed: 2, capped: false)

        XCTAssertEqual(d.mailboxMessages, 103)
        XCTAssertEqual(d.offenders.reduce(0) { $0 + $1.count } + d.unattributedMessages + d.failedMessages,
                       d.mailboxMessages)
        XCTAssertEqual(d.unattributedMessages, 10)
        XCTAssertEqual(d.offenders.map(\.count), d.offenders.map(\.count).sorted(by: >))
        // A própria conta aparece sempre, protegida, mesmo fora do top 10.
        XCTAssertTrue(d.top10.contains { $0.sender == "eu@gmail.com" && $0.isProtected })
    }

    func testTop10KeepsOwnAccountOutsideTop() {
        let others = (0..<12).map {
            Offender(sender: "s\($0)@x.com", domain: "x.com", count: 100 - $0, size: 0, category: "cat.other", isProtected: false)
        }
        let own = Offender(sender: "eu@gmail.com", domain: "gmail.com", count: 1, size: 0, category: "cat.google", isProtected: true)
        let top = top10Of(others + [own], own: [own])
        XCTAssertEqual(top.count, 11)
        XCTAssertEqual(top.last, own)
    }
}
