//
//  MarkdownParseSanitizer.swift
//  MarkdownView
//

enum MarkdownParseSanitizer {
    private struct Fence {
        let marker: Character
        let length: Int
    }

    static func sanitizedForCmark(_ text: String) -> String {
        guard text.contains("~") else { return text }

        var result = String()
        result.reserveCapacity(text.count)

        var index = text.startIndex
        var activeFence: Fence?

        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[index..<lineEnd]
            let includesNewline = lineEnd < text.endIndex
            let nextLine = includesNewline ? text.index(after: lineEnd) : lineEnd

            if let fence = activeFence {
                result.append(contentsOf: text[index..<nextLine])
                if isClosingFence(line, for: fence) {
                    activeFence = nil
                }
            } else if let fence = openingFence(in: line) {
                result.append(contentsOf: text[index..<nextLine])
                activeFence = fence
            } else if isIndentedCodeLine(line) {
                result.append(contentsOf: text[index..<nextLine])
            } else {
                result.append(contentsOf: escapeLoneTildesOutsideInlineCodeAndTags(line))
                if includesNewline {
                    result.append("\n")
                }
            }

            index = nextLine
        }

        return result
    }

    private static func escapeLoneTildesOutsideInlineCodeAndTags(_ text: Substring) -> String {
        var result = String()
        result.reserveCapacity(text.count)

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if character == "`" {
                let runEnd = endOfRun(startingAt: index, in: text, matching: "`")
                let runLength = text.distance(from: index, to: runEnd)
                if let closingEnd = closingBacktickRunEnd(length: runLength, in: text, from: runEnd) {
                    result.append(contentsOf: text[index..<closingEnd])
                    index = closingEnd
                } else {
                    result.append(contentsOf: text[index..<runEnd])
                    index = runEnd
                }
                continue
            }

            if character == "<", let tagEnd = htmlTagEnd(in: text, from: index) {
                result.append(contentsOf: text[index..<tagEnd])
                index = tagEnd
                continue
            }

            if character == "\\" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next] == "~" {
                    result.append(contentsOf: text[index...next])
                    index = text.index(after: next)
                    continue
                }
            }

            if character == "~" {
                let runEnd = endOfRun(startingAt: index, in: text, matching: "~")
                if text.distance(from: index, to: runEnd) == 1 {
                    result.append("\\~")
                } else {
                    result.append(contentsOf: text[index..<runEnd])
                }
                index = runEnd
                continue
            }

            result.append(character)
            index = text.index(after: index)
        }

        return result
    }

    private static func openingFence(in line: Substring) -> Fence? {
        var index = line.startIndex
        var indentation = 0

        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }

        guard indentation <= 3, index < line.endIndex else { return nil }
        let marker = line[index]
        guard marker == "`" || marker == "~" else { return nil }

        let runEnd = endOfRun(startingAt: index, in: line, matching: marker)
        let length = line.distance(from: index, to: runEnd)
        guard length >= 3 else { return nil }

        return Fence(marker: marker, length: length)
    }

    private static func isClosingFence(_ line: Substring, for fence: Fence) -> Bool {
        var index = line.startIndex
        var indentation = 0

        while index < line.endIndex, line[index] == " ", indentation < 4 {
            indentation += 1
            index = line.index(after: index)
        }

        guard indentation <= 3, index < line.endIndex, line[index] == fence.marker else {
            return false
        }

        let runEnd = endOfRun(startingAt: index, in: line, matching: fence.marker)
        let length = line.distance(from: index, to: runEnd)
        guard length >= fence.length else { return false }

        return line[runEnd...].allSatisfy { $0 == " " || $0 == "\t" || $0 == "\r" }
    }

    private static func isIndentedCodeLine(_ line: Substring) -> Bool {
        guard let first = line.first else { return false }
        if first == "\t" { return true }
        return line.prefix(4).allSatisfy { $0 == " " } && line.count >= 4
    }

    private static func closingBacktickRunEnd(
        length: Int,
        in text: Substring,
        from start: Substring.Index
    ) -> Substring.Index? {
        var index = start
        while index < text.endIndex {
            guard text[index] == "`" else {
                index = text.index(after: index)
                continue
            }

            let runEnd = endOfRun(startingAt: index, in: text, matching: "`")
            if text.distance(from: index, to: runEnd) == length {
                return runEnd
            }
            index = runEnd
        }

        return nil
    }

    private static func htmlTagEnd(in text: Substring, from start: Substring.Index) -> Substring.Index? {
        let afterStart = text.index(after: start)
        guard afterStart < text.endIndex else { return nil }

        if text[afterStart...].hasPrefix("!--"),
           let commentEnd = text[afterStart...].range(of: "-->")?.upperBound {
            return commentEnd
        }

        var nameStart = afterStart
        if text[nameStart] == "/" {
            nameStart = text.index(after: nameStart)
        }

        guard nameStart < text.endIndex,
              text[nameStart].isLetter || text[nameStart] == "!" || text[nameStart] == "?"
        else {
            return nil
        }

        guard let close = text[nameStart...].firstIndex(of: ">") else {
            return nil
        }

        return text.index(after: close)
    }

    private static func endOfRun(
        startingAt start: Substring.Index,
        in text: Substring,
        matching marker: Character
    ) -> Substring.Index {
        var index = start
        while index < text.endIndex, text[index] == marker {
            index = text.index(after: index)
        }
        return index
    }
}
