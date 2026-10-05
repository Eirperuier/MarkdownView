extension Doc {
    /// Checks every model invariant; tests run it after every operation.
    /// Throws the first violation found.
    public func validate() throws(DocError) {
        var seen: Set<DocBlockID> = []
        for block in blocks {
            guard seen.insert(block.id).inserted else { throw .duplicateID }
            guard (0...6).contains(block.indent) else { throw .invalidIndent }
            if case .heading(let level) = block.kind, !(1...6).contains(level) {
                throw .invalidHeadingLevel
            }
            if !block.kind.carriesText, !block.text.isEmpty || !block.text.marks.isEmpty {
                throw .emptyTextRequired
            }
            if !block.kind.allowsMarks, !block.text.marks.isEmpty {
                throw .marksNotAllowed
            }
            try block.text.validate()
            if case .database(let id, _) = block.kind, databases[id] == nil {
                throw .databaseNotFound(id)
            }
        }
    }
}

extension DocText {
    /// Marks must be normalized, on scalar boundaries, and obey the atom
    /// rules: every U+FFFC carries exactly one atom span of length 1, and
    /// every atom span sits on a U+FFFC.
    func validate() throws(DocError) {
        var canonical = self
        canonical.normalize()
        guard canonical.marks == marks else { throw .marksNotNormalized }

        let units = [UInt16](string.utf16)
        var atomOffsets = Set<Int>()
        var covering: [Int: Int] = [:]
        for span in marks {
            guard isValidOffset(span.range.lowerBound), isValidOffset(span.range.upperBound) else {
                throw .notScalarBoundary
            }
            guard span.range.lowerBound < span.range.upperBound, span.range.upperBound <= length else {
                throw .offsetOutOfRange
            }
            for offset in span.range where units[offset] == 0xFFFC {
                covering[offset, default: 0] += 1
            }
            if span.mark.kind.isAtom {
                guard span.range.count == 1 else { throw .invalidAtom }
                atomOffsets.insert(span.range.lowerBound)
            }
        }
        for (index, unit) in units.enumerated() where unit == 0xFFFC {
            // One atom span and nothing else may cover the character.
            guard atomOffsets.contains(index), covering[index] == 1 else { throw .invalidAtom }
            atomOffsets.remove(index)
        }
        guard atomOffsets.isEmpty else { throw .invalidAtom }
    }
}
