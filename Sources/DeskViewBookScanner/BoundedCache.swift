import Foundation

/// Kleiner Cache mit Obergrenze: Beim Überlauf fliegen die ältesten Einträge.
struct BoundedCache<Key: Hashable, Value> {
    private var storage: [Key: Value] = [:]
    private var order: [Key] = []
    let limit: Int

    init(limit: Int) { self.limit = limit }

    subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                if storage[key] == nil { order.append(key) }
                storage[key] = newValue
                while order.count > limit, let oldest = order.first {
                    order.removeFirst()
                    storage[oldest] = nil
                }
            } else {
                storage[key] = nil
                order.removeAll { $0 == key }
            }
        }
    }

    mutating func removeAll() {
        storage.removeAll()
        order.removeAll()
    }

    mutating func removeAll(where predicate: (Key) -> Bool) {
        for key in order where predicate(key) { storage[key] = nil }
        order.removeAll(where: predicate)
    }
}
