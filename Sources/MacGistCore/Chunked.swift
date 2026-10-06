import Foundation

/// Incremental decoder for `Transfer-Encoding: chunked` request bodies
/// (what `curl -T -` sends when reading stdin).
public struct ChunkedDecoder {
    public enum DecodeError: Error { case malformed }

    private enum State { case size, data(UInt64), dataEnd, trailer, done }
    private var state = State.size
    private var line = Data()

    public init() {}

    public var isDone: Bool { if case .done = state { return true } else { return false } }

    /// Feeds raw bytes; returns decoded body bytes. Bytes after the final chunk are ignored.
    public mutating func feed(_ input: Data) throws -> Data {
        var out = Data()
        var i = input.startIndex
        while i < input.endIndex {
            switch state {
            case .done:
                return out
            case .size, .dataEnd, .trailer:
                let byte = input[i]
                i += 1
                guard byte == 0x0A else {
                    line.append(byte)
                    if line.count > 4096 { throw DecodeError.malformed }
                    continue
                }
                if line.last == 0x0D { line.removeLast() }
                let text = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                switch state {
                case .size:
                    let hex = text.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                    guard let n = UInt64(hex, radix: 16) else { throw DecodeError.malformed }
                    state = n == 0 ? .trailer : .data(n)
                case .dataEnd:
                    guard text.isEmpty else { throw DecodeError.malformed }
                    state = .size
                case .trailer:
                    if text.isEmpty { state = .done }
                default:
                    break
                }
            case .data(let remaining):
                let take = Int(min(remaining, UInt64(input.endIndex - i)))
                out.append(input[i..<(i + take)])
                i += take
                state = remaining - UInt64(take) == 0 ? .dataEnd : .data(remaining - UInt64(take))
            }
        }
        return out
    }
}
