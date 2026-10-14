//
//  DocDemoCorpus.swift
//  DemoApp
//
//  The sample document (the chat corpus's replies as sections, long enough to scroll
//  like the chat benchmark) and what the scripted agent writes into it.
//

import Foundation
import DocKit

enum DocDemoCorpus {
    static let sections = 24

    static let document: String = {
        var parts = ["# 文档示例\n\n这篇文档由 DocKit 载入：每一块是列表里的一行，块 id 终身不变。点「Agent 演示」，看 agent 在文档里插入、改一句、改写、删除和移动。", """
        - 每一块都能直接编辑：回车拆块，块首退格合并或退出列表
          - 嵌套列表的缩进和符号是 MarkdownView 自己的
            1. 编号也一样
            2. Tab 缩进，空项回车退一层
        - 行首输入 `# `、`- `、`1. `、`> ` 改块的类型
        """, attachments, cards, views]
        for index in 0..<sections {
            parts.append("## 第 \(index + 1) 节 · \(ChatCorpus.prompt(index))")
            parts.append(ChatCorpus.reply(index))
        }
        return parts.joined(separator: "\n\n")
    }()

    /// Links, files and an image: the blocks with layouts.
    static let attachments = """
        ## 资料

        [拙政园](https://zh.wikipedia.org/wiki/%E6%8B%99%E6%94%BF%E5%9B%AD "bookmark")

        [平江路历史文化街区](https://zh.wikipedia.org/wiki/%E5%B9%B3%E6%B1%9F%E8%B7%AF "bookmark")

        [苏州两日游路线.pdf](blob:demo-route "file")

        [行程预算.xlsx](blob:demo-budget "file")

        ![平江路](asset:pingjianglu)

        ![拙政园](asset:zhuozhengyuan)
        """

    /// What the app would have found out about the links and files (their pages'
    /// summaries and previews, the files' sizes) and the layouts they're shown in.
    private static let links: [String: (summary: String, image: String, layout: DocLayout)] = [
        "https://zh.wikipedia.org/wiki/%E6%8B%99%E6%94%BF%E5%9B%AD": ("中国四大名园之一，明代园林的代表作，以水为中心，亭台楼榭临水而建。", "asset:zhuozhengyuan", .card),
        "https://zh.wikipedia.org/wiki/%E5%B9%B3%E6%B1%9F%E8%B7%AF": ("苏州保存最完整的古街之一，河街并行，白墙黛瓦。", "asset:pingjianglu", .card),
    ]
    private static let files: [String: (size: Int, layout: DocLayout)] = [
        "blob:demo-route": (2_516_582, .regular),
        "blob:demo-budget": (18_944, .small),
    ]

    /// The sample document, its links and files filled in.
    static func doc(id: DocID) -> Doc {
        var doc = Doc(id: id, markdown: document)
        for index in doc.blocks.indices {
            switch doc.blocks[index].kind {
            case .link(var link):
                guard let found = links[link.url] else { continue }
                (link.summary, link.image, link.layout) = (found.summary, found.image, found.layout)
                doc.blocks[index].kind = .link(link: link)
            case .file(var file):
                guard let found = files[file.source] else { continue }
                (file.size, file.layout) = (found.size, found.layout)
                doc.blocks[index].kind = .file(file: file)
            default:
                continue
            }
        }
        // A collection before the sections: the same tasks as a kanban and as a table.
        if let index = doc.blocks.firstIndex(where: { $0.text.string.hasPrefix("第 1 节") }) {
            let (heading, block, database) = collection()
            doc.databases[database.id] = database
            // A page of the project's own, after the tasks.
            let page = DocBlock(id: .generate(), kind: .page(page: DocPage(doc: .generate(), title: "上线计划")))
            doc.blocks.insert(contentsOf: [heading, block, page], at: index)
        }
        return doc
    }

    /// A project's tasks: who, how far along, when, how long.
    static func collection() -> (heading: DocBlock, block: DocBlock, database: Database) {
        func option(_ name: String, _ color: String? = nil) -> SelectOption { SelectOption(id: .generate(), name: name, color: color) }
        let owners = ["林", "莫", "Priya", "Sam"].map { option($0) }
        let states = [option("未开始", "gray"), option("进行中", "blue"), option("已完成", "green"), option("逾期", "red")]
        let task = Column(id: .generate(), name: "任务", type: .text)
        let owner = Column(id: .generate(), name: "负责人", type: .select(options: owners))
        let state = Column(id: .generate(), name: "状态", type: .select(options: states))
        let due = Column(id: .generate(), name: "截止", type: .date)
        let hours = Column(id: .generate(), name: "工时", type: .number)
        let reviewed = Column(id: .generate(), name: "已评审", type: .checkbox)
        func day(_ day: Int) -> CellValue { .date(value: Timestamp(millisecondsSince1970: (1_791_158_400 + Int64(day - 5) * 86_400) * 1000)) }
        func row(_ title: String, _ who: Int, _ how: Int, _ when: Int, _ time: Double, _ checked: Bool = false) -> Row {
            var cells: [ColumnID: CellValue] = [task.id: .text(value: title), owner.id: .select(option: owners[who].id),
                                                state.id: .select(option: states[how].id), due.id: day(when), hours.id: .number(value: time)]
            if checked { cells[reviewed.id] = .checkbox(value: true) }
            return Row(id: .generate(), cells: cells)
        }
        let database = Database(id: .generate(), columns: [task, owner, state, due, hours, reviewed], rows: [
            row("配置服务里的排序开关", 0, 2, 10, 6, true),
            row("新排序的延迟看板", 1, 3, 12, 4),
            row("上线手册", 1, 2, 11, 3, true),
            row("2k 查询集的相关性评测", 2, 1, 14, 10),
            row("迁移自动补全客户端", 3, 0, 16, 8),
            row("查询时缓存向量", 2, 0, 17, 5),
        ])
        let collection = DocCollection(database: database.id, name: "搜索改版", views: [
            CollectionView(name: "看板", layout: .kanban(groupBy: state.id, hidden: [], sort: [])),
            CollectionView(name: "表格", layout: .table(hidden: [], sort: []), calculations: [hours.id: .sum]),
        ])
        let heading = DocBlock(id: .generate(), kind: .heading(level: 2), text: DocText(string: "任务"))
        return (heading, DocBlock(id: .generate(), kind: .collection(collection: collection)), database)
    }

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
