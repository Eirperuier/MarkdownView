//
//  Markdown+CJKForkSendable.swift
//  MarkdownTextKit
//
//  upstream 3.0 用官方 swift-markdown(0.8.0,已补 Sendable),本仓库用 CJK fork
//  (cjk-friendly-emphasis,尚未补齐 Sendable)。在此为完整 3.0 渲染栈要求的类型
//  补上 Sendable。Sendable 是 marker protocol(无 runtime conformance record),
//  与 MarkdownView module 中同类扩展并存不会产生链接冲突。
//
//  TODO: swift-markdown CJK fork 适配 Swift 6 后移除。
//

import Markdown

extension Markdown.Document: @retroactive @unchecked Sendable { }
extension Markdown.SourceLocation: @retroactive @unchecked Sendable { }
extension Markdown.Table: @retroactive @unchecked Sendable { }
extension Markdown.Table.Row: @retroactive @unchecked Sendable { }
extension Markdown.OrderedList: @retroactive @unchecked Sendable { }
extension Markdown.UnorderedList: @retroactive @unchecked Sendable { }
extension Markdown.ParseOptions: @retroactive @unchecked Sendable { }
extension Markdown.Heading: @retroactive @unchecked Sendable { }
