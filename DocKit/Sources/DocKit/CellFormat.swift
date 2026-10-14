/// What a field takes from typed text, the same for every writer (the editor, the agent):
/// nil is text that isn't that kind of value, which the field doesn't take.
public enum CellFormat {
    /// A number as typed, with the writer's grouping and decimal separators ("1,234.5"
    /// where those are "," and "."); never infinite or NaN.
    public static func number(_ text: String, grouping: String = ",", decimal: String = ".") -> Double? {
        var digits = text.trimmingWhitespace()
        if !grouping.isEmpty { digits = digits.replacing(grouping, with: "") }
        if decimal != "." { digits = digits.replacing(decimal, with: ".") }
        guard digits.allSatisfy({ $0.isASCII && ($0.isNumber || "+-.eE".contains($0)) }),
              let number = Double(digits), number.isFinite else { return nil }
        return number
    }

    /// A link as stored: "scheme://host…", or mailto:/tel:; a bare "example.com/a" gets
    /// https://. A web link's host is a domain (it has a dot) or localhost.
    public static func link(_ text: String) -> String? {
        let link = text.trimmingWhitespace()
        guard !link.isEmpty, !link.contains(where: \.isWhitespace) else { return nil }
        for scheme in ["mailto:", "tel:"] where link.lowercased().hasPrefix(scheme) {
            return link.count > scheme.count ? link : nil
        }
        guard let separator = link.firstRange(of: "://") else { return self.link("https://" + link) }
        let scheme = link[..<separator.lowerBound]
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return nil }
        let rest = link[separator.upperBound...]
        var host = rest.prefix { !"/?#".contains($0) }
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if let colon = host.lastIndex(of: ":") { host = host[..<colon] }
        guard !host.isEmpty, !host.hasPrefix("."), !host.hasSuffix(".") else { return nil }
        if ["http", "https"].contains(scheme.lowercased()) {
            guard host.contains(".") || host.lowercased() == "localhost" else { return nil }
        }
        return link
    }
}

extension Column {
    /// Whether the value is one this column holds: its kind, a finite number, the
    /// select's own options (each once), a link as `CellFormat.link` stores it.
    public func holds(_ value: CellValue) -> Bool {
        switch (type, value) {
        case (.text, .text), (.date, .date), (.checkbox, .checkbox), (.person, .person): true
        case (.text, .richText(let text)): !text.marks.isEmpty && (try? text.validate()) != nil
        case (.number, .number(let number)): number.isFinite
        case (.url, .url(let link)): CellFormat.link(link) == link
        case (.select(let options), .select(let id)): options.contains { $0.id == id }
        case (.multiSelect(let options), .multiSelect(let ids)):
            Set(ids).count == ids.count && ids.allSatisfy { id in options.contains { $0.id == id } }
        default: false
        }
    }
}

private extension String {
    func trimmingWhitespace() -> String {
        String(drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
    }
}
