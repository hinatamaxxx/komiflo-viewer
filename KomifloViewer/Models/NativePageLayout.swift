import Foundation

/// 公式のページ情報を、端末に残さず表示用のタイル配置に変える。
struct NativePageLayout: Equatable {
    static let tileSize = 128
    let width: Int
    let height: Int
    let seed: Int32

    struct Tile: Equatable {
        let sourceX: Int
        let sourceY: Int
        let destinationX: Int
        let destinationY: Int
    }

    init(encoded: [Int64]) throws {
        guard encoded.count == 3, encoded.allSatisfy({ $0 >= Int64(Int32.min) && $0 <= Int64(UInt32.max) }) else {
            throw NativeReaderError.invalidDocument
        }
        let seed = Int32(truncatingIfNeeded: encoded[2])
        let originalWidth = Int(Int32(truncatingIfNeeded: encoded[0]) ^ seed)
        let originalHeight = Int(Int32(truncatingIfNeeded: encoded[1]) ^ seed)
        guard originalWidth > 0, originalHeight > 0, originalWidth <= 10000, originalHeight <= 10000 else {
            throw NativeReaderError.invalidDocument
        }
        let shorter = min(originalWidth, originalHeight)
        let longer = max(originalWidth, originalHeight)
        var target = longer / Self.tileSize * Self.tileSize
        var fittedWidth = 0
        while target > 0 {
            fittedWidth = Int(floor(Double(shorter) / (Double(longer) / Double(target)) + 0.5))
            let tiles = Double(fittedWidth) / Double(Self.tileSize)
            let crop = tiles - floor(tiles) < 0.15
            let paddedWidth = Int(crop ? floor(tiles + 0.5) : ceil(tiles)) * Self.tileSize
            if crop { fittedWidth = paddedWidth }
            if paddedWidth * target < 3_000_000 { break }
            target -= Self.tileSize
        }
        guard target > 0, fittedWidth > 0 else { throw NativeReaderError.invalidDocument }
        self.width = originalWidth < originalHeight ? fittedWidth : target
        self.height = originalWidth < originalHeight ? target : fittedWidth
        self.seed = seed
    }

    var columns: Int { (width + Self.tileSize - 1) / Self.tileSize }
    var rows: Int { (height + Self.tileSize - 1) / Self.tileSize }
    var sourceWidth: Int { columns * Self.tileSize }
    var sourceHeight: Int { rows * Self.tileSize }

    func tiles() -> [Tile] {
        var random = NativePageRandom(seed: String(seed))
        var order = Array(0..<(columns * rows))
        var remaining = order.count
        while remaining > 0 {
            let index = Int(random.next() * Double(remaining))
            remaining -= 1
            order.swapAt(index, remaining)
        }
        let landscape = width > height
        let padding = (landscape ? sourceHeight - height : sourceWidth - width)
        return order.enumerated().map { destination, source in
            let column = destination % columns
            let row = destination / columns
            let edge = landscape ? row == rows - 1 : column == columns - 1
            return Tile(sourceX: source % columns * Self.tileSize, sourceY: source / columns * Self.tileSize,
                        destinationX: column * Self.tileSize - (edge && !landscape ? padding : 0),
                        destinationY: row * Self.tileSize - (edge && landscape ? padding : 0))
        }
    }
}

/// 公式の配信形式が使うUHE PRNG。生成するのは配置だけで、画像やキーは保存しない。
private struct NativePageRandom {
    private var state = [Double](repeating: 0, count: 48)
    private var carry = 1.0
    private var phase = 48
    private var mashState = 4022871197.0
    private let fraction = 2.3283064365386963e-10

    init(seed: String) {
        for index in state.indices { state[index] = mash([32]) }
        _ = mash(Array(seed.utf16))
        for character in seed.utf16 {
            for index in state.indices {
                state[index] -= mash(Array(String(character).utf16))
                if state[index] < 0 { state[index] += 1 }
            }
        }
    }

    private mutating func mash(_ characters: [UInt16]) -> Double {
        for character in characters {
            mashState += Double(character)
            var mixed = 0.02519603282416938 * mashState
            mashState = uint32(mixed)
            mixed -= mashState
            mixed *= mashState
            mashState = uint32(mixed)
            mixed -= mashState
            mashState += 4294967296 * mixed
        }
        return fraction * uint32(mashState)
    }

    private func uint32(_ value: Double) -> Double {
        let result = value.rounded(.towardZero).truncatingRemainder(dividingBy: 4294967296)
        return result < 0 ? result + 4294967296 : result
    }

    private mutating func raw() -> Double {
        phase += 1
        if phase >= state.count { phase = 0 }
        let value = 1768863 * state[phase] + fraction * carry
        carry = floor(value)
        state[phase] = value - carry
        return state[phase]
    }

    mutating func next() -> Double {
        let first = raw()
        let value = first + 1.1102230246251565e-16 * floor(2097152 * raw())
        return floor(Double.greatestFiniteMagnitude * value) / Double.greatestFiniteMagnitude
    }
}
