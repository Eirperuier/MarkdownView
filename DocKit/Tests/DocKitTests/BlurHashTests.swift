import Testing

@testable import DocKit

@Suite
struct BlurHashTests {
    /// One colour draws back as that colour where the picture is, a little off at its
    /// edges (BlurHash samples its cosines at the pixels' edges).
    @Test
    func aPlainColourDrawsBack() throws {
        let width = 32, height = 24
        let rgba = [UInt8]((0..<(width * height)).flatMap { _ in [200, 120, 40, 255] as [UInt8] })
        let hash = try #require(BlurHash.encode(rgba: rgba, width: width, height: height, components: (4, 3)))
        #expect(hash.utf8.count == 4 + 2 * 4 * 3)
        let drawn = try #require(BlurHash.decode(hash, width: width, height: height))
        let middle = ((height / 2) * width + width / 2) * 4
        #expect(Array(drawn[middle..<(middle + 4)]) == [200, 120, 40, 255])
        for pixel in stride(from: 0, to: drawn.count, by: 4) {
            #expect(abs(Int(drawn[pixel]) - 200) <= 25 && abs(Int(drawn[pixel + 1]) - 120) <= 15 && abs(Int(drawn[pixel + 2]) - 40) <= 5)
        }
    }

    /// Light on the left and dark on the right stays so, blurred.
    @Test
    func aGradientKeepsItsSides() throws {
        let width = 16, height = 8
        let rgba = (0..<(width * height)).flatMap { index -> [UInt8] in
            let value = UInt8(255 - (index % width) * 255 / (width - 1))
            return [value, value, value, 255]
        }
        let hash = try #require(BlurHash.encode(rgba: rgba, width: width, height: height, components: BlurHash.components(width: width, height: height)))
        let drawn = try #require(BlurHash.decode(hash, width: 8, height: 4))
        let row = (0..<8).map { drawn[$0 * 4] }
        #expect(row[0] > 200 && row[7] < 80 && row[1] > row[6], "\(row)")
    }

    /// The reference implementation's example decodes; what isn't a hash doesn't.
    @Test
    func referenceAndBrokenHashes() {
        #expect(BlurHash.decode("LEHV6nWB2yk8pyo0adR*.7kCMdnj", width: 32, height: 32)?.count == 32 * 32 * 4)
        #expect(BlurHash.decode("LEHV6nWB2yk8", width: 32, height: 32) == nil)
        #expect(BlurHash.decode("LEHV6nWB2yk8pyo0adR*.7kCMdn\u{e9}", width: 32, height: 32) == nil)
    }
}
