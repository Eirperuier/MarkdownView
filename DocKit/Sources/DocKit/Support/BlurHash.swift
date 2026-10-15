import Foundation

/// BlurHash (blurha.sh): an image as a few cosine components of its colours, in a short
/// string, drawn blurred while the image itself isn't here. Pixels are RGBA, 8 bits a
/// channel, rows top to bottom.
public enum BlurHash {
    /// The components across and down for an image this shape: four along its long side,
    /// three along the short one.
    public static func components(width: Int, height: Int) -> (x: Int, y: Int) {
        width >= height ? (4, 3) : (3, 4)
    }

    /// The hash of `rgba` (`width` × `height` pixels); nil if the sizes don't fit it.
    public static func encode(rgba: [UInt8], width: Int, height: Int, components: (x: Int, y: Int)) -> String? {
        guard (1...9).contains(components.x), (1...9).contains(components.y), width > 0, height > 0,
              rgba.count >= width * height * 4
        else { return nil }
        var factors: [(Double, Double, Double)] = []
        for j in 0..<components.y {
            for i in 0..<components.x {
                let normalisation: Double = i == 0 && j == 0 ? 1 : 2
                var r = 0.0, g = 0.0, b = 0.0
                for y in 0..<height {
                    let down = cos(Double.pi * Double(j) * Double(y) / Double(height))
                    for x in 0..<width {
                        let basis = cos(Double.pi * Double(i) * Double(x) / Double(width)) * down
                        let pixel = (y * width + x) * 4
                        r += basis * linear(rgba[pixel])
                        g += basis * linear(rgba[pixel + 1])
                        b += basis * linear(rgba[pixel + 2])
                    }
                }
                let scale = normalisation / Double(width * height)
                factors.append((r * scale, g * scale, b * scale))
            }
        }
        let dc = factors[0]
        let ac = factors.dropFirst()
        var hash = encode83((components.x - 1) + (components.y - 1) * 9, length: 1)
        let maximum: Double
        if ac.isEmpty {
            maximum = 1
            hash += encode83(0, length: 1)
        } else {
            let actual = ac.map { max(abs($0.0), abs($0.1), abs($0.2)) }.max() ?? 0
            let quantised = Int(max(0, min(82, (actual * 166 - 0.5).rounded(.down))))
            maximum = Double(quantised + 1) / 166
            hash += encode83(quantised, length: 1)
        }
        hash += encode83((sRGB(dc.0) << 16) + (sRGB(dc.1) << 8) + sRGB(dc.2), length: 4)
        for factor in ac {
            let quantise = { (value: Double) in
                Int(max(0, min(18, (signedPow(value / maximum, 0.5) * 9 + 9.5).rounded(.down))))
            }
            hash += encode83(quantise(factor.0) * 19 * 19 + quantise(factor.1) * 19 + quantise(factor.2), length: 2)
        }
        return hash
    }

    /// The hash drawn at `width` × `height` pixels (opaque RGBA); nil if it isn't one.
    /// `punch` makes its contrast stronger or weaker.
    public static func decode(_ hash: String, width: Int, height: Int, punch: Double = 1) -> [UInt8]? {
        let digits = Array(hash.utf8)
        guard digits.count >= 6, width > 0, height > 0, let size = decode83(digits[0..<1]) else { return nil }
        let across = size % 9 + 1, down = size / 9 + 1
        guard digits.count == 4 + 2 * across * down, let quantised = decode83(digits[1..<2]),
              let dc = decode83(digits[2..<6])
        else { return nil }
        let maximum = Double(quantised + 1) / 166 * punch
        var colors = [(linear(UInt8(dc >> 16)), linear(UInt8((dc >> 8) & 255)), linear(UInt8(dc & 255)))]
        for index in 1..<(across * down) {
            guard let value = decode83(digits[(4 + index * 2)..<(6 + index * 2)]) else { return nil }
            let component = { (quantised: Int) in signedPow(Double(quantised - 9) / 9, 2) * maximum }
            colors.append((component(value / (19 * 19)), component((value / 19) % 19), component(value % 19)))
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var r = 0.0, g = 0.0, b = 0.0
                for j in 0..<down {
                    let vertical = cos(Double.pi * Double(y) * Double(j) / Double(height))
                    for i in 0..<across {
                        let basis = cos(Double.pi * Double(x) * Double(i) / Double(width)) * vertical
                        let color = colors[i + j * across]
                        r += color.0 * basis
                        g += color.1 * basis
                        b += color.2 * basis
                    }
                }
                let pixel = (y * width + x) * 4
                pixels[pixel] = UInt8(sRGB(r))
                pixels[pixel + 1] = UInt8(sRGB(g))
                pixels[pixel + 2] = UInt8(sRGB(b))
            }
        }
        return pixels
    }

    private static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz#$%*+,-.:;=?@[]^_{|}~".utf8)
    private static let values: [UInt8: Int] = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, $0) })

    private static func encode83(_ value: Int, length: Int) -> String {
        var digits: [UInt8] = []
        var divisor = 1
        for _ in 1..<max(1, length) { divisor *= 83 }
        for _ in 0..<length {
            digits.append(alphabet[(value / divisor) % 83])
            divisor = max(1, divisor / 83)
        }
        return String(decoding: digits, as: UTF8.self)
    }

    private static func decode83(_ digits: ArraySlice<UInt8>) -> Int? {
        var value = 0
        for digit in digits {
            guard let digit = values[digit] else { return nil }
            value = value * 83 + digit
        }
        return value
    }

    private static func linear(_ value: UInt8) -> Double {
        let v = Double(value) / 255
        return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
    }

    private static func sRGB(_ value: Double) -> Int {
        let v = max(0, min(1, value))
        return v <= 0.003_130_8 ? Int(v * 12.92 * 255 + 0.5) : Int((1.055 * pow(v, 1 / 2.4) - 0.055) * 255 + 0.5)
    }

    private static func signedPow(_ value: Double, _ exponent: Double) -> Double {
        let magnitude = pow(abs(value), exponent)
        return value < 0 ? -magnitude : magnitude
    }
}
