import XCTest
@testable import LecternCore

final class PracticeCardsTests: XCTestCase {
    func testLecternsOwnShape() {
        let source = """
        # Zincir kuralı

        1. Zincir kuralı neyi hesaplar?
        > İç değişkenlere göre türevleri çarparak sonucun türevini.

        2. \\(U = B\\cdot C\\) ise \\(\\partial U/\\partial B\\) nedir?
        > \\(C\\)
        > Çünkü B'nin katsayısıdır.
        """
        let cards = PracticeCards.parse(source, prefix: "w6")
        XCTAssertEqual(cards.map(\.id), ["w6#1", "w6#2"])
        XCTAssertEqual(cards[0].question, "Zincir kuralı neyi hesaplar?")
        XCTAssertEqual(cards[0].answer, "İç değişkenlere göre türevleri çarparak sonucun türevini.")
        XCTAssertEqual(cards[1].answer, "\\(C\\)\nÇünkü B'nin katsayısıdır.")
    }

    func testHeadingsWithAnAnswerKeyAndExpectedAnswers() {
        let source = """
        # Sınava Hazırlık Soruları

        ## Çoktan seçmeli sorular

        ### 1. MLP, Dense ve geri yayılım

        Aşağıdakilerden hangisi doğrudur?

        A) Birinci
        B) İkinci

        ### 2. Parametre sayısı

        **a)** Giriş katmanını yazınız.

        10.000 \\rightarrow 32

        ## Cevap anahtari

        ### Çoktan seçmeli sorular

        1. **B:** MLP mimarinin adıdır.

        ### Açık uçlu sorular

        #### 2. Beklenen cevap

        1. Önce girişleri sayın.
        2. Sonra bias ekleyin.
        """
        let cards = PracticeCards.parse(source, prefix: "w6")
        XCTAssertEqual(cards.map(\.number), [1, 2])
        XCTAssertTrue(cards[0].question.hasPrefix("**MLP, Dense ve geri yayılım**"))
        XCTAssertTrue(cards[0].question.contains("B) İkinci"))
        XCTAssertEqual(cards[0].answer, "**B:** MLP mimarinin adıdır.")
        // the formula line and the answer's own steps stay where they are
        XCTAssertTrue(cards[1].question.contains("10.000 \\rightarrow 32"))
        XCTAssertEqual(cards[1].answer, "1. Önce girişleri sayın.\n2. Sonra bias ekleyin.")
    }

    func testMissedCardsComeFirstThenNewThenKnown() {
        let cards = (1...4).map { PracticeCard(id: "s#\($0)", number: $0, question: "Q\($0)", answer: "") }
        var log = PracticeLog()
        log.record("s#1", known: true, at: Date(timeIntervalSince1970: 100))
        log.record("s#2", known: false, at: Date(timeIntervalSince1970: 200))
        log.record("s#4", known: true, at: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(log.order(cards, random: { _ in 0 }).map(\.number), [2, 3, 4, 1])
    }
}
