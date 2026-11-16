import Foundation

struct FixedRingBuffer<Element> {
    let capacity: Int
    private var storage: [Element]
    private var writeIndex: Int = 0

    init(capacity: Int, repeating: Element) {
        let cap = max(1, capacity)
        self.capacity = cap
        self.storage = Array(repeating: repeating, count: cap)
    }

    var count: Int {
        capacity
    }

    mutating func append(_ value: Element) {
        storage[writeIndex] = value
        writeIndex = (writeIndex + 1) % capacity
    }

    var values: [Element] {
        if writeIndex == 0 {
            return storage
        }
        return Array(storage[writeIndex..<capacity] + storage[0..<writeIndex])
    }

    var latest: Element {
        let lastIndex = (writeIndex - 1 + capacity) % capacity
        return storage[lastIndex]
    }
}

extension FixedRingBuffer: Equatable where Element: Equatable {
    static func == (lhs: FixedRingBuffer<Element>, rhs: FixedRingBuffer<Element>) -> Bool {
        lhs.values == rhs.values
    }
}

extension FixedRingBuffer: Codable where Element: Codable {}
extension FixedRingBuffer: Sendable where Element: Sendable {}
