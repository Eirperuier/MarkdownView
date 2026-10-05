//
//  DocDemoCorpus.swift
//  DemoApp
//
//  The sample document (the chat corpus's replies as sections, long enough to scroll
//  like the chat benchmark) and what the scripted agent writes into it.
//

import Foundation

enum DocDemoCorpus {
    static let sections = 24

    static let document: String = {
        var parts = ["# 文档示例\n\n这篇文档由 DocKit 载入：每一块是列表里的一行，块 id 终身不变。点「Agent 演示」，看 agent 在文档里插入、改一句、改写、删除和移动。", """
        - 每一块都能直接编辑：回车拆块，块首退格合并或退出列表
          - 嵌套列表的缩进和符号是 MarkdownView 自己的
            1. 编号也一样
            2. Tab 缩进，空项回车退一层
        - 行首输入 `# `、`- `、`1. `、`> ` 改块的类型
        """]
        for index in 0..<sections {
            parts.append("## 第 \(index + 1) 节 · \(ChatCorpus.prompt(index))")
            parts.append(ChatCorpus.reply(index))
        }
        return parts.joined(separator: "\n\n")
    }()

    static let inserted = """
        Before anything else, decide **which cell is the anchor**: the first one whose top is on screen is the usual choice, because it is the one the reader is looking at.

        - Record its id and its distance from the top of the viewport.
        - After the update, scroll by the difference — never by the inserted height, which is only an estimate until the new cells are measured.
        """

    static let rewritten = """
        这周睡眠**更规律了**：七天里有五天在 23:30 前入睡，平均时长 7 小时 12 分，比上周多 18 分钟。深睡占比稳定在 21% 左右，周四那晚最短，只有 5 小时 40 分。
        """

    static func chunks(of text: String) -> [String] {
        ChatCorpus.chunks(of: text)
    }
}
