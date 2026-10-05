#if canImport(Darwin)
    import Darwin
#elseif canImport(Musl)
    import Musl
#elseif canImport(Glibc)
    import Glibc
#endif

/// Spreadsheet formulas in table cells, as Craft has them: a cell whose text starts
/// with `=` shows what it computes. References are A1-style with the header as row 1
/// (`B2` is the first body row's second column), ranges are `A2:C4`, and `ABOVE`,
/// `BELOW`, `LEFT`, `RIGHT` mean the cells that way from the formula's cell (body rows
/// only). Functions: SUM, AVERAGE, COUNT, COUNTA, MIN, MAX, MEDIAN, MODE, PRODUCT,
/// ROUND, ABS, INT, SIGN; operators `+ - * / ^`, unary minus and parentheses.
/// Errors read `#ERROR`, `#REF!`, `#DIV/0!`, `#CYCLE!`.
public enum DatabaseFormula {
    /// What a cell shows: a formula's result, or the cell's own text.
    public static func displayed(_ text: String, in database: Database, row: Int, column: Int) -> String {
        guard isFormula(text) else { return text }
        var evaluator = Evaluator(database: database)
        return evaluator.display(row: row, column: column)
    }

    public static func isFormula(_ text: String) -> Bool {
        text.hasPrefix("=") && text.count > 1
    }

    /// A column's letters: 0 → A, 25 → Z, 26 → AA.
    public static func columnName(_ index: Int) -> String {
        var index = index
        var name = ""
        repeat {
            name = String(UnicodeScalar(UInt8(65 + index % 26))) + name
            index = index / 26 - 1
        } while index >= 0
        return name
    }

    enum Failure: Error {
        case syntax, reference, divisionByZero, cycle
        var display: String {
            switch self {
            case .syntax: "#ERROR"
            case .reference: "#REF!"
            case .divisionByZero: "#DIV/0!"
            case .cycle: "#CYCLE!"
            }
        }
    }

    /// A value in a formula: a number, a run of cells (from a range), or text.
    enum Value {
        case number(Double)
        case cells([Cell])
        case text(String)
    }

    struct Cell {
        var number: Double?
        var isEmpty: Bool
    }

    /// Row 0 is the header; body row r is `database.rows[r - 1]`.
    struct Evaluator {
        let database: Database
        var evaluating: Set<[Int]> = []
        var cache: [[Int]: Result<Double?, Failure>] = [:]

        func raw(_ row: Int, _ column: Int) -> String? {
            guard database.columns.indices.contains(column), row >= 0, row <= database.rows.count else { return nil }
            let target = database.columns[column]
            if row == 0 { return target.name }
            return target.display(database.rows[row - 1].cells[target.id])
        }

        mutating func display(row: Int, column: Int) -> String {
            switch value(row, column) {
            case .success(let number): number.map(DatabaseFormula.format) ?? (raw(row, column) ?? "")
            case .failure(let failure): failure.display
            }
        }

        /// A cell's number: its formula's result, or its text read as a number.
        mutating func value(_ row: Int, _ column: Int) -> Result<Double?, Failure> {
            let key = [row, column]
            if let cached = cache[key] { return cached }
            guard let text = raw(row, column) else { return .failure(.reference) }
            guard DatabaseFormula.isFormula(text) else { return .success(DatabaseFormula.number(text)) }
            guard !evaluating.contains(key) else { return .failure(.cycle) }
            evaluating.insert(key)
            defer { evaluating.remove(key) }
            var parser = Parser(source: String(text.dropFirst()), row: row, column: column)
            let result: Result<Double?, Failure>
            do {
                let expression = try parser.parse()
                result = .success(try number(of: expression))
            } catch let failure as Failure {
                result = .failure(failure)
            } catch {
                result = .failure(.syntax)
            }
            cache[key] = result
            return result
        }

        mutating func number(of expression: Expression) throws -> Double {
            switch try evaluate(expression) {
            case .number(let number): return number
            case .cells(let cells):
                guard cells.count == 1 else { throw Failure.syntax }
                return cells[0].number ?? 0
            case .text: throw Failure.syntax
            }
        }

        mutating func cells(_ rows: ClosedRange<Int>, _ columns: ClosedRange<Int>) throws -> [Cell] {
            var cells: [Cell] = []
            for row in rows {
                for column in columns {
                    guard raw(row, column) != nil else { throw Failure.reference }
                    let number = try value(row, column).get()
                    cells.append(Cell(number: number, isEmpty: (raw(row, column) ?? "").isEmpty))
                }
            }
            return cells
        }

        mutating func evaluate(_ expression: Expression) throws -> Value {
            switch expression {
            case .number(let number):
                return .number(number)
            case .reference(let row, let column):
                return .cells(try cells(row...row, column...column))
            case .range(let fromRow, let fromColumn, let toRow, let toColumn):
                return .cells(try cells(min(fromRow, toRow)...max(fromRow, toRow), min(fromColumn, toColumn)...max(fromColumn, toColumn)))
            case .direction(let direction, let row, let column):
                switch direction {
                case .above: return .cells(row > 1 ? try cells(1...(row - 1), column...column) : [])
                case .below: return .cells(row < database.rows.count ? try cells((row + 1)...database.rows.count, column...column) : [])
                case .left: return .cells(column > 0 && row > 0 ? try cells(row...row, 0...(column - 1)) : [])
                case .right: return .cells(column + 1 < database.columns.count && row > 0 ? try cells(row...row, (column + 1)...(database.columns.count - 1)) : [])
                }
            case .negate(let inner):
                return .number(-(try number(of: inner)))
            case .binary(let op, let lhs, let rhs):
                let a = try number(of: lhs), b = try number(of: rhs)
                switch op {
                case "+": return .number(a + b)
                case "-": return .number(a - b)
                case "*": return .number(a * b)
                case "/":
                    guard b != 0 else { throw Failure.divisionByZero }
                    return .number(a / b)
                case "^": return .number(pow(a, b))
                default: throw Failure.syntax
                }
            case .call(let name, let arguments):
                return .number(try call(name, arguments))
            }
        }

        /// The numbers of a function's arguments, ranges flattened (empty and text cells skipped).
        mutating func numbers(_ arguments: [Expression]) throws -> (numbers: [Double], filled: Int) {
            var numbers: [Double] = []
            var filled = 0
            for argument in arguments {
                switch try evaluate(argument) {
                case .number(let number):
                    numbers.append(number)
                    filled += 1
                case .cells(let cells):
                    numbers += cells.compactMap(\.number)
                    filled += cells.filter { !$0.isEmpty }.count
                case .text(let text):
                    filled += text.isEmpty ? 0 : 1
                }
            }
            return (numbers, filled)
        }

        mutating func call(_ name: String, _ arguments: [Expression]) throws -> Double {
            switch name {
            case "ROUND":
                guard (1...2).contains(arguments.count) else { throw Failure.syntax }
                let value = try number(of: arguments[0])
                let places = arguments.count == 2 ? try number(of: arguments[1]) : 0
                let scale = pow(10, places.rounded())
                return (value * scale).rounded() / scale
            case "ABS", "INT", "SIGN":
                guard arguments.count == 1 else { throw Failure.syntax }
                let value = try number(of: arguments[0])
                switch name {
                case "ABS": return abs(value)
                case "INT": return value.rounded(.towardZero)
                default: return value > 0 ? 1 : value < 0 ? -1 : 0
                }
            default:
                let (values, filled) = try numbers(arguments)
                switch name {
                case "SUM": return values.reduce(0, +)
                case "PRODUCT": return values.isEmpty ? 0 : values.reduce(1, *)
                case "AVERAGE":
                    guard !values.isEmpty else { throw Failure.divisionByZero }
                    return values.reduce(0, +) / Double(values.count)
                case "COUNT": return Double(values.count)
                case "COUNTA": return Double(filled)
                case "MIN": return values.min() ?? 0
                case "MAX": return values.max() ?? 0
                case "MEDIAN":
                    guard !values.isEmpty else { throw Failure.syntax }
                    let sorted = values.sorted()
                    let middle = sorted.count / 2
                    return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
                case "MODE":
                    guard !values.isEmpty else { throw Failure.syntax }
                    var counts: [Double: Int] = [:]
                    for value in values { counts[value, default: 0] += 1 }
                    let best = counts.values.max() ?? 0
                    return values.first { counts[$0] == best } ?? values[0]
                default: throw Failure.syntax
                }
            }
        }
    }

    enum Direction { case above, below, left, right }

    indirect enum Expression {
        case number(Double)
        case reference(row: Int, column: Int)
        case range(fromRow: Int, fromColumn: Int, toRow: Int, toColumn: Int)
        case direction(Direction, row: Int, column: Int)
        case negate(Expression)
        case binary(Character, Expression, Expression)
        case call(String, [Expression])
    }

    /// Recursive descent: sum := product (('+'|'-') product)*, product := power
    /// (('*'|'/') power)*, power := unary ('^' unary)?, unary := '-' unary | atom.
    struct Parser {
        let characters: [Character]
        var index = 0
        /// The formula's own cell (for ABOVE and the like).
        let row: Int
        let column: Int

        init(source: String, row: Int, column: Int) {
            characters = Array(source)
            self.row = row
            self.column = column
        }

        mutating func parse() throws -> Expression {
            let expression = try sum()
            skipSpaces()
            guard index == characters.count else { throw Failure.syntax }
            return expression
        }

        mutating func skipSpaces() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }

        mutating func peek() -> Character? {
            skipSpaces()
            return index < characters.count ? characters[index] : nil
        }

        mutating func sum() throws -> Expression {
            var lhs = try product()
            while let op = peek(), op == "+" || op == "-" {
                index += 1
                lhs = .binary(op, lhs, try product())
            }
            return lhs
        }

        mutating func product() throws -> Expression {
            var lhs = try power()
            while let op = peek(), op == "*" || op == "/" {
                index += 1
                lhs = .binary(op, lhs, try power())
            }
            return lhs
        }

        mutating func power() throws -> Expression {
            let base = try unary()
            if peek() == "^" {
                index += 1
                return .binary("^", base, try unary())
            }
            return base
        }

        mutating func unary() throws -> Expression {
            if peek() == "-" {
                index += 1
                return .negate(try unary())
            }
            if peek() == "+" { index += 1 }
            return try atom()
        }

        mutating func atom() throws -> Expression {
            guard let next = peek() else { throw Failure.syntax }
            if next == "(" {
                index += 1
                let inner = try sum()
                guard peek() == ")" else { throw Failure.syntax }
                index += 1
                return inner
            }
            if next.isNumber || next == "." {
                let start = index
                while index < characters.count, characters[index].isNumber || characters[index] == "." { index += 1 }
                guard let number = Double(String(characters[start..<index])) else { throw Failure.syntax }
                if index < characters.count, characters[index] == "%" {
                    index += 1
                    return .number(number / 100)
                }
                return .number(number)
            }
            guard next.isLetter else { throw Failure.syntax }
            let start = index
            while index < characters.count, characters[index].isLetter || characters[index].isNumber { index += 1 }
            let word = String(characters[start..<index]).uppercased()
            if peek() == "(" {
                index += 1
                var arguments: [Expression] = []
                if peek() != ")" {
                    repeat {
                        if peek() == "," || peek() == ";" { index += 1 }
                        arguments.append(try argument())
                    } while peek() == "," || peek() == ";"
                }
                guard peek() == ")" else { throw Failure.syntax }
                index += 1
                return .call(word, arguments)
            }
            switch word {
            case "ABOVE": return .direction(.above, row: row, column: column)
            case "BELOW": return .direction(.below, row: row, column: column)
            case "LEFT": return .direction(.left, row: row, column: column)
            case "RIGHT": return .direction(.right, row: row, column: column)
            default: break
            }
            guard let (refRow, refColumn) = Self.reference(word) else { throw Failure.syntax }
            if peek() == ":" {
                index += 1
                skipSpaces()
                let start = index
                while index < characters.count, characters[index].isLetter || characters[index].isNumber { index += 1 }
                guard let (toRow, toColumn) = Self.reference(String(characters[start..<index]).uppercased()) else { throw Failure.syntax }
                return .range(fromRow: refRow, fromColumn: refColumn, toRow: toRow, toColumn: toColumn)
            }
            return .reference(row: refRow, column: refColumn)
        }

        mutating func argument() throws -> Expression {
            try sum()
        }

        /// `B2` → (row 1, column 1): row 1 is the header (0), so body rows start at B2.
        static func reference(_ word: String) -> (Int, Int)? {
            let letters = word.prefix { $0.isLetter }
            let digits = word.dropFirst(letters.count)
            guard !letters.isEmpty, !digits.isEmpty, digits.allSatisfy(\.isNumber), let number = Int(digits), number >= 1 else { return nil }
            var column = 0
            for letter in letters {
                guard let ascii = letter.asciiValue, (65...90).contains(ascii) else { return nil }
                column = column * 26 + Int(ascii - 64)
            }
            return (number - 1, column - 1)
        }
    }

    /// A cell's text as a number: "1,234.5", "21%" (0.21), "$12", "¥8"; nil if it isn't one.
    static func number(_ text: String) -> Double? {
        var trimmed = String(text.drop(while: \.isWhitespace).reversed().drop(while: \.isWhitespace).reversed())
        guard !trimmed.isEmpty else { return nil }
        var scale = 1.0
        if trimmed.hasSuffix("%") {
            trimmed.removeLast()
            scale = 0.01
        }
        trimmed = trimmed.filter { $0 != "," && !"$€£¥￥".contains($0) }
        return Double(trimmed).map { $0 * scale }
    }

    /// A result as a cell shows it: whole numbers without decimals, others rounded to
    /// 10 places (so 0.1 + 0.2 reads 0.3).
    static func format(_ number: Double) -> String {
        guard number.isFinite else { return Failure.syntax.display }
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        let rounded = (number * 1e10).rounded() / 1e10
        return rounded == rounded.rounded() && abs(rounded) < 1e15 ? String(Int64(rounded)) : String(rounded)
    }
}
