import Foundation

/// Turns a verification fingerprint (hex) into a few friendly words, so people can
/// confirm a connection by comparing words out loud instead of staring at hex.
/// Same fingerprint → same words on both phones.
enum SafetyWords {
    private static let list: [String] = [
        "apple", "amber", "anchor", "aspen", "basil", "bay", "bear", "berry",
        "birch", "bloom", "breeze", "brook", "cedar", "clay", "clover", "cloud",
        "coral", "cove", "crane", "daisy", "dawn", "deer", "dove", "dune",
        "ember", "fern", "finch", "fox", "frost", "garden", "grove", "harbor",
        "hazel", "heron", "honey", "ivy", "lake", "lark", "leaf", "lily",
        "lotus", "maple", "meadow", "mint", "moon", "moss", "olive", "otter",
        "panda", "peach", "pearl", "pine", "poppy", "quail", "rain", "reed",
        "river", "robin", "sage", "shell", "sky", "snow", "sparrow", "spruce",
        "stone", "storm", "sun", "swan", "thistle", "tide", "topaz", "tulip",
        "vale", "violet", "willow", "wren",
    ]

    static func words(fromHex hex: String, count: Int = 4) -> [String] {
        var bytes: [UInt8] = []
        var i = hex.startIndex
        while i < hex.endIndex, bytes.count < count {
            let next = hex.index(i, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let b = UInt8(hex[i..<next], radix: 16) { bytes.append(b) }
            i = next
        }
        return bytes.map { list[Int($0) % list.count] }
    }
}
