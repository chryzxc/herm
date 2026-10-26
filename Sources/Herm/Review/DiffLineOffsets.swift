import Foundation

/// TextKit character positions are UTF-16 offsets, including alignment placeholders.
struct DiffLineOffsets {
    let starts: [Int]

    init(lengths: [Int]) {
        var offset = 0
        starts = lengths.map { length in
            defer { offset += length + 1 }
            return offset
        }
    }

    func row(containing character: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let middle = low + (high - low) / 2
            if starts[middle] <= character { low = middle + 1 } else { high = middle }
        }
        return max(0, low - 1)
    }
}
