import XCTest
@testable import LecternCore

final class MathTextTests: XCTestCase {
    func testSubscriptsAndEllipsis() {
        XCTAssertEqual(MathText.plain("x_1, x_2, \\ldots, x_n"), "x₁, x₂, …, xₙ")
    }

    func testFractionOfDerivatives() {
        XCTAssertEqual(MathText.plain("w \\leftarrow w-\\eta\\frac{\\partial C}{\\partial w}"), "w ← w−η∂C/∂w")
    }

    func testCompoundFractionGetsParentheses() {
        XCTAssertEqual(MathText.plain("\\frac{a+b}{2}"), "(a+b)/2")
    }

    func testTextAndOperatorsKeepTheirWords() {
        XCTAssertEqual(MathText.plain("\\text{MSE}=\\frac{1}{n}\\sum (y-\\hat{y})^2"), "MSE=1/n∑(y−ŷ)²")
        XCTAssertEqual(MathText.plain("\\log(h_\\theta(x))"), "log (h_θ(x))")
    }

    func testCasesBecomeLines() {
        let latex = "\\begin{cases}\n-\\log(h), & y=1\\\\\n-\\log(1-h), & y=0\n\\end{cases}"
        XCTAssertEqual(MathText.plain(latex), "−log (h), y=1\n−log (1−h), y=0")
    }

    func testSuperscriptTranspose() {
        XCTAssertEqual(MathText.plain("w^Tx"), "wᵀx")
        XCTAssertEqual(MathText.plain("3^n"), "3ⁿ")
    }
}

final class NoteDocumentTests: XCTestCase {
    func testTitleIsDroppedOnlyWhenItLeadsTheNotes() {
        let blocks = NoteDocument.parse("# Yapay Sinir Ağları\n\n## Giriş\nMetin", droppingTitle: "Yapay Sinir Ağları")
        XCTAssertEqual(blocks, [.heading(level: 2, text: "Giriş"), .paragraph("Metin")])
        XCTAssertEqual(NoteDocument.parse("# Başka\n", droppingTitle: "Yapay").first, .heading(level: 1, text: "Başka"))
    }

    func testInlineFormulasAreEscapedForMarkdown() {
        let blocks = NoteDocument.parse("- **Girişler:** \\(x_1, \\ldots, h_\\theta\\)")
        XCTAssertEqual(blocks, [.bullet(depth: 0, text: "**Girişler:** x₁, …, h\\_θ")])
        let markdown = try? AttributedString(markdown: "h\\_θ")
        XCTAssertEqual(markdown.map { String($0.characters) }, "h_θ")
    }

    func testDisplayedFormulaOverSeveralLines() {
        let blocks = NoteDocument.parse("Önce:\n\n\\[\nU=B\\cdot C\n\\]\n\nSonra")
        XCTAssertEqual(blocks, [.paragraph("Önce:"), .formula("U=B·C"), .paragraph("Sonra")])
    }

    func testTableSkipsTheSeparatorAndKeepsFormulaCells() {
        let source = "| \\(x_1\\) | \\(|x|\\) | XOR |\n|---|---|---|\n| 0 | 1 | 1 |"
        XCTAssertEqual(NoteDocument.parse(source), [.table(header: ["x₁", "|x|", "XOR"], rows: [["0", "1", "1"]])])
    }

    func testListsRulesAndContinuations() {
        let source = "1. Girişler ileri geçirilir.\n   ayrıntı\n2. Çıktı alınır.\n\n---\n  - iç madde\nsatır bir\nsatır iki"
        XCTAssertEqual(NoteDocument.parse(source), [
            .numbered(number: 1, text: "Girişler ileri geçirilir.\nayrıntı"),
            .numbered(number: 2, text: "Çıktı alınır."),
            .rule,
            .bullet(depth: 1, text: "iç madde"),
            .paragraph("satır bir satır iki"),
        ])
    }

    func testSectionNumbersAreNotListItems() {
        XCTAssertEqual(NoteDocument.parse("### 2.4. XOR"), [.heading(level: 3, text: "2.4. XOR")])
        XCTAssertEqual(NoteDocument.parse("10.000 örnek"), [.paragraph("10.000 örnek")])
    }
}
