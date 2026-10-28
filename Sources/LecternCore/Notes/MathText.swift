import Foundation

/// Turns the LaTeX in generated notes into readable plain text: `x_1` becomes x₁,
/// `\frac{\partial C}{\partial w}` becomes ∂C/∂w. It does not lay out formulas; it only makes them legible.
public enum MathText {
    public static func plain(_ latex: String) -> String {
        var reader = Reader(latex)
        let text = reader.convert(until: nil)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private struct Reader {
        let chars: [Character]
        var index = 0

        init(_ text: String) { chars = Array(text) }

        var atEnd: Bool { index >= chars.count }

        mutating func convert(until closing: Character?) -> String {
            var out = ""
            while !atEnd {
                let c = chars[index]
                if c == closing { index += 1; return out }
                switch c {
                case "\\":
                    out += command()
                case "_", "^":
                    index += 1
                    let content = group()
                    out += script(content, superscript: c == "^")
                case "{":
                    index += 1
                    out += convert(until: "}")
                case "}":
                    index += 1
                case "&", "~":
                    index += 1
                    out += " "
                case "-":
                    index += 1
                    out += "−"
                case "\n":
                    index += 1
                    out += " "
                default:
                    index += 1
                    out.append(c)
                }
            }
            return out
        }

        /// A braced group, a command or a single character, converted.
        mutating func group() -> String {
            while !atEnd, chars[index] == " " { index += 1 }
            guard !atEnd else { return "" }
            switch chars[index] {
            case "{":
                index += 1
                return convert(until: "}")
            case "\\":
                return command()
            default:
                let c = chars[index]
                index += 1
                return c == "-" ? "−" : String(c)
            }
        }

        /// The raw text of a braced group, for `\text{...}` and environment names.
        mutating func rawGroup() -> String {
            while !atEnd, chars[index] == " " { index += 1 }
            guard !atEnd, chars[index] == "{" else { return "" }
            index += 1
            var depth = 1, out = ""
            while !atEnd {
                let c = chars[index]
                index += 1
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { break } }
                out.append(c)
            }
            return out
        }

        mutating func command() -> String {
            index += 1
            guard !atEnd else { return "" }
            let first = chars[index]
            guard first.isLetter else {
                index += 1
                switch first {
                case "\\": return "\n"
                case ",", ";", ":", " ": return " "
                case "!": return ""
                default: return String(first)
                }
            }
            var name = ""
            while !atEnd, chars[index].isLetter { name.append(chars[index]); index += 1 }
            // the space after a command name only ends the name
            if !atEnd, chars[index] == " " { index += 1 }

            switch name {
            case "frac", "dfrac", "tfrac":
                let top = group(), bottom = group()
                return "\(wrapped(top))/\(wrapped(bottom))"
            case "sqrt":
                return "√" + wrapped(group())
            case "text", "textrm", "textbf", "textit", "mathrm", "operatorname", "mathit", "mbox":
                return rawGroup()
            case "mathbf", "boldsymbol", "mathcal", "mathbb", "boxed", "displaystyle", "textstyle", "overline":
                return name == "displaystyle" || name == "textstyle" ? "" : group()
            case "hat", "widehat": return accent(group(), "\u{0302}")
            case "bar": return accent(group(), "\u{0304}")
            case "tilde", "widetilde": return accent(group(), "\u{0303}")
            case "vec": return accent(group(), "\u{20D7}")
            case "dot": return accent(group(), "\u{0307}")
            case "left", "right", "big", "Big", "bigg", "Bigg":
                if !atEnd, chars[index] == "." { index += 1 }
                return ""
            case "begin", "end":
                _ = rawGroup()
                return name == "begin" ? "" : "\n"
            case "quad", "qquad": return "  "
            default:
                if let symbol = Self.symbols[name] { return Self.relations.contains(name) ? " \(symbol) " : symbol }
                if Self.words.contains(name) { return name + " " }
                return name
            }
        }

        private func wrapped(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            let compound = trimmed.count > 1 && trimmed.contains(where: { " +−=·×/,".contains($0) })
            return compound ? "(\(trimmed))" : trimmed
        }

        private func accent(_ text: String, _ mark: String) -> String {
            text.count == 1 ? text + mark : text
        }

        private func script(_ text: String, superscript: Bool) -> String {
            let map = superscript ? Self.superscripts : Self.subscripts
            let mapped = text.map { map[$0] }
            if !text.isEmpty, mapped.allSatisfy({ $0 != nil }) { return String(mapped.compactMap { $0 }) }
            let mark = superscript ? "^" : "_"
            return text.count == 1 ? mark + text : "\(mark)(\(text))"
        }

        static let symbols: [String: String] = [
            "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε",
            "zeta": "ζ", "eta": "η", "theta": "θ", "vartheta": "ϑ", "iota": "ι", "kappa": "κ", "lambda": "λ",
            "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π", "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ",
            "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
            "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ",
            "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
            "partial": "∂", "nabla": "∇", "infty": "∞", "sum": "∑", "prod": "∏", "int": "∫",
            "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "ast": "∗",
            "ldots": "…", "cdots": "⋯", "dots": "…", "vdots": "⋮",
            "leftarrow": "←", "rightarrow": "→", "to": "→", "gets": "←", "Rightarrow": "⇒", "Leftarrow": "⇐",
            "leftrightarrow": "↔", "Leftrightarrow": "⇔", "implies": "⇒", "iff": "⇔", "mapsto": "↦",
            "leq": "≤", "le": "≤", "geq": "≥", "ge": "≥", "neq": "≠", "ne": "≠", "approx": "≈", "sim": "∼",
            "equiv": "≡", "propto": "∝", "in": "∈", "notin": "∉", "subset": "⊂", "subseteq": "⊆",
            "cup": "∪", "cap": "∩", "emptyset": "∅", "forall": "∀", "exists": "∃", "neg": "¬",
            "land": "∧", "lor": "∨", "langle": "⟨", "rangle": "⟩", "lfloor": "⌊", "rfloor": "⌋",
            "lceil": "⌈", "rceil": "⌉", "mid": "|", "prime": "′", "circ": "∘", "star": "⋆",
        ]

        /// Arrows and relations read better with room around them: `w ← w − η`.
        static let relations: Set<String> = [
            "leftarrow", "rightarrow", "to", "gets", "Rightarrow", "Leftarrow", "leftrightarrow", "Leftrightarrow",
            "implies", "iff", "mapsto", "leq", "le", "geq", "ge", "neq", "ne", "approx", "sim", "equiv", "propto",
            "in", "notin", "subset", "subseteq",
        ]

        static let words: Set<String> = ["log", "ln", "exp", "sin", "cos", "tan", "max", "min", "arg", "lim", "det", "sup", "inf"]

        static let subscripts: [Character: Character] = [
            "0": "₀", "1": "₁", "2": "₂", "3": "₃", "4": "₄", "5": "₅", "6": "₆", "7": "₇", "8": "₈", "9": "₉",
            "+": "₊", "−": "₋", "=": "₌", "(": "₍", ")": "₎",
            "a": "ₐ", "e": "ₑ", "h": "ₕ", "i": "ᵢ", "j": "ⱼ", "k": "ₖ", "l": "ₗ", "m": "ₘ", "n": "ₙ", "o": "ₒ",
            "p": "ₚ", "r": "ᵣ", "s": "ₛ", "t": "ₜ", "u": "ᵤ", "v": "ᵥ", "x": "ₓ",
            "β": "ᵦ", "γ": "ᵧ", "ρ": "ᵨ", "φ": "ᵩ", "χ": "ᵪ",
        ]

        static let superscripts: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴", "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "−": "⁻", "=": "⁼", "(": "⁽", ")": "⁾",
            "a": "ᵃ", "b": "ᵇ", "c": "ᶜ", "d": "ᵈ", "e": "ᵉ", "f": "ᶠ", "g": "ᵍ", "h": "ʰ", "i": "ⁱ", "j": "ʲ",
            "k": "ᵏ", "l": "ˡ", "m": "ᵐ", "n": "ⁿ", "o": "ᵒ", "p": "ᵖ", "r": "ʳ", "s": "ˢ", "t": "ᵗ", "u": "ᵘ",
            "v": "ᵛ", "w": "ʷ", "x": "ˣ", "y": "ʸ", "z": "ᶻ", "T": "ᵀ", "′": "′", "∗": "*", "*": "*",
        ]
    }
}
