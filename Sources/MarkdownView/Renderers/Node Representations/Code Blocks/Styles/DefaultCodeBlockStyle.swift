//
//  DefaultCodeBlockStyle.swift
//  MarkdownView
//
//  Created by LiYanan2004 on 2025/3/25.
//

import SwiftUI
import UIKit

#if canImport(Highlightr)
  @preconcurrency import Highlightr
#endif

/// Default code block style that applies to a MarkdownView.
public struct DefaultCodeBlockStyle: CodeBlockStyle {
  /// Theme configuration in the current context.
  public var highlighterTheme: CodeHighlighterTheme

  public init(
    highlighterTheme: CodeHighlighterTheme = CodeHighlighterTheme(
      lightModeThemeName: "xcode",
      darkModeThemeName: "dark"
    )
  ) {
    self.highlighterTheme = highlighterTheme
  }

  public func makeBody(configuration: Configuration) -> some View {
    DefaultMarkdownCodeBlock(
      codeBlockConfiguration: configuration,
      theme: highlighterTheme
    )
  }
}

extension CodeBlockStyle where Self == DefaultCodeBlockStyle {
  /// Default code block theme with light theme called "xcode" and dark theme called "dark".
  static public var `default`: DefaultCodeBlockStyle { .init() }

  /// Default code block theme with customized light & dark themes.
  static public func `default`(
    lightTheme: String = "xcode",
    darkTheme: String = "dark"
  ) -> DefaultCodeBlockStyle {
    .init(
      highlighterTheme: CodeHighlighterTheme(
        lightModeThemeName: lightTheme,
        darkModeThemeName: darkTheme
      )
    )
  }
}

extension AttributedString {
  func splitByLines() -> [AttributedString] {
    let nsAttributedString = NSAttributedString(self)
    let string = nsAttributedString.string
    var lines: [AttributedString] = []

    string.enumerateLines { line, _ in
      if let range = string.range(of: line) {
        let nsRange = NSRange(range, in: string)
        let lineAttributedString = nsAttributedString.attributedSubstring(from: nsRange)
        if let attributedLine = try? AttributedString(lineAttributedString, including: \.uiKit) {
          lines.append(attributedLine)
        }
      }
    }

    return lines
  }
}
@available(iOS 16.0, *)
struct TableViewWrapper<Item: Identifiable, Content: View>: UIViewRepresentable {
  let items: [Item]
  let content: (Item) -> Content

  func makeUIView(context: Context) -> UITableView {
    let tableView = UITableView(frame: .zero, style: .plain)
    tableView.dataSource = context.coordinator
    tableView.delegate = context.coordinator

    // 注册使用 UIHostingConfiguration 的 Cell
    tableView.register(UITableViewCell.self, forCellReuseIdentifier: "HostingCell")

    return tableView
  }

  func updateUIView(_ tableView: UITableView, context: Context) {
    context.coordinator.items = items
    tableView.reloadData()
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(items: items, content: content)
  }

  class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
    var items: [Item]
    let content: (Item) -> Content

    init(items: [Item], content: @escaping (Item) -> Content) {
      self.items = items
      self.content = content
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
      return items.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
      let cell = tableView.dequeueReusableCell(withIdentifier: "HostingCell", for: indexPath)
      let item = items[indexPath.row]

      // **使用 UIHostingConfiguration 配置 Cell**
      cell.contentConfiguration = UIHostingConfiguration {
        content(item)
      }
      .margins(.all, 0)  // 移除默认边距

      return cell
    }
  }
}

extension Collection {
  func prefix(_ maxLength: Int?) -> SubSequence {
    guard let maxLength = maxLength else {
      return self[...]
    }
    return prefix(maxLength)
  }
}
// MARK: - Default View Implementation

struct DefaultMarkdownCodeBlock: View {
  var codeBlockConfiguration: CodeBlockStyleConfiguration

  var theme: CodeHighlighterTheme
  @Environment(\.colorScheme) private var colorScheme

  @Environment(\.markdownFontGroup) private var fontGroup

  @State private var attributedCode: AttributedString?
  @State private var codeHighlightTask: Task<Void, Error>?
  @State var showFullSheet: Bool = false
  @State private var showCopyButton = false
  @State private var codeCopied = false

  var codeSource: some View {
    Group {
      if let attributedCode {
        let lines = attributedCode.splitByLines()
        ForEach(
          Array(lines.enumerated()).prefix(codeBlockConfiguration.showFullCode ? nil : 15),
          id: \.offset
        ) { index, line in
          HStack(alignment: .top) {
            if #available(iOS 16.4, *) {
              Text("\(index + 1)")
                .font(.subheadline)
                .monospaced()
                .frame(width: 30, alignment: .trailing)
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.5)
            } else {
              // Fallback on earlier versions
            }
            Rectangle()
              .frame(width: 1).foregroundStyle(.gray.opacity(0.2))
              .padding(.vertical, -3)
            Text(line)
              .padding(.horizontal, 5)
            Spacer(minLength: 0)
          }
          .padding(.vertical, 3)
          .background {
            if index % 2 != 0 {
              Rectangle()
                .foregroundStyle(.tertiary.opacity(0.1))
            }

          }
        }
        if lines.count > 15 && !codeBlockConfiguration.showFullCode {
          Divider()
          Button(
            action: {
              showFullSheet = true
            },
            label: {

              HStack {
                Spacer(minLength: 0)
                Text("Show the Remaining \(lines.count - 15) lines")

                  .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
              }
              .padding(10)
            })
        }
        //
      } else {
        //Text(codeBlockConfiguration.code)
        let lines = codeBlockConfiguration.code.components(separatedBy: .newlines)
        ForEach(
          Array(lines.enumerated()).prefix(codeBlockConfiguration.showFullCode ? nil : 15),
          id: \.offset
        ) { index, line in
          HStack(alignment: .top) {
            if #available(iOS 16.4, *) {
              Text("\(index + 1)")
                .font(.subheadline)
                .monospaced()
                .frame(width: 30, alignment: .trailing)
                .foregroundStyle(.secondary)
                .minimumScaleFactor(0.5)
            } else {
              // Fallback on earlier versions
            }
            Rectangle()
              .frame(width: 1).foregroundStyle(.gray.opacity(0.2))
              .padding(.vertical, -3)
            Text(verbatim: line)
              .padding(.horizontal, 5)
            Spacer(minLength: 0)
          }
          .padding(.vertical, 3)

          .background {
            if index % 2 != 0 {
              Rectangle()
                .foregroundStyle(.tertiary.opacity(0.1))
            }

          }
        }
        if lines.count > 15 && !codeBlockConfiguration.showFullCode {
          Divider()
          Button(
            action: {
              showFullSheet = true
            },
            label: {

              HStack {
                Spacer(minLength: 0)
                Text("Show the Remaining \(lines.count - 15) lines")

                  .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
              }
              .padding(10)
            })
        }
      }
    }

  }

  var code: some View {
    VStack(alignment: .leading, spacing: 0) {
      codeSource
    }
    //.task(id: codeHighlightingConfiguration, debouncedHighlight)
    //        .onValueChange(codeBlockConfiguration) {
    //            debouncedHighlight()
    //        }
    .font(fontGroup.codeBlock)
  }
  @Namespace var namespace
  var body: some View {
    if #available(iOS 18.0, *) {
      code
        .frame(maxWidth: .infinity, alignment: .leading)
        //.frame(maxHeight: codeBlockConfiguration.showFullCode ? nil : 300)
        #if os(macOS) || os(iOS)
          .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
              codeLanguage
              if !codeBlockConfiguration.showFullCode {
                fullSheet
              }

              Spacer(minLength: 10)
              copyButton
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .background {
              Rectangle().foregroundStyle(
                colorScheme == .dark ? .gray.opacity(0.1) : .white.opacity(0.5))
            }

          }
          .background {
            RoundedRectangle(cornerRadius: 15)
            .foregroundStyle(colorScheme == .dark ? .gray.opacity(0.1) : .white.opacity(0.5))
          }
          .clipShape(RoundedRectangle(cornerRadius: 15))
        //.matchedTransitionSource(id: codeBlockConfiguration.code, in: namespace)
        #endif

        .sheet(
          isPresented: $showFullSheet,
          content: {
            var configuration: CodeBlockStyleConfiguration {
              var conf = configuration
              conf.showFullCode = true
              return conf
            }
            if #available(iOS 18.0, *) {
              NavigationStack {
                ScrollView {
                  LazyVStack(spacing: 0) {
                    Group {
                      if let attributedCode {
                        let lines = attributedCode.splitByLines()
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                          HStack(alignment: .top) {
                            if #available(iOS 16.4, *) {
                              Text("\(index + 1)")
                                .font(.subheadline)
                                .monospaced()
                                .frame(width: 30, alignment: .trailing)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.5)
                            } else {
                              // Fallback on earlier versions
                            }
                            Rectangle()
                              .frame(width: 1).foregroundStyle(.gray.opacity(0.2))
                              .padding(.vertical, -3)
                            Text(line)
                              .padding(.horizontal, 5)
                            Spacer(minLength: 0)
                          }
                          .padding(.vertical, 3)
                          .background {
                            if index % 2 != 0 {
                              Rectangle()
                                .foregroundStyle(.tertiary.opacity(0.1))
                            }

                          }
                        }

                      } else {
                        //Text(codeBlockConfiguration.code)
                        let lines = codeBlockConfiguration.code.components(separatedBy: .newlines)
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                          HStack(alignment: .top) {
                            if #available(iOS 16.4, *) {
                              Text("\(index + 1)")
                                .font(.subheadline)
                                .monospaced()
                                .frame(width: 30, alignment: .trailing)
                                .foregroundStyle(.secondary)
                                .minimumScaleFactor(0.5)
                            } else {
                              // Fallback on earlier versions
                            }
                            Rectangle()
                              .frame(width: 1).foregroundStyle(.gray.opacity(0.2))
                              .padding(.vertical, -3)
                            Text(verbatim: line)
                              .padding(.horizontal, 5)
                            Spacer(minLength: 0)
                          }
                          .padding(.vertical, 3)

                          .background {
                            if index % 2 != 0 {
                              Rectangle()
                                .foregroundStyle(.tertiary.opacity(0.1))
                            }

                          }
                        }
                      }
                    }
                  }
                  .font(fontGroup.codeBlock)
                  .task {
                    debouncedHighlight()
                  }
                }
                .toolbar {

                  ToolbarItem(
                    placement: .primaryAction,
                    content: {
                      Button {
                        #if os(macOS)
                          NSPasteboard.general.clearContents()
                          NSPasteboard.general.setString(
                            codeBlockConfiguration.code, forType: .string)
                        #elseif os(iOS) || os(visionOS)
                          UIPasteboard.general.string = codeBlockConfiguration.code
                        #endif
                        Task {
                          withAnimation(.spring()) {
                            codeCopied = true
                          }
                          try await Task.sleep(nanoseconds: 2_000_000_000)
                          withAnimation(.spring()) {
                            codeCopied = false
                          }
                        }
                      } label: {
                        Group {
                          if codeCopied {
                            Label("Copied", systemImage: "checkmark")
                          } else {
                            Label("Copy", systemImage: "square.on.square")
                          }
                        }
                      }
                    })
                }
              }
              //.presentationBackground(.thickMaterial)
              //.navigationTransition(.zoom(sourceID: codeBlockConfiguration.code, in: namespace))
            }

          })
    } else {
      // Fallback on earlier versions
    }
  }
  private var fullSheet: some View {
    Button(
      action: {
        showFullSheet = true
      },
      label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
          .font(.footnote)
          .foregroundStyle(.secondary)
      })
  }

  @ViewBuilder
  private var codeLanguage: some View {
    if let language = codeBlockConfiguration.language {
      Text(language.localizedCapitalized)
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }

  private func debouncedHighlight() {

    codeHighlightTask?.cancel()
    codeHighlightTask = Task.detached(priority: .background) {
      try await updateAttributeCode()
      try await Task.sleep(nanoseconds: 200_000_000)  // 0.2 seconds
      try await highlight()
    }
  }

  private func updateAttributeCode() async throws {
    guard var attributedCode = attributedCode else { return }
    let characters = attributedCode.characters

    for difference in codeBlockConfiguration.code.difference(from: characters) {
      try Task.checkCancellation()

      switch difference {
      case .insert(let offset, let insertion, _):
        let insertionPoint = attributedCode.index(
          attributedCode.startIndex,
          offsetByCharacters: offset
        )
        attributedCode.insert(
          AttributedString(String(insertion)),
          at: insertionPoint
        )
      case .remove(let offset, _, _):
        let removalLowerBound = attributedCode.index(
          attributedCode.startIndex, offsetByCharacters: offset)
        let removalUpperBound = attributedCode.index(afterCharacter: removalLowerBound)
        attributedCode.removeSubrange(removalLowerBound..<removalUpperBound)
      }
    }

    try Task.checkCancellation()
    await MainActor.run {
      self.attributedCode = attributedCode
    }
  }

  private func immediateHighlight() async {
    do {
      try await highlight()
    } catch is CancellationError {
      // The task has been cancelled
    } catch {
      logger.error("\(String(describing: error), privacy: .public)")
    }
  }

  @Sendable
  nonisolated private func highlight() async throws {
    #if canImport(Highlightr)
      try Task.checkCancellation()
      let highlightr = Highlightr()!
      await highlightr.setTheme(to: theme.themeName(for: colorScheme))

      let specifiedLanguage = codeBlockConfiguration.language?.lowercased() ?? ""
      let language = highlightr.supportedLanguages()
        .first(where: { $0.localizedCaseInsensitiveCompare(specifiedLanguage) == .orderedSame })

      try Task.checkCancellation()
      let code = codeBlockConfiguration.code
      guard let highlightedCode = highlightr.highlight(code, as: language) else { return }
      let attributedCode = NSMutableAttributedString(
        attributedString: highlightedCode
      )
      attributedCode.removeAttribute(.font, range: NSMakeRange(0, attributedCode.length))

      try await MainActor.run {
        try Task.checkCancellation()
        self.attributedCode = AttributedString(attributedCode)
      }
    #endif
  }

  private var copyButton: some View {
    Button {
      #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(codeBlockConfiguration.code, forType: .string)
      #elseif os(iOS) || os(visionOS)
        UIPasteboard.general.string = codeBlockConfiguration.code
      #endif
      Task {
        withAnimation(.spring()) {
          codeCopied = true
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        withAnimation(.spring()) {
          codeCopied = false
        }
      }
    } label: {
      Group {
        if codeCopied {
          Label("Copied", systemImage: "checkmark")
            .font(.footnote)
            .transition(.opacity.combined(with: .scale))
        } else {
          Label("Copy", systemImage: "square.on.square")
            .font(.footnote)
            .transition(.opacity.combined(with: .scale))
        }
      }
      .contentShape(.rect)
    }
    .buttonStyle(.accessory)
    .font(.callout.weight(.medium))
    .padding(.horizontal, -4)
  }
}

extension DefaultMarkdownCodeBlock {
  struct CodeHighlightingConfiguration: Hashable, Sendable {
    var theme: CodeHighlighterTheme
    var colorScheme: ColorScheme
  }

  private var codeHighlightingConfiguration: CodeHighlightingConfiguration {
    CodeHighlightingConfiguration(
      theme: theme,
      colorScheme: colorScheme
    )
  }
}

// MARK: - Supplementary

private struct AccessoryButtonStyle: PrimitiveButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    #if os(macOS)
      if #available(macOS 14.0, *) {
        Button(role: configuration.role) {
          configuration.trigger()
        } label: {
          configuration.label
        }
        .buttonStyle(.accessoryBar)
      } else {
        Button(role: configuration.role) {
          configuration.trigger()
        } label: {
          configuration.label
        }
        .buttonStyle(.plain)
      }
    #else
      Button(role: configuration.role) {
        configuration.trigger()
      } label: {
        configuration.label
      }
      .buttonStyle(.plain)
    #endif
  }
}

extension PrimitiveButtonStyle where Self == AccessoryButtonStyle {
  static fileprivate var accessory: AccessoryButtonStyle {
    .init()
  }
}
