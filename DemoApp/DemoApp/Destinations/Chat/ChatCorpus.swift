//
//  ChatCorpus.swift
//  DemoApp
//
//  Sample prompts and replies with the mix of blocks a chat produces: prose, lists,
//  code, tables, math, quotes and CJK text.
//

import Foundation

enum ChatCorpus {
    /// `-chatCorpus text`: replies of only text, to see the text path alone.
    private static let isTextOnly = UserDefaults.standard.string(forKey: "chatCorpus") == "text"
    /// `-chatCorpus interaction`: short rows with known text, for the UI tests.
    private static let isInteraction = UserDefaults.standard.string(forKey: "chatCorpus") == "interaction"
    private static var chosen: [String] { isInteraction ? interactionReplies : isTextOnly ? textReplies : replies }

    private static let interactionReplies = ["""
    Interaction first paragraph with plain words to select in it.

    [Open the test link](https://example.com/drawn) and then some plain words after it.

    - A list item with plain words

    Interaction last paragraph with `inline code` and **bold** words.

    ```swift
    let interactionFirstCodeLine = "plain words to select in code, long enough to go past the width of this block on any device that runs it, which is rather far"
    let two = 2
    let three = 3
    let four = 4
    let five = 5
    let six = 6
    let seven = 7
    let eight = 8
    let nine = 9
    let ten = 10
    let eleven = 11
    let twelve = 12
    let thirteen = 13
    let fourteen = 14
    let fifteen = 15
    let sixteen = 16
    let interactionLastCodeLine = 17
    ```

    Interaction after the code.

    | Table name | Table value | Table third | Table fourth | Table fifth | Table sixth | Table seventh |
    | --- | --- | --- | --- | --- | --- | --- |
    | Table plain words to select | [Table test link](https://example.com/table) | A longer cell of plain words in the third column of the table | Fourth cell | Fifth cell | Sixth cell | Seventh cell |
    | Table second row | Second value | **Table bold** words | `table code` | Fifth two | Sixth two | Seventh two |
    | Table third row | Third value | Third third | Fourth three | Fifth three | Sixth three | Seventh three |
    | Table fourth row | Fourth value | Third four | Fourth four | Fifth four | Sixth four | Seventh four |
    | Table fifth row | Fifth value | Third five | Fourth five | Fifth five | Sixth five | Seventh five |
    | Table sixth row | Sixth value | Third six | Fourth six | Fifth six | Sixth six | Seventh six |

    Interaction after the table.
    """]

    static func prompt(_ index: Int) -> String {
        prompts[index % prompts.count]
    }

    static func reply(_ index: Int) -> String {
        chosen[index % chosen.count]
    }

    /// Every reply back to back: a long answer to stream.
    static let longReply = chosen.joined(separator: "\n\n")

    /// Uneven chunks, like a model's token stream.
    static func chunks(of text: String) -> [String] {
        var chunks: [String] = []
        var rest = Substring(text)
        var size = 3
        while !rest.isEmpty {
            chunks.append(String(rest.prefix(size)))
            rest = rest.dropFirst(size)
            size = size % 11 + 3
        }
        return chunks
    }

    private static let prompts = [
        "How do I keep a chat list from jumping when older messages load?",
        "帮我总结一下这周的睡眠数据",
        "What's the difference between a spring and a timing curve?",
        "Write a function that splits markdown into blocks.",
        "Compare the three options in a table.",
        "Explain the integral of x² from 0 to 1.",
    ]

    /// The same prose as `replies`, its code, tables and display maths written out as text, with
    /// a heading where a chat would have one.
    private static let textReplies = [
        #"""
        ## Keeping the list still

        Loading older messages shifts everything below them, so the list has to **pin a visible anchor** across the update.

        1. Before applying the change, remember one visible cell and its screen position.
        2. Apply the insert without animation.
        3. Move the content offset so the anchor lands where it was.

        The trap is timing: self-sizing cells can change height *after* the insert, so the anchor has to be re-applied until their heights settle. A layout that owns its attributes can do this inside `prepare()` instead of patching the offset afterwards.

        > Never set the offset while the user is dragging or decelerating: even setting the current value stops the momentum.
        """#,
        #"""
        这周你的睡眠整体**比上周稳定**，但入睡时间偏晚。

        - 平均时长 7 小时 12 分，比上周多 18 分钟。
        - 深睡占比 19%，处在你过去三个月的正常区间。
        - 周三和周五入睡都晚于 1 点，第二天的静息心率也高了 4–5 次/分钟。

        周一 7 小时 5 分，周三 6 小时 10 分，周五 6 小时 32 分，周日 8 小时 2 分：差距主要在周中的入睡时间。

        如果想改善，最有效的是把周中的入睡时间提前到 **12 点前**，其他指标会跟着变好。
        """#,
        #"""
        A **timing curve** runs for a fixed duration along a fixed shape; a **spring** runs until it settles, and its shape comes from physics.

        - Timing curves are predictable: good for things that must finish on a beat.
        - Springs keep velocity: a scroll that is interrupted mid-flight continues smoothly from where it is, instead of restarting.

        For a critically damped spring the position never overshoots, and a single number alone sets how quickly it settles.
        """#,
        #"""
        ### Splitting into blocks

        A small splitter keeps block ids stable while the text grows, by giving each block the id of its position, and making a new one only for a position it hasn't seen.

        Keyed by position, a block keeps its id as long as nothing is inserted before it, which is exactly the streaming case: text only grows at the end. [The list's docs](https://example.com/list) say more about it.
        """#,
        #"""
        There are three options, and each pays somewhere:

        - One text view per message: low latency, high memory, simple.
        - One cell per block: low latency, medium memory, more to keep track of.
        - Pre-rendered snapshots: the lowest latency, the highest memory, and a lot to build.

        **One cell per block** is the usual middle ground: cells stay small, so measuring and reusing them is cheap, and a streaming reply only re-renders its last block.
        """#,
        #"""
        The integral measures the area under the curve between 0 and 1, which comes to one third.

        Intuitively, the curve stays low for most of the interval and only reaches 1 at the right edge, so the area is well under half of the unit square. The same rule gives the integral of any power, `1 / (n + 1)`, for any n of at least 0.
        """#,
    ]

    private static let replies = [
        #"""
        Loading older messages shifts everything below them, so the list has to **pin a visible anchor** across the update.

        1. Before applying the change, remember one visible cell and its screen position.
        2. Apply the insert without animation.
        3. Move the content offset so the anchor lands where it was.

        The trap is timing: self-sizing cells can change height *after* the insert, so the anchor has to be re-applied until their heights settle. A layout that owns its attributes can do this inside `prepare()` instead of patching the offset afterwards.

        > Never set the offset while the user is dragging or decelerating: even setting the current value stops the momentum.
        """#,
        #"""
        这周你的睡眠整体**比上周稳定**，但入睡时间偏晚。

        - 平均时长 7 小时 12 分，比上周多 18 分钟。
        - 深睡占比 19%，处在你过去三个月的正常区间。
        - 周三和周五入睡都晚于 1 点，第二天的静息心率也高了 4–5 次/分钟。

        | 日期 | 时长 | 深睡 | 入睡 |
        |---|---|---|---|
        | 周一 | 7:05 | 21% | 23:48 |
        | 周三 | 6:10 | 16% | 01:20 |
        | 周五 | 6:32 | 17% | 01:05 |
        | 周日 | 8:02 | 22% | 23:30 |

        如果想改善，最有效的是把周中的入睡时间提前到 **12 点前**，其他指标会跟着变好。
        """#,
        #"""
        A **timing curve** runs for a fixed duration along a fixed shape; a **spring** runs until it settles, and its shape comes from physics.

        - Timing curves are predictable: good for things that must finish on a beat.
        - Springs keep velocity: a scroll that is interrupted mid-flight continues smoothly from where it is, instead of restarting.

        For a critically damped spring the position follows

        $$
        x(t) = (x_0 + (v_0 + \omega x_0)\,t)\,e^{-\omega t}
        $$

        so it never overshoots, and $\omega$ alone sets how quickly it settles.
        """#,
        #"""
        Here's a small splitter that keeps block ids stable while the text grows:

        ```swift
        struct BlockSplitter {
            private var ids: [Int: UUID] = [:]

            mutating func split(_ text: String) -> [(id: UUID, source: String)] {
                text.components(separatedBy: "\n\n").enumerated().map { index, source in
                    let id = ids[index] ?? UUID()
                    ids[index] = id
                    return (id, source)
                }
            }
        }
        ```

        Keyed by position, a block keeps its id as long as nothing is inserted before it, which is exactly the streaming case: text only grows at the end.
        """#,
        #"""
        | Option | Latency | Memory | Complexity |
        |---|---|---|---|
        | One text view per message | Low | High | Low |
        | One cell per block | Low | Medium | Medium |
        | Pre-rendered snapshots | Lowest | Highest | High |

        **One cell per block** is the usual middle ground: cells stay small, so measuring and reusing them is cheap, and a streaming reply only re-renders its last block.
        """#,
        #"""
        The integral measures the area under $y = x^2$ between 0 and 1:

        $$
        \int_0^1 x^2\,dx = \left[\frac{x^3}{3}\right]_0^1 = \frac{1}{3}
        $$

        Intuitively, the curve stays low for most of the interval and only reaches 1 at the right edge, so the area is well under half of the unit square. The same rule gives $\int_0^1 x^n\,dx = \frac{1}{n+1}$ for any $n \ge 0$.
        """#,
    ]
}
