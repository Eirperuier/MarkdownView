//
//  FlooWork.swift
//  DemoApp
//
//  An agent's work in its message: one line, where it took the thing on. While it runs, what
//  it's at, a light passing over it; done, what it came to. Opened, how it went: the steps, or
//  the several things it looked into at once, each with what it read.
//

import SwiftUI
import FlooDesign

struct FlooWorkView: View {
    let id: String
    let process: FlooProcess
    let expanded: Bool
    let open: Set<String>
    let tint: Color
    let demo: FlooDemo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                demo.toggle(id)
            } label: {
                HStack(spacing: 8) {
                    FlooWorkGlyph(state: process.waitsForYou ? .waiting : process.running ? .running : .done, tint: tint)
                    Text(process.running ? process.doing ?? "在弄" : process.summary ?? "")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .flooShimmer(process.running && !process.waitsForYou)
                        .id(process.running ? process.doing : process.summary)
                        .transition(.push(from: .bottom).combined(with: .opacity))
                    FlooSources(sources: process.sources)
                    FlooChevron(expanded: expanded)
                }
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded {
                Group {
                    if process.tasks.isEmpty {
                        FlooStepList(steps: process.steps, live: process.running, tint: tint)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(process.tasks) { task in
                                FlooTaskRow(task: task, open: open.contains(task.id), tint: tint) {
                                    demo.toggle("\(id)/\(task.id)")
                                }
                            }
                        }
                    }
                }
                .padding(.top, 10)
                .padding(.leading, 23)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
        .animation(FlooDesignTokens.Motion.layout, value: process)
    }
}

// MARK: - One of the things it looked into

private struct FlooTaskRow: View {
    let task: FlooTask
    let open: Bool
    let tint: Color
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggle) {
                HStack(alignment: .top, spacing: 8) {
                    FlooWorkGlyph(state: task.state, tint: tint, size: 12)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 1) {
                        (Text(task.title).foregroundStyle(task.state == .stopped ? .secondary : .primary)
                            + Text(task.executor.map { "  \($0)" } ?? "").foregroundStyle(.secondary).fontWeight(.regular)
                            + Text(task.added.map { "  \($0) 你加的" } ?? "").foregroundStyle(tint).fontWeight(.regular))
                            .font(.footnote.weight(.medium))
                        Text(task.detail)
                            .font(.caption)
                            .foregroundStyle(task.state == .waiting ? .tertiary : .secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    FlooSources(sources: task.sources)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open, !task.steps.isEmpty {
                FlooStepList(steps: task.steps, live: task.state == .running, tint: tint)
                    .padding(.leading, 20)
            }
        }
    }
}

// MARK: - What it has in hand

/// The things an agent has in hand in this conversation, over the composer when you ask.
struct FlooErrandList: View {
    let errands: [FlooDemo.Errand]
    let jump: (FlooDemo.Errand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(errands.enumerated()), id: \.element.id) { index, errand in
                if index > 0 {
                    Rectangle().fill(.primary.opacity(0.08)).frame(height: 0.5).padding(.leading, 35)
                }
                Button {
                    jump(errand)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        FlooWorkGlyph(state: .running, tint: errand.agent.tint)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(errand.title).font(.subheadline.weight(.medium))
                            Text(errand.doing)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .flooShimmer(true)
                        }
                        Spacer(minLength: 8)
                        Text(errand.since).font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground).opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - Parts

/// Where a piece of work is: turning while it runs, a dashed ring waiting, a check done.
struct FlooWorkGlyph: View {
    let state: FlooTask.State
    let tint: Color
    var size = 15.0

    var body: some View {
        Group {
            switch state {
            case .running:
                TimelineView(.animation) { context in
                    let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    Circle()
                        .trim(from: 0, to: 0.7)
                        .stroke(tint, style: StrokeStyle(lineWidth: size > 13 ? 1.8 : 1.5, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360))
                        .padding(1.5)
                }
            case .waiting:
                Circle()
                    .stroke(.tertiary, style: StrokeStyle(lineWidth: 1.2, dash: [2, 2.2]))
                    .padding(1.5)
            case .done:
                Image(systemName: "checkmark.circle.fill")
                    .resizable()
                    .foregroundStyle(tint.opacity(0.8))
            case .stopped:
                Image(systemName: "minus.circle")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// What it read, as the sites' initials, overlapping.
private struct FlooSources: View {
    let sources: [String]

    var body: some View {
        let shown = Array(sources.prefix(4))
        HStack(spacing: -4) {
            ForEach(shown, id: \.self) { source in
                Text(String(source.prefix(1)).uppercased())
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 15, height: 15)
                    .background(Self.color(source), in: Circle())
                    .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1.2))
            }
            if sources.count > shown.count {
                Text("+\(sources.count - shown.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 7)
            }
        }
    }

    static func color(_ source: String) -> Color {
        let palette: [Color] = [.teal, .indigo, .orange, .pink, .green, .blue, .brown, .purple]
        return palette[source.unicodeScalars.reduce(0) { $0 + Int($1.value) } % palette.count].opacity(0.85)
    }
}

/// The steps of a piece of work, the one it's at in the tint.
private struct FlooStepList: View {
    let steps: [String]
    let live: Bool
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                let current = live && index == steps.count - 1
                HStack(spacing: 8) {
                    Circle()
                        .fill(current ? tint : Color.secondary.opacity(0.35))
                        .frame(width: 4, height: 4)
                    Text(step)
                        .font(.caption)
                        .foregroundStyle(current ? .primary : .secondary)
                }
            }
        }
    }
}

private struct FlooChevron: View {
    let expanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(expanded ? 90 : 0))
    }
}

// MARK: - Shimmer

extension View {
    /// A light passing over the text while the work it names is going on.
    func flooShimmer(_ active: Bool) -> some View {
        modifier(FlooShimmer(active: active))
    }
}

private struct FlooShimmer: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.overlay {
                TimelineView(.animation) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                    GeometryReader { geometry in
                        LinearGradient(
                            colors: [.clear, Color(uiColor: .systemBackground).opacity(0.75), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: geometry.size.width * 0.45)
                        .offset(x: (phase * 1.9 - 0.45) * geometry.size.width)
                    }
                }
                .mask(content)
                .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}
