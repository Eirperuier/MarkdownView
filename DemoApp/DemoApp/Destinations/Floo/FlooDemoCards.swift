//
//  FlooDemoCards.swift
//  DemoApp
//
//  Cards the demo shows: what gpt-6-luna drew in the cards lab (compose and push samples),
//  their words put into Chinese, and the research and Arcaea cards written for the demo in
//  the same language. The source is fed to a CardSession as a model would stream it.
//

import Foundation

enum FlooDemoCards {
    enum Size { case small, medium }

    struct Card {
        let source: String
        let data: String
        let size: Size
    }

    static let all: [String: Card] = [
        "steps": Card(
            source: #"""
VStack(alignment: .leading, spacing: 14) {
    VStack(alignment: .leading, spacing: 5) {
        Text("步数")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)

        Text("平稳的一周，比平时多")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
    }

    BigValue(value: "6,790", unit: "步/天", tint: .orange, size: 38)

    HStack(spacing: 6) {
        Image(systemName: "arrow.up")
            .font(.caption.weight(.semibold))
        Text("比 30 天平均 \(average_30d.formatted()) 多 310")
            .font(.footnote)
    }
    .foregroundStyle(.secondary)

    HistoryBars(
        values: days.map(\.steps),
        tint: .orange,
        highlights: [1, 3],
        reference: Double(goal),
        referenceLabel: "目标 8000",
        labels: ["9/23", "9/29"]
    )

    Text("7 天里 2 天达标")
        .font(.footnote.weight(.medium))
        .foregroundStyle(.secondary)
}
"""#,
            data: #"""
{"unit": "steps", "goal": 8000, "average_30d": 6480, "days": [{"date": "2026-09-23", "steps": 4210}, {"date": "2026-09-24", "steps": 9120}, {"date": "2026-09-25", "steps": 6030}, {"date": "2026-09-26", "steps": 11240}, {"date": "2026-09-27", "steps": 7310}, {"date": "2026-09-28", "steps": 3980}, {"date": "2026-09-29", "steps": 5640}]}
"""#,
            size: .medium
        ),
        "heart": Card(
            source: #"""
VStack(alignment: .leading, spacing: 14) {
    MetricHeader(
        title: "静息心率",
        systemImage: "heart",
        tint: .pink,
        detail: "9/23–9/29"
    )

    Text("一直在平时的范围里")
        .font(.headline)

    RangeStrip(
        value: health_resting_heart_rate.today,
        low: health_resting_heart_rate.typical_range[0],
        high: health_resting_heart_rate.typical_range[1],
        tint: .pink,
        history: health_resting_heart_rate.days.map { $0.bpm },
        unit: "bpm",
        rangeLabel: "平时"
    )

    Divider()

    HStack(alignment: .center) {
        VStack(alignment: .leading, spacing: 4) {
            Text("昨晚睡眠")
                .font(.subheadline.weight(.semibold))
            BigDuration(minutes: health_sleep.asleep_minutes, tint: .indigo, size: 30)
        }
        Spacer()
        ScoreRing(
            score: health_sleep.score,
            total: 100,
            tint: .indigo,
            label: "\(health_sleep.score)"
        )
        .frame(width: 58, height: 58)
    }

    SleepStages(intervals: health_sleep.stages)
        .frame(height: 100)
}
"""#,
            data: #"""
{"health_resting_heart_rate": {"unit": "bpm", "typical_range": [58, 68], "today": 61, "yesterday": 64, "days": [{"date": "2026-09-23", "bpm": 63}, {"date": "2026-09-24", "bpm": 66}, {"date": "2026-09-25", "bpm": 65}, {"date": "2026-09-26", "bpm": 62}, {"date": "2026-09-27", "bpm": 60}, {"date": "2026-09-28", "bpm": 64}, {"date": "2026-09-29", "bpm": 61}]}, "health_sleep": {"date": "2026-09-29", "in_bed": "2026-09-28T23:42:00", "woke": "2026-09-29T07:31:00", "asleep_minutes": 441, "score": 84, "score_parts": {"duration": [45, 50], "bedtime": [27, 30], "interruptions": [12, 20]}, "average_bedtime": "23:20", "stages_minutes": {"awake": 28, "rem": 96, "core": 251, "deep": 94}, "stages": [{"stage": "core", "start": "23:55", "end": "00:40"}, {"stage": "deep", "start": "00:40", "end": "01:35"}, {"stage": "core", "start": "01:35", "end": "02:30"}, {"stage": "rem", "start": "02:30", "end": "03:05"}, {"stage": "awake", "start": "03:05", "end": "03:15"}, {"stage": "core", "start": "03:15", "end": "04:20"}, {"stage": "deep", "start": "04:20", "end": "04:59"}, {"stage": "rem", "start": "04:59", "end": "05:50"}, {"stage": "core", "start": "05:50", "end": "07:05"}, {"stage": "awake", "start": "07:05", "end": "07:31"}]}}
"""#,
            size: .medium
        ),
        "weather": Card(
            source: #"""
VStack(alignment: .leading, spacing: 6) {
    Label("15 点有雨", systemImage: "cloud.rain.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.cyan)
    BigValue(value: "\(high)°", unit: "/ \(low)°", size: 28)
    Chart {
        ForEach(Array(rain.enumerated()), id: \.offset) { index, chance in
            BarMark(x: .value("Hour", index), y: .value("Rain", max(chance, 4)))
                .foregroundStyle(chance >= 50 ? Color.cyan : Color.gray.opacity(0.25))
                .clipShape(Capsule())
        }
    }
    .chartXAxis(.hidden)
    .chartYAxis(.hidden)
    .chartYScale(domain: 0...100)
    .frame(height: 30)
    HStack {
        Text("7 时")
        Spacer()
        Text("15")
        Spacer()
        Text("22 时")
    }
    .font(.caption2.monospacedDigit())
    .foregroundStyle(.secondary)
}
"""#,
            data: #"""
{"high": 21, "low": 14, "rain": [5, 5, 5, 5, 10, 10, 15, 20, 70, 80, 85, 60, 40, 20, 10, 5]}
"""#,
            size: .small
        ),
        "sleep": Card(
            source: #"""
VStack(alignment: .leading, spacing: 6) {
    Label("睡眠", systemImage: "bed.double.fill")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.indigo)
    BigDuration(minutes: minutes, size: 28)
    let top = nights.max() ?? 1
    HStack(alignment: .bottom, spacing: 4) {
        ForEach(Array(nights.enumerated()), id: \.offset) { index, night in
            Capsule()
                .fill(index == nights.count - 1 ? Color.indigo : Color.gray.opacity(0.25))
                .frame(width: 8, height: max(30 * (night - 300) / (top - 300), 4))
                .frame(maxWidth: .infinity)
        }
    }
    .frame(height: 30, alignment: .bottom)
    HStack {
        Text("周四")
        Spacer()
        Text("昨晚")
    }
    .font(.caption2)
    .foregroundStyle(.secondary)
}
"""#,
            data: #"""
{"minutes": 441, "nights": [402, 388, 415, 430, 396, 405, 441]}
"""#,
            size: .small
        ),
        "rain": Card(
            source: #"""
let big = Font.system(size: 20, weight: .semibold, design: .rounded)
let caps = Font.system(size: 12, weight: .semibold)
ZStack(alignment: .topLeading) {
    // Five minutes a bar from now at the content's left edge, running off the card's right.
    GeometryReader { area in
        let step = (area.size.width - 16) / Double(rain.count)
        let base = area.size.height - 40
        ZStack(alignment: .topLeading) {
            ForEach(Array(rain.enumerated()), id: \.offset) { point in
                let x = 16 + step * (Double(point.offset) + 0.5)
                if point.element > 0 {
                    Capsule().fill(.cyan)
                        .frame(width: 6, height: 8 + point.element * 76)
                        .position(x: x, y: base - (8 + point.element * 76) / 2)
                } else {
                    Circle().fill(.cyan.opacity(0.35)).frame(width: 4, height: 4).position(x: x, y: base - 2)
                }
            }
            Text("现在").font(caps).foregroundStyle(.secondary).position(x: 16 + step * 0.5 + 8, y: base + 18)
            Text("15:00").font(caps).foregroundStyle(.cyan).position(x: 16 + step * 4.5, y: base + 18)
            Text("16:10").font(caps).foregroundStyle(.secondary).position(x: 16 + step * 18.5, y: base + 18)
        }
    }
    .padding(-16)
    HStack(alignment: .firstTextBaseline) {
        Text("22").font(big) + Text(" 分钟后").font(caps).foregroundStyle(.cyan)
        Spacer()
        Text("小雨").font(caps).foregroundStyle(.cyan)
    }
}
.frame(height: 128)
"""#,
            data: #"""
{"rain": [0, 0, 0, 0, 0.3, 0.6, 0.8, 0.9, 0.7, 0.6, 0.8, 1.0, 0.9, 0.7, 0.5, 0.4, 0.3, 0.2, 0.15, 0, 0, 0, 0, 0]}
"""#,
            size: .medium
        ),
        "gpt6": Card(
            source: #"""
VStack(alignment: .leading, spacing: 16) {
    VStack(alignment: .leading, spacing: 4) {
        Text("GPT-6 三档")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.teal)
        Text("跑分差几个点，价钱差 20 倍")
            .font(.title3.weight(.semibold))
    }

    VStack(alignment: .leading, spacing: 8) {
        ForEach(models.enumerated(), id: \.offset) { index, model in
            let tint = index == 0 ? Color.teal : index == 1 ? Color.gray : Color.gray.opacity(0.45)
            HStack(spacing: 8) {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(model.name)
                    .font(.subheadline.weight(index == 0 ? .semibold : .regular))
                    .frame(width: 46, alignment: .leading)
                Capsule().fill(tint).frame(width: max(4, 150 * model.output / 50), height: 8)
                Text(model.price)
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(index == 0 ? Color.teal : Color.secondary)
            }
        }
        Text("每百万输出 token 的价钱")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    Chart {
        ForEach(benchmarks.enumerated(), id: \.offset) { _, bench in
            RuleMark(xStart: .value("低", bench.luna), xEnd: .value("高", bench.astra), y: .value("评测", bench.name))
                .foregroundStyle(Color.gray.opacity(0.2))
                .lineStyle(StrokeStyle(lineWidth: 6, lineCap: .round))
            PointMark(x: .value("分", bench.astra), y: .value("评测", bench.name))
                .foregroundStyle(Color.gray.opacity(0.45))
                .symbolSize(45)
            PointMark(x: .value("分", bench.sol), y: .value("评测", bench.name))
                .foregroundStyle(Color.gray)
                .symbolSize(45)
            PointMark(x: .value("分", bench.luna), y: .value("评测", bench.name))
                .foregroundStyle(Color.teal)
                .symbolSize(70)
        }
    }
    .chartXScale(domain: 0...100)
    .chartXAxis {
        AxisMarks(values: [0, 50, 100]) { value in
            AxisGridLine()
            AxisValueLabel {
                Text("\(value.as(Double.self) ?? 0, specifier: "%.0f")%")
            }
        }
    }
    .chartYAxis {
        AxisMarks(position: .leading) { _ in
            AxisValueLabel()
        }
    }
    .frame(height: 170)
}
"""#,
            data: #"""
{"models": [{"name": "Luna", "output": 0.5, "price": "$0.50"}, {"name": "Sol", "output": 10, "price": "$10"}, {"name": "Astra", "output": 50, "price": "$50"}], "benchmarks": [{"name": "业务流程", "luna": 20.7, "sol": 33.2, "astra": 41.4}, {"name": "综合 agent", "luna": 50.9, "sol": 56.4, "astra": 59.3}, {"name": "写代码", "luna": 42.4, "sol": 49.3, "astra": 53.4}, {"name": "长软件任务", "luna": 66.6, "sol": 68.8, "astra": 74.1}, {"name": "操作电脑", "luna": 52.7, "sol": 64.4, "astra": 73.5}]}
"""#,
            size: .medium
        ),
        "cost": Card(
            source: #"""
VStack(alignment: .leading, spacing: 14) {
    VStack(alignment: .leading, spacing: 4) {
        Text("floo 这周的用量")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.teal)
        Text("换成 Sol，一周多花 $114")
            .font(.title3.weight(.semibold))
    }

    CompareBars(items: options, tint: .teal)

    Text("输入 \(input) 万 token · 输出 \(output) 万 token")
        .font(.footnote)
        .foregroundStyle(.secondary)
}
"""#,
            data: #"""
{"options": [{"label": "luna", "value": 6.02, "text": "$6.02"}, {"label": "6.1 Sol", "value": 120.4, "text": "$120.40"}], "input": "4,120", "output": "380"}
"""#,
            size: .medium
        ),
        "g7315": Card(
            source: #"""
VStack(alignment: .leading, spacing: 6) {
    Label("G7315", systemImage: "train.side.front.car")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.indigo)
    HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text("9:15").font(.title3.weight(.bold).monospacedDigit())
        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
        Text("9:48").font(.title3.weight(.bold).monospacedDigit())
    }
    Text("上海虹桥 → 苏州")
        .font(.caption)
        .foregroundStyle(.secondary)
    Text("二等座有票")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.green)
}
"""#,
            data: "{}",
            size: .small
        ),
        "g7001": Card(
            source: #"""
VStack(alignment: .leading, spacing: 6) {
    Label("G7001", systemImage: "train.side.front.car")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.indigo)
    HStack(alignment: .firstTextBaseline, spacing: 5) {
        Text("8:05").font(.title3.weight(.bold).monospacedDigit())
        Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
        Text("8:40").font(.title3.weight(.bold).monospacedDigit())
    }
    Text("上海虹桥 → 苏州")
        .font(.caption)
        .foregroundStyle(.secondary)
    Text("只剩一等座")
        .font(.caption2.weight(.medium))
        .foregroundStyle(.orange)
}
"""#,
            data: "{}",
            size: .small
        ),
        "arcaea": Card(
            source: #"""
VStack(alignment: .leading, spacing: 14) {
    VStack(alignment: .leading, spacing: 4) {
        Text("单曲潜力值")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.purple)
        Text("定数 10.5 打到 986 万，就在摘星线上")
            .font(.title3.weight(.semibold))
    }

    Chart {
        RuleMark(y: .value("摘星", 12.0))
            .foregroundStyle(Color.orange)
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        RuleMark(x: .value("拐点", 980))
            .foregroundStyle(Color.gray.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        ForEach(points.enumerated(), id: \.offset) { _, point in
            LineMark(x: .value("分数", point.score), y: .value("潜力值", point.value), series: .value("谱", point.chart))
                .foregroundStyle(point.chart == "10.5" ? Color.purple : Color.purple.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: point.chart == "10.5" ? 3 : 2, lineCap: .round))
        }
        ForEach(crossings.enumerated(), id: \.offset) { index, crossing in
            PointMark(x: .value("分数", crossing), y: .value("潜力值", 12.0))
                .foregroundStyle(index == 0 ? Color.purple : Color.purple.opacity(0.45))
                .symbolSize(60)
        }
    }
    .chartXScale(domain: 950...1000)
    .chartYScale(domain: 10...13)
    .chartXAxis {
        AxisMarks(values: [950, 980, 1000]) { value in
            AxisValueLabel {
                Text("\(value.as(Double.self) ?? 0, specifier: "%.0f") 万")
            }
        }
    }
    .chartYAxis {
        AxisMarks(position: .leading, values: [10, 11, 12, 13])
    }
    .frame(height: 170)

    HStack(spacing: 14) {
        HStack(spacing: 5) {
            Capsule().fill(Color.purple).frame(width: 14, height: 3)
            Text("定数 10.5")
        }
        HStack(spacing: 5) {
            Capsule().fill(Color.purple.opacity(0.35)).frame(width: 14, height: 3)
            Text("定数 10.0")
        }
        HStack(spacing: 5) {
            Capsule().fill(Color.orange).frame(width: 14, height: 2)
            Text("12.00 摘星")
        }
    }
    .font(.caption)
    .foregroundStyle(.secondary)
}
"""#,
            data: #"""
{"points": [{"chart": "10.5", "score": 950, "value": 10.7}, {"chart": "10.5", "score": 980, "value": 11.7}, {"chart": "10.5", "score": 1000, "value": 12.7}, {"chart": "10.0", "score": 950, "value": 10.2}, {"chart": "10.0", "score": 980, "value": 11.2}, {"chart": "10.0", "score": 1000, "value": 12.2}], "crossings": [986, 996]}
"""#,
            size: .medium
        ),
    ]
}
