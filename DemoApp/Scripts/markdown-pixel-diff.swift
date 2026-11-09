#!/usr/bin/env swift
//
//  markdown-pixel-diff.swift
//
//  Compares two folders of catalogue shots, pixel by pixel:
//
//      swift markdown-pixel-diff.swift <baseline> <candidate> [<diff output folder>]
//
//  For each PNG in the baseline: size, how many pixels differ, the largest channel
//  difference, and where. A picture with a difference gets a diff image: differing pixels
//  red over a faded baseline. Exit 0 only when every picture is identical.
//

import AppKit
import CoreGraphics
import Foundation

struct Bitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        width = image.width
        height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        pixels = data
    }
}

func writeDiff(_ baseline: Bitmap, _ candidate: Bitmap, to url: URL) {
    var output = [UInt8](repeating: 255, count: baseline.width * baseline.height * 4)
    for i in stride(from: 0, to: output.count, by: 4) {
        let different = (0..<3).contains { baseline.pixels[i + $0] != candidate.pixels[i + $0] }
        if different {
            output[i] = 255; output[i + 1] = 0; output[i + 2] = 0
        } else {
            for channel in 0..<3 { output[i + channel] = UInt8(200 + Int(baseline.pixels[i + channel]) * 55 / 255) }
        }
    }
    output.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(
            data: buffer.baseAddress, width: baseline.width, height: baseline.height, bitsPerComponent: 8,
            bytesPerRow: baseline.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    print("usage: markdown-pixel-diff <baseline> <candidate> [<diff output folder>]")
    exit(2)
}
let baselineFolder = URL(fileURLWithPath: arguments[1])
let candidateFolder = URL(fileURLWithPath: arguments[2])
let diffFolder = arguments.count > 3 ? URL(fileURLWithPath: arguments[3]) : nil
if let diffFolder { try? FileManager.default.createDirectory(at: diffFolder, withIntermediateDirectories: true) }

let names = ((try? FileManager.default.contentsOfDirectory(atPath: baselineFolder.path)) ?? [])
    .filter { $0.hasSuffix(".png") }
    .sorted()
var identical = 0, different = 0, missing = 0

for name in names {
    guard let baseline = Bitmap(url: baselineFolder.appending(path: name)) else {
        print("UNREADABLE \(name)"); missing += 1; continue
    }
    guard let candidate = Bitmap(url: candidateFolder.appending(path: name)) else {
        print("MISSING    \(name)"); missing += 1; continue
    }
    guard baseline.width == candidate.width, baseline.height == candidate.height else {
        print("SIZE       \(name)  \(baseline.width)x\(baseline.height) vs \(candidate.width)x\(candidate.height)")
        different += 1
        continue
    }
    var count = 0, largest = 0
    var minX = baseline.width, minY = baseline.height, maxX = -1, maxY = -1
    for y in 0..<baseline.height {
        for x in 0..<baseline.width {
            let i = (y * baseline.width + x) * 4
            var delta = 0
            for channel in 0..<3 { delta = max(delta, abs(Int(baseline.pixels[i + channel]) - Int(candidate.pixels[i + channel]))) }
            if delta > 0 {
                count += 1
                largest = max(largest, delta)
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
    }
    if count == 0 {
        identical += 1
    } else {
        different += 1
        print("DIFF       \(name)  \(count) px  max \(largest)  in (\(minX),\(minY))-(\(maxX),\(maxY))")
        if let diffFolder { writeDiff(baseline, candidate, to: diffFolder.appending(path: name)) }
    }
}
print("\(names.count) pictures: \(identical) identical, \(different) different, \(missing) missing")
exit(different == 0 && missing == 0 ? 0 : 1)
