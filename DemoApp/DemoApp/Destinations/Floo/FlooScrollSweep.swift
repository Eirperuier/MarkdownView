//
//  FlooScrollSweep.swift
//  DemoApp
//
//  `-flooScrollSweep <points per second>`: once the conversation shows, the list is scrolled
//  from its end to its top and back at that speed, frame by frame as a hand would, and the
//  frames are printed as a `BENCH` line. Inside the app, so nothing else is timed with it
//  (computer use reads the accessibility tree as it scrolls, which costs more than the scroll).
//  `-flooScrollSweepDelay <seconds>` (8 by default): how long the conversation settles first.
//

#if DEBUG
import SwiftUI
import MessagingUI

@MainActor
enum FlooScrollSweep {
    static var speed: CGFloat? {
        let value = UserDefaults.standard.double(forKey: "flooScrollSweep")
        return value > 0 ? value : nil
    }

    static func run(_ reader: TiledViewReader<String>, speed: CGFloat) async {
        let delay = UserDefaults.standard.double(forKey: "flooScrollSweepDelay")
        try? await Task.sleep(for: .seconds(delay > 0 ? delay : 8))  // try?: cancelled, swept now
        let clock = FrameClock()
        for direction in [-1.0, 1.0] as [CGFloat] {
            clock.start()
            try? await Task.sleep(for: .milliseconds(100))  // try?: as above
            let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
            var still = 0
            await clock.drive { delta in
                let offset = reader.contentOffsetY()
                reader.scrollToContentOffsetY(offset + direction * speed * CGFloat(delta), animated: false)
                still = abs(reader.contentOffsetY() - offset) < 0.5 ? still + 1 : 0
                return still < 30
            }
            let cpu = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000
            let stats = clock.stop()
            print(String(
                format: "BENCH floo-sweep-%@ speed %.0f  %.0fms  cpu %.0fms  hitch %.1fms/s  p50 %.1f  p95 %.1f  max %.1f  long %d/%d",
                direction < 0 ? "up" : "down", speed, stats.duration * 1000, cpu, stats.hitchMillisecondsPerSecond,
                stats.p50Milliseconds, stats.p95Milliseconds, stats.maxMilliseconds, stats.longFrames, stats.frames
            ))
            fflush(stdout)
        }
    }
}
#endif
