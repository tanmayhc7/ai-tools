import Foundation

/// Splits a big JSON file into its top-level elements without ever holding the whole file.
///
/// Accepts `[ {...}, {...} ]` (what chat exports use) and also a bare run of objects
/// (`{...}{...}` or JSON Lines). Memory is bounded by the largest single element, which is itself
/// capped: an oversized element is skipped and counted instead of buffered.
struct JSONStreamSplitter {
    enum SplitError: LocalizedError {
        case notJSON
        var errorDescription: String? { "This file isn't a JSON list of conversations." }
    }

    struct Summary: Equatable {
        var elements = 0
        var oversized = 0
        /// The file ended in the middle of an element (or before the closing bracket).
        var truncated = false
    }

    let maxElementBytes: Int
    private(set) var summary = Summary()

    private enum State { case start, topLevelObjects, betweenElements, element, scalar, done }
    private var state = State.start
    private var buffer = Data()
    private var depth = 0
    private var inString = false
    private var escaped = false
    private var skippingOversized = false
    private var elementBytes = 0
    private var sawAnything = false
    private var bomBytesSeen = 0
    /// True when the input is a bare run of objects (JSON Lines) rather than one array.
    private var topLevelWasObjects = false

    init(maxElementBytes: Int = 64 << 20) { self.maxElementBytes = maxElementBytes }

    // ASCII constants
    private static let lbrace: UInt8 = 0x7B, rbrace: UInt8 = 0x7D, lbracket: UInt8 = 0x5B, rbracket: UInt8 = 0x5D
    private static let quote: UInt8 = 0x22, backslash: UInt8 = 0x5C, comma: UInt8 = 0x2C

    private static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x0A || b == 0x0D || b == 0x09 }

    /// Feed the next chunk of the file. `emit` receives the bytes of each complete element.
    mutating func feed(_ chunk: UnsafeRawBufferPointer, emit: (Data) -> Void) throws {
        var i = 0
        let n = chunk.count
        while i < n {
            switch state {
            case .done:
                return

            case .start:
                let b = chunk[i]
                // UTF-8 byte order mark at the very start
                let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
                if bomBytesSeen < 3, b == bom[bomBytesSeen], !sawAnything { bomBytesSeen += 1; i += 1; continue }
                if Self.isSpace(b) { i += 1; continue }
                sawAnything = true
                if b == Self.lbracket { state = .betweenElements; i += 1 }
                else if b == Self.lbrace { state = .topLevelObjects }       // do not consume: it starts an element
                else { throw SplitError.notJSON }

            case .topLevelObjects, .betweenElements:
                let b = chunk[i]
                if Self.isSpace(b) || b == Self.comma { i += 1; continue }
                if state == .betweenElements, b == Self.rbracket { state = .done; return }
                if b == Self.lbrace || b == Self.lbracket {
                    beginElement(); depth = 0; state = .element           // reprocess this byte inside the element
                } else if b == Self.quote {
                    beginElement(); depth = 0; state = .element
                } else if state == .betweenElements {
                    state = .scalar; i += 1                              // number / true / false / null: skip it
                } else {
                    throw SplitError.notJSON
                }

            case .scalar:
                let b = chunk[i]
                if b == Self.comma { state = .betweenElements; i += 1 }
                else if b == Self.rbracket { state = .done; return }
                else { i += 1 }

            case .element:
                let start = i
                var closedAt = -1
                while i < n {
                    let b = chunk[i]
                    if inString {
                        if escaped { escaped = false }
                        else if b == Self.backslash { escaped = true }
                        else if b == Self.quote { inString = false; if depth == 0 { closedAt = i; i += 1; break } }
                    } else if b == Self.quote { inString = true }
                    else if b == Self.lbrace || b == Self.lbracket { depth += 1 }
                    else if b == Self.rbrace || b == Self.rbracket {
                        depth -= 1
                        if depth == 0 { closedAt = i; i += 1; break }
                        if depth < 0 { throw SplitError.notJSON }
                    }
                    i += 1
                }
                let end = closedAt >= 0 ? closedAt + 1 : i
                let length = end - start
                elementBytes += length
                if !skippingOversized {
                    if elementBytes > maxElementBytes {
                        skippingOversized = true; buffer = Data()           // give the memory back
                    } else {
                        buffer.append(chunk.baseAddress!.advanced(by: start).assumingMemoryBound(to: UInt8.self), count: length)
                    }
                }
                if closedAt >= 0 {
                    if skippingOversized { summary.oversized += 1 }
                    else { summary.elements += 1; emit(buffer) }
                    buffer = Data(); skippingOversized = false; elementBytes = 0
                    state = topLevelWasObjects ? .topLevelObjects : .betweenElements
                }
            }
        }
    }

    private mutating func beginElement() {
        // remember which kind of stream we are in, to know where to go after an element closes
        topLevelWasObjects = (state == .topLevelObjects)
        buffer = Data(); elementBytes = 0; skippingOversized = false
        inString = false; escaped = false
    }

    /// Call after the last chunk. Reports whether the file ended cleanly.
    mutating func finish() -> Summary {
        switch state {
        case .done: break
        case .topLevelObjects: break                    // a run of objects has no closing marker
        case .start: summary.truncated = sawAnything == false ? false : true
        default: summary.truncated = true
        }
        return summary
    }
}

extension JSONStreamSplitter {
    /// All elements of an in-memory JSON document. For tests and small inputs.
    static func elements(of data: Data, maxElementBytes: Int = 64 << 20, chunkSize: Int = 1 << 16) throws -> (items: [Data], summary: Summary) {
        var splitter = JSONStreamSplitter(maxElementBytes: maxElementBytes)
        var items: [Data] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunkSize, data.count)
            try data.withUnsafeBytes { raw in
                try splitter.feed(UnsafeRawBufferPointer(rebasing: raw[offset..<end])) { items.append($0) }
            }
            offset = end
        }
        return (items, splitter.finish())
    }
}
