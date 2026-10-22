//
//  FlooScenarios.swift
//  DemoApp
//
//  The conversations the demo plays: each is how one kind of asynchrony looks in floo.
//

import Foundation
import CardUI
import Wire

@MainActor
enum FlooScenario: Int, CaseIterable, Identifiable {
    // Live goes first in the menu; the scripted ones keep their numbers (`-flooScenario N`).
    case live = 99, slowWork = 0, interjection, waitingOnYou, catchingUp, group, answerWithCards, pushes, research, longAnswer, errands,
        onDevice

    nonisolated var id: Int { rawValue }

    var name: String {
        switch self {
        case .live: FlooLive.Stage.launched == nil ? "floo：登录后真的对话" : "本机后端：连上实验台，真的对话"
        case .slowWork: "慢活：先答一句，回来接着说"
        case .interjection: "插话：它在写的时候你补一句"
        case .waitingOnYou: "等你：它的问题不会被冲走"
        case .catchingUp: "回来：你不在时发生了什么"
        case .group: "群里：几个 agent 同时干活"
        case .answerWithCards: "查问题：图跟着论点，原位画出"
        case .pushes: "主动：没人找它时说的话"
        case .research: "调研：几分钟的活，一篇长报告"
        case .longAnswer: "长回答：从头读，它在下面接着写"
        case .errands: "手上几件事：随时交代，各自回来"
        case .onDevice: "本机：动你设备上的东西，先问你"
        }
    }

    func play(_ m: FlooDemo) async throws {
        switch self {
        case .live: try await FlooLive.play(m)
        case .slowWork: try await Self.slowWork(m)
        case .interjection: try await Self.interjection(m)
        case .waitingOnYou: try await Self.waitingOnYou(m)
        case .catchingUp: try await Self.catchingUp(m)
        case .group: try await Self.group(m)
        case .answerWithCards: try await Self.answerWithCards(m)
        case .pushes: try await Self.pushes(m)
        case .research: try await Self.research(m)
        case .longAnswer: try await Self.longAnswer(m)
        case .errands: try await Self.errands(m)
        case .onDevice: try await Self.onDevice(m)
        }
    }

    // MARK: Slow work

    /// It says it's on it and goes about it: it looks through the issues itself, then hands the
    /// urgent ones to codex on your Mac. You talk about something else meanwhile, stop one of
    /// them, and it comes back to what you asked.
    private static func slowWork(_ m: FlooDemo) async throws {
        m.reset(title: "管家")
        m.time("14:02")
        let ask = try await m.type("看下 floo 仓库这两天的新 issue，要紧的交给 Mac 上的 codex")
        try await m.wait(500)
        m.mark(ask, .read)
        let first = m.begin(.butler, at: "14:02")
        first.processAfterText = true
        try await m.stream(first, "好，我去看，要紧的交给 codex，弄完跟你说。")
        m.mark(ask, .answered)

        m.takeOn(first, "看新 issue，要紧的交给 codex")
        m.spawn(first, "list", "看新 issue")
        m.progress(first, "list", "在列这两天的新 issue", source: "github.com")
        try await m.wait(1800)
        m.progress(first, "list", "在读 #482、#509、#517 的讨论", source: "github.com")
        try await m.wait(1800)
        m.complete(first, "list", "11 个新 issue，3 个要紧")
        try await m.wait(400)
        // It decides to run these at once, each where codex is.
        m.spawn(first, "482", "#482 断线后重复发送", executor: "交给 Mac 上的 codex")
        try await m.wait(300)
        m.spawn(first, "517", "#517 会话列表排序错乱", executor: "交给 Mac 上的 codex")
        try await m.wait(900)
        m.progress(first, "482", "在读 SyncClient.swift")
        try await m.wait(500)
        m.progress(first, "517", "在复现排序问题")

        // The work goes on while the conversation does.
        let fix = Task { @MainActor in
            try await m.wait(2400)
            m.progress(first, "482", "在改重连时的去重")
            try await m.wait(2200)
            m.progress(first, "517", "找到原因：缺一个排序用的时间字段")
            try await m.wait(5200)
            m.progress(first, "482", "在跑测试，12 个里过了 9 个")
            try await m.wait(2600)
            m.complete(first, "482", "修好了，测试全过，提了 PR")
        }
        try await m.wait(1500)
        m.time("14:04")
        let aside = try await m.type("顺便，今晚会下雨吗")
        try await m.wait(400)
        m.mark(aside, .read)
        let quick = m.begin(.butler, at: "14:04")
        try await m.stream(quick, "今晚不下。明天下午 3 点起有雨。")
        m.mark(aside, .answered)

        // One of the tasks, stopped by name.
        try await m.wait(1800)
        let hold = try await m.type("#517 要是得改数据库，先别动，等我看")
        try await m.wait(400)
        m.mark(hold, .read)
        let held = m.begin(.butler, at: "14:05")
        try await m.stream(held, "好，#517 就停在找到原因这一步，改法等你看。#482 接着修。")
        m.stop(first, "517", "找到原因，没改：等你看")
        m.mark(hold, .answered)
        try await fix.value

        m.finishWork(first, "看了 11 个 issue，codex 修好 1 个 · 6 分 40 秒")
        try await m.wait(1200)
        m.time("14:09")
        let back = m.begin(.butler, at: "14:09", marks: [.continuing("接着 14:02 的事")])
        try await m.stream(back, """
            看完了，11 个新 issue 里 **3 个要紧**：

            - **#482** 同步断线后会重复发送——codex 修好了，测试全过，PR 已提
            - **#517** 会话列表排序错乱——原因是会话表缺一个排序用的时间字段，要改数据库结构，按你说的停在这
            - **#509** 登录偶发 401——得你看一眼日志，我没动

            ```floo.mention
            issue509
            ```

            其余 8 个是功能建议，我先标了 later。
            """)
    }

    // MARK: On your devices

    /// It works on your devices, as when you've chosen to be asked (by default nothing is, not
    /// even deleting): reading your calendar it just does, on the phone in your hand; changing
    /// it waits for you, shown as what the phone will do, not as its words. What can't be undone
    /// has no standing choice, and no is an answer too. What only your Mac has, you allow on
    /// the Mac.
    private static func onDevice(_ m: FlooDemo) async throws {
        m.reset(title: "管家")
        m.time("10:12")
        let ask = try await m.type("周六上午 9 点约了牙医，记到日历里，提前一小时提醒我")
        try await m.wait(400)
        m.mark(ask, .read)
        let add = m.begin(.butler, at: "10:12")
        m.step(add, "在看这台 iPhone 上周六的日程")
        try await m.wait(1400)
        m.step(add, "周六上午空着，等你确认")
        let added = try await m.approve(
            FlooApproval(
                agent: .butler,
                device: "iPhone",
                action: "在日历里新建日程",
                details: ["牙医", "10月3日 周六 09:00–10:00", "提前 1 小时提醒"],
                call: """
                    calendar.create_event
                    {"title": "牙医", "start": "2026-10-03T09:00+08:00",
                     "duration_minutes": 60, "reminders": [60]}
                    """,
                standing: ["以后新建日程都允许", "日历的都允许"]
            ),
            for: add,
            autoAfter: 9000,
            deciding: .once
        )
        m.step(add, Self.decided(added))
        m.finishWork(add, added.allowed ? "在日历里建了「牙医」" : "没建：你没允许")
        try await m.stream(add, added.allowed ? "记好了：周六 9:00 牙医，8:00 提醒你。" : "好，没记。换个时间再跟我说。")
        m.mark(ask, .answered)

        try await m.wait(1500)
        m.time("10:15")
        let drop = try await m.type("把下周三的周会删了")
        try await m.wait(400)
        m.mark(drop, .read)
        let remove = m.begin(.butler, at: "10:15")
        m.step(remove, "在找下周三的周会")
        try await m.wait(1200)
        m.step(remove, "找到了，等你确认")
        let removed = try await m.approve(
            FlooApproval(
                agent: .butler,
                device: "iPhone",
                action: "删除日程",
                details: ["周会", "10月7日 周三 10:00–11:00", "每周重复：只删这一次"],
                call: """
                    calendar.delete_event
                    {"event": "周会", "occurrence": "2026-10-07T10:00+08:00", "span": "this"}
                    """,
                confirm: "删除",
                dangerous: true
            ),
            for: remove,
            autoAfter: 9000,
            deciding: .denied
        )
        m.step(remove, Self.decided(removed))
        m.finishWork(remove, removed.allowed ? "删了下周三的周会" : "没删：你没确认")
        try await m.stream(remove, removed.allowed ? "删了，只删了下周三这一次。" : "好，没删。周会还在。")
        m.mark(drop, .answered)

        try await m.wait(1500)
        m.time("10:18")
        let send = try await m.type("把体检报告发给王医生")
        try await m.wait(400)
        m.mark(send, .read)
        let mail = m.begin(.butler, at: "10:18")
        m.step(mail, "在 MacBook 的邮件里找体检报告")
        try await m.wait(1400)
        m.step(mail, "找到了，等你确认")
        let sent = try await m.approve(
            FlooApproval(
                agent: .butler,
                device: "MacBook",
                action: "用邮件发送",
                details: ["给 王医生 <wang@clinic.example>", "附件：体检报告 2026-09.pdf"],
                call: """
                    mail.send
                    {"to": ["wang@clinic.example"], "subject": "体检报告",
                     "attachments": ["体检报告 2026-09.pdf"]}
                    """,
                elsewhere: true,
                standing: ["以后发给王医生都允许"]
            ),
            for: mail,
            autoAfter: 9000,
            deciding: .once
        )
        m.step(mail, Self.decided(sent))
        m.finishWork(mail, sent.allowed ? "在 MacBook 上发给了王医生" : "没发：你没允许")
        try await m.stream(mail, sent.allowed ? "发了，附件是 9 月的体检报告。" : "好，没发。")
        m.mark(send, .answered)
    }

    /// What you decided, as a step of the work that waited on it.
    private static func decided(_ decision: FlooDecision) -> String {
        switch decision {
        case .once: "你允许了这一次"
        case .always(let choice): "你允许了：\(choice)"
        case .denied: "你没允许"
        }
    }

    // MARK: Interjection

    /// You add something while it writes: it shows as not seen yet, is read at the next
    /// breakpoint, and the answer takes it in.
    private static func interjection(_ m: FlooDemo) async throws {
        m.reset(title: "管家")
        m.time("21:40")
        let ask = try await m.type("帮我想想早报里放什么")
        try await m.wait(400)
        m.mark(ask, .read)
        let first = m.begin(.butler, at: "21:40")
        first.processAfterText = true
        let typing = Task { @MainActor in
            try await m.wait(2200)
            return try await m.type("对了，健康的部分别放太多", receipt: .unseen)
        }
        try await m.stream(first, """
            可以按「今天要你做决定的事」来排，而不是按来源排——天气、日历、健康各占一块的早报，读完还得自己拼。

            我先看看你最近打开早报时都点了什么。
            """, perSecond: 30)
        m.mark(ask, .answered)
        // A tool call: the breakpoint where what came in meanwhile is read.
        m.step(first, "在看你最近 30 天打开早报的记录")
        try await m.wait(1800)
        m.finishWork(first, "看了 30 天的早报记录 · 2 秒")
        let added = try await typing.value
        m.mark(added, .read)
        try await m.wait(700)
        let second = m.begin(.butler, at: "21:41", marks: [.continuing("接着你刚补充的")])
        try await m.stream(second, """
            收到，健康只留一行：昨晚睡了多久、比平时多还是少，其余挪到晚报。

            早报就排成三段：

            1. **今天要你决定的**——等你回复的事、快到期的约定
            2. **今天会发生的**——日程，和天气里跟你有关的那一句
            3. **一行健康**——只在异常时展开

            要的话明早 7 点就按这个发。

            ```floo.choice
            - 📅 按这个发
              send: 明早 7 点按「要你决定的 / 今天会发生的 / 一行健康」三段发早报
            - ✏️ 再改改
              send: 早报先别发，我还想调整
            ```
            """)
        m.mark(added, .answered)
        // Tappable next steps, not a question that blocks: picking one is your reply.
        let picked = try await m.awaitChoice(second, autoAfter: 5000, auto: 0)
        let reply = m.begin(.butler, at: "21:42")
        try await m.stream(reply, "好，明早 7 点发第一份。")
        m.mark(picked.said, .answered)
    }

    // MARK: Waiting on you

    /// #517 要你决定的修复方向：选哪种做法，或者自己写。
    private static let a517 = FlooAskCard(
        id: "a517",
        agent: .butler,
        items: [
            FlooAskItem(
                title: "修复方向",
                question: "#517 要按最后一条消息排序，选哪种做法？",
                form: .choose(
                    options: [
                        FlooOption(label: "方案 1：加一列", detail: "会话表加 last_message_at，线上跑一次迁移；列表最快"),
                        FlooOption(label: "方案 2：查询时算", detail: "不改表结构，每次取会话时算最新消息；会话很多时慢一点"),
                    ],
                    multiple: false,
                    own: "先在测试库跑一遍迁移，没问题再说"
                )
            ),
        ],
        state: .open
    )

    /// It asks and goes on: the card rides on the message that asked, the asks waiting on you
    /// are counted over the composer, and each is answered where it sits, whenever you get to
    /// it — including in your own words.
    private static func waitingOnYou(_ m: FlooDemo) async throws {
        m.reset(title: "管家")
        m.time("15:02")
        let question = m.begin(.butler, at: "15:02", marks: [.continuing("接着 #517")])
        try await m.stream(question, """
            #517 的排序问题查清楚了：会话表缺一个排序用的时间字段。修它要**改数据库结构**，线上得跑一次迁移。
            """, finishing: false)
        m.ask(question, a517)
        try await m.stream(question, "这个等你定，我先把不需要它的 #482 做完。")

        try await m.wait(2500)
        m.time("15:06")
        let done = m.begin(.butler, at: "15:06", marks: [.continuing("接着 #482")])
        try await m.stream(done, "#482 修好了，测试全过，codex 已经提了 PR。")
        try await m.wait(1200)
        let ask = try await m.type("PR 发我看看")
        try await m.wait(400)
        m.mark(ask, .read)
        let link = m.begin(.butler, at: "15:07")
        try await m.stream(link, """
            在这：

            ```floo.mention
            pr482
            ```
            """, finishing: false)
        // Now two asks are open at once; the entry over the composer reads "2 件在等你".
        m.ask(link, FlooAskCard(
            id: "a482",
            agent: .butler,
            items: [
                FlooAskItem(
                    title: "合并 #482",
                    question: "#482 的 PR 要我合进 main 吗？",
                    form: .confirm(effect: "会合进 main 并关掉 #482；CI 已经全过", yes: "合并", no: "先别")
                ),
            ],
            state: .open
        ))
        try await m.stream(link, "你点头我就合。")
        m.mark(ask, .answered)

        // Answered one at a time, each where its card sits.
        let merged = try await m.awaitAnswer("a482", item: 0, autoAfter: 4000, auto: .confirm(true))
        let mergedReply = m.begin(.butler, at: "15:09")
        try await m.stream(mergedReply, "合好了，#482 已关。")
        m.mark(merged, .answered)
        let way = try await m.awaitAnswer("a517", item: 0, autoAfter: 6000, auto: .own)
        let reply = m.begin(.butler, at: "15:10")
        try await m.stream(reply, "好，先让 codex 在测试库跑一遍迁移，跑完把结果给你，上不上线你定。")
        m.mark(way, .answered)
    }

    // MARK: Catching up

    /// You come back after hours: it opens where you left off, says in a line what happened,
    /// and takes you to what's waiting on you.
    private static func catchingUp(_ m: FlooDemo) async throws {
        m.reset(title: "管家")
        m.time("昨天 22:10")
        m.say(.me, "明早提醒我把体检报告带上", receipt: .answered)
        m.write(m.begin(.butler, at: "22:10"), "好，明早 8 点提醒你。")
        m.time("14:02")
        m.say(.me, "看下 floo 仓库这两天的新 issue，要紧的交给 Mac 上的 codex", receipt: .answered)
        m.write(m.begin(.butler, at: "14:02"), "好，我去看，要紧的交给 codex，弄完跟你说。")
        m.unread("上次看到这里 · 14:10")
        m.catchUp("你不在的时候：#482 修好了，PR 已提；#517 要改数据库结构，**在等你决定**；今晚不下雨。")
        m.time("14:31")
        m.write(m.begin(.butler, at: "14:31", marks: [.continuing("接着 14:02 的事")]), """
            #482 修好了，测试全过，codex 提了 PR：

            ```floo.mention
            pr482
            ```
            """)
        m.time("15:02")
        let question = m.begin(.butler, at: "15:02", marks: [.continuing("接着 #517")])
        m.write(question, "#517 的排序问题查清楚了：会话表缺一个排序用的时间字段。修它要**改数据库结构**，线上得跑一次迁移。")
        // Asked while you were away: the card is still open where it was asked.
        m.ask(question, a517)
        m.setJumpTarget(question)
        m.time("16:40")
        m.write(m.begin(.butler, at: "16:40", marks: [.proactive]), """
            今晚不下雨，明天 15 点起有雨，明早出门不用带伞。

            ```floo.card
            weather
            ```
            """)
        try await m.wait(300)
        m.openAtUnread()
        try await m.wait(3500)
        m.jump()
        let chosen = try await m.awaitAnswer("a517", item: 0, autoAfter: 5000, auto: .option(1))
        let reply = m.begin(.butler, at: "16:52")
        try await m.stream(reply, "好，不改表结构，按查询时算来改。")
        m.mark(chosen, .answered)
    }

    // MARK: Group

    /// In a group, two agents answer at once; who is doing what shows in one line, and each
    /// speaks as itself when it's done.
    private static func group(_ m: FlooDemo) async throws {
        m.reset(title: "周末 · 苏州")
        m.time("20:15")
        m.say(.person("阿岚"), "那就定了，10 号周六出发，11 号回")
        try await m.wait(1200)
        let ask = try await m.type("@天气 @管家 周六上午怎么安排比较好")
        try await m.wait(500)
        m.mark(ask, .read)
        let weather = Task { @MainActor in
            let message = m.begin(.weather, at: "20:15")
            try await m.wait(900)
            try await m.stream(message, """
                周六苏州**上午多云，15 点起有雨**，14–21°。上午逛园林正好，下午的安排尽量放室内。

                ```floo.card
                weather
                ```
                """, perSecond: 35)
        }
        let butler = m.begin(.butler, at: "20:15")
        m.step(butler, "在查 10 号上海到苏州的高铁")
        try await m.wait(2600)
        m.step(butler, "在看 G7315 的余票")
        try await m.wait(2400)
        try await weather.value
        m.finishWork(butler, "查了高铁 · 5 秒")
        try await m.stream(butler, """
            高铁 **G7315**，9:15 上海虹桥发车，9:48 到苏州，还有票。

            上午二选一：

            ```floo.choice
            - 🌿 拙政园
              image: zhuozhengyuan
              detail: 上午人少，7:30 开门
              send: 周六上午去拙政园，帮我们俩订 10 点的门票
            - 🏮 平江路
              image: pingjianglu
              detail: 免门票，边走边吃
              send: 周六上午去平江路逛
            ```

            要我帮你们俩盯着 G7315 放票吗？

            ```floo.choice
            - 👀 盯着
              send: 帮我们俩盯着周六 G7315 的余票，有票就告诉我
            - 不用
              send: 不用盯票
            ```
            """)
        m.mark(ask, .answered)
        try await m.wait(1500)
        m.say(.person("阿岚"), "好，就买这班")
        _ = try await m.awaitChoice(butler, autoAfter: 4000, auto: 0)
        _ = try await m.awaitChoice(butler, 1, autoAfter: 4000, auto: 0)
        // Watching tickets needs a few details: it asks, its guesses already filled in.
        let seat = m.begin(.butler, at: "20:17")
        try await m.stream(seat, "盯票要几样信息，我先猜了：")
        m.ask(seat, FlooAskCard(
            id: "seat",
            agent: .butler,
            items: [
                FlooAskItem(
                    title: "盯票信息",
                    question: "按这样盯？",
                    form: .fill(fields: [
                        FlooAskItem.Field(label: "乘车人", kind: .person, guess: "你、阿岚"),
                        FlooAskItem.Field(label: "席别", kind: .text, guess: "二等座"),
                        FlooAskItem.Field(label: "最晚到苏州", kind: .time, guess: "10:30"),
                    ])
                ),
            ],
            state: .open
        ))
        let confirmed = try await m.awaitAnswer("seat", item: 0, autoAfter: 5000, auto: .fill)
        let reply = m.begin(.butler, at: "20:18")
        try await m.stream(reply, "好，盯着了：G7315 二等座两张，一有票就在群里说。")
        m.mark(confirmed, .answered)
    }

    // MARK: Answer with cards

    /// A long answer with its evidence where it makes each point: the drawing starts when its
    /// fence closes and fills its place while the text goes on.
    private static func answerWithCards(_ m: FlooDemo) async throws {
        m.reset(title: "健康")
        m.time("21:05")
        let ask = try await m.type("这周身体状况怎么样")
        try await m.wait(400)
        m.mark(ask, .read)
        let answer = m.begin(.health, at: "21:05")
        m.step(answer, "在看这周的步数")
        try await m.wait(1200)
        m.step(answer, "在看静息心率和睡眠")
        try await m.wait(1300)
        m.finishWork(answer, "看了步数、心率和睡眠 · 3 秒")
        try await m.stream(answer, """
            整体平稳：这周平均每天 **6,790 步**，比你 30 天的平均多一些；8000 步的目标达成了 **2 天**。

            ```floo.draw
            每天的步数，对着 8000 的目标和 30 天平均
            card: steps
            ```

            """, finishing: false)
        let steps = Task { @MainActor in try await m.draw("steps") }
        try await m.stream(answer, """
            静息心率一整周都在你平时的范围里。睡眠只有昨晚的数据：睡了 **7 小时 21 分**，得分 **84**。

            ```floo.draw
            静息心率在平时范围内；昨晚睡了 7 小时 21 分、84 分
            card: heart
            ```

            """, finishing: false)
        let heart = Task { @MainActor in try await m.draw("heart") }
        try await m.stream(answer, """
            周三和周日走得最少，那两天你都在家办公。要不要下周在那两天午饭后提醒你走一圈？

            ```floo.choice
            - 🚶 提醒我
              send: 下周三和周日午饭后提醒我走一圈
            - 不用
              send: 不用提醒
            ```
            """)
        m.mark(ask, .answered)
        try await steps.value
        try await heart.value
        let remind = try await m.awaitChoice(answer, autoAfter: 5000, auto: 0)
        let reply = m.begin(.health, at: "21:06")
        try await m.stream(reply, "好，下周三和周日 12:40 提醒你。")
        m.mark(remind.said, .answered)
    }

    // MARK: Research

    /// Minutes of reading: it says how it will go about it, reads with each source showing,
    /// and comes back with a report that starts with its conclusion. Too long for the screen,
    /// it's read from its start while the rest is written below; its question waits over the
    /// composer, and a reply can pick out the part it's about.
    private static func research(_ m: FlooDemo) async throws {
        m.reset(title: "管家")
        m.time("21:10")
        let ask = try await m.type("帮我调研下 GPT-6：几个型号差在哪、价格、跑分，floo 现在用 luna，要不要换")
        try await m.wait(500)
        m.mark(ask, .read)
        let first = m.begin(.butler, at: "21:10")
        first.processAfterText = true
        try await m.stream(first, "好，我去看看，最后按 floo 这周的用量算笔账。要几分钟，看完在这跟你说。")
        m.mark(ask, .answered)
        // It looks into three things at once, and does the bill once they're in.
        m.takeOn(first, "GPT-6 值不值得换")
        m.spawn(first, "models", "型号和价格")
        try await m.wait(250)
        m.spawn(first, "bench", "第三方跑分")
        try await m.wait(250)
        m.spawn(first, "voices", "用过的人怎么说")
        try await m.wait(250)
        m.spawn(first, "bill", "算 floo 这周的账", waiting: "等前面几路查完")

        // The work goes on while you ask about it.
        let work = Task { @MainActor in
            for (task, step, source) in [
                ("models", "在读 OpenAI 的发布说明", "openai.com"),
                ("bench", "在读 llm-stats 的跑分", "llm-stats.com"),
                ("voices", "在搜评测和讨论", nil),
                ("models", "在读 VentureBeat：Sol 和 Luna 发布", "venturebeat.com"),
            ] as [(String, String, String?)] {
                try await m.wait(800)
                m.progress(first, task, step, source: source)
            }
            try await m.wait(900)
            m.complete(first, "models", "三档：Astra、Sol、Luna，外加昨天的 6.1 Sol")
            try await m.wait(2600)
            m.progress(first, "bench", "在读 Vellum：6.1 Sol 跑分解读", source: "vellum.ai")
            try await m.wait(2400)
            m.progress(first, "voices", "在读 Digital Applied：Sol 和 Luna 的取舍", source: "digitalapplied.com")
            try await m.wait(3200)
            m.progress(first, "voices", "在读 Build Fast with AI：6.1 Sol 评测", source: "buildfastwithai.com")
            try await m.wait(2600)
            m.complete(first, "bench", "五项评测，三档都有分")
            try await m.wait(1800)
            m.complete(first, "voices", "两篇评测，一条要注意")
        }

        // Asked mid-way: it answers from what's in, says what isn't, and the work goes on.
        try await m.wait(4600)
        m.time("21:12")
        let price = try await m.type("Sol 比 luna 贵多少？先说个大概")
        try await m.wait(400)
        m.mark(price, .read)
        let soFar = m.begin(.butler, at: "21:12", marks: [.soFar("按目前进度：价格查完了，跑分还在查")])
        try await m.stream(soFar, """
            型号和价格那路查完了：每百万 token，Sol 输入 $2、输出 $10，luna 是 $0.10 和 $0.50——**两头都贵 20 倍**。

            贵得值不值要看跑分，那路还在查，报告里一起说。
            """)
        m.mark(price, .answered)

        // Asked for more: the work grows a task, and the report waits for it too.
        try await m.wait(1400)
        let more = try await m.type("顺便看下 Claude Sonnet 5 的价格")
        try await m.wait(400)
        m.mark(more, .read)
        let added = m.begin(.butler, at: "21:13", marks: [.joined("GPT-6 值不值得换")])
        try await m.stream(added, "好，一起看，放进报告里。")
        m.spawn(first, "claude", "Claude Sonnet 5 的价格", added: "21:13")
        m.mark(more, .answered)
        try await m.wait(900)
        m.progress(first, "claude", "在读各家价格对比", source: "digitalapplied.com")
        try await m.wait(2200)
        m.complete(first, "claude", "$2 / $10，和 Sol 同价")

        try await work.value
        try await m.wait(500)
        m.progress(first, "bill", "在读 floo 这周的用量")
        try await m.wait(1400)
        m.complete(first, "bill", "luna $6.02，Sol $120.40")
        try await m.wait(800)
        m.finishWork(first, "查了价格、跑分和评测，算了账 · 7 分钟")
        try await m.wait(1000)

        m.time("21:17")
        let report = m.begin(.butler, at: "21:17", marks: [.continuing("接着 GPT-6 调研")])
        try await m.stream(report, """
            **结论：先不换。** 刚才说了 Sol 贵 20 倍；跑分查完，它只高 2 到 12 个点。luna 就是 GPT-6 最便宜的那一档。

            ### 三个型号

            价钱按每百万 token 算：

            | | Astra | Sol | Luna |
            |---|---|---|---|
            | 发布 | 9 月 3 日 | 9 月 22 日 | 9 月 22 日 |
            | 输入 | $10 | $2 | $0.10 |
            | 输出 | $50 | $10 | $0.50 |

            三档的上下文都是 105 万 token，一次最多输出 12.8 万。昨天 DevDay 又出了 6.1 Sol：价格不变，说是接近 Astra 的水平。

            你中途问的 Claude Sonnet 5：输入 $2、输出 $10，和 Sol 同价。

            ### 跑分

            ```floo.draw
            五项评测上三档的得分，和价钱放在一起
            card: gpt6
            ```

            """, perSecond: 90, finishing: false)
        let bench = Task { @MainActor in try await m.draw("gpt6") }
        try await m.stream(report, """
            差得最多的是操作电脑（OSWorld）：Luna 52.7%，Sol 64.4%。差得最少的是长时间的软件任务（DeepSWE）：66.6% 对 68.8%。

            ### 用过的人怎么说

            - Luna 开到最高推理强度，五项里有四项超过低强度的 Sol；写代码时，每个任务的花费只有 Sol 的五分之一左右。
            - 和上一代 GPT-5.6 Sol 比，这一代主要是便宜了，最高分反而有两项没超过。
            - 有一条要注意：

            ```floo.mention
            alignment
            ```

            ### 对 floo 意味着什么

            ```floo.draw
            按 floo 这周的用量，两个型号各要花多少
            card: cost
            ```

            """, perSecond: 90, finishing: false)
        let cost = Task { @MainActor in try await m.draw("cost") }
        try await m.stream(report, """
            这周 floo 用了 4,120 万输入 token、380 万输出 token。按 luna 算约 **$6**，换 Sol 要 **$120**。

            我的建议：

            1. 聊天和画卡片继续用 luna。
            2. 以后要做操作电脑的活，再单独评估 Sol。
            3. 护栏写在代码里，不靠模型自觉——我们现在就是这么做的。

            要我盯着 6.1 Sol 的第三方评测吗？

            ```floo.choice
            - 👀 盯着
              send: 6.1 Sol 有新的第三方评测就告诉我
            - 不用
              send: 不用盯
            ```
            """, perSecond: 90)
        try await bench.value
        try await cost.value

        // The choice rides at the end of the report while you ask about a part of it.
        let watch = Task { @MainActor in
            try await m.awaitChoice(report, autoAfter: 16000, auto: 0)
        }
        try await m.wait(4000)
        m.time("21:19")
        let how = try await m.type("这 $120 怎么算的", quote: "按 luna 算约 $6，换 Sol 要 $120。")
        try await m.wait(400)
        m.mark(how, .read)
        let sum = m.begin(.butler, at: "21:19")
        try await m.stream(sum, """
            输入 4,120 万 × $2 / 百万 = $82.4，输出 380 万 × $10 / 百万 = $38，一共 **$120.4**。

            luna 那边是 $4.12 + $1.90 = **$6.02**。
            """)
        m.mark(how, .answered)
        let chosen = try await watch.value
        try await m.wait(500)
        let promise = m.begin(.butler, at: "21:20")
        try await m.stream(promise, "好，记下了：6.1 Sol 有新的第三方评测，我就在这告诉你。")
        m.mark(chosen.said, .answered)
    }

    // MARK: Long answer

    /// An answer longer than the screen: you read it from its start while it's written below.
    /// What you say meanwhile waits over the composer until it has finished, then it answers.
    private static func longAnswer(_ m: FlooDemo) async throws {
        m.reset(title: "管家")
        m.time("22:40")
        let ask = try await m.type("arcaea 怎么摘星")
        try await m.wait(400)
        m.mark(ask, .read)
        let answer = m.begin(.butler, at: "22:40")
        m.step(answer, "在查 Arcaea 现在的潜力值规则")
        try await m.wait(1500)
        m.step(answer, "在读 Arcaea 维基：7.0 的新算法")
        try await m.wait(1400)
        m.finishWork(answer, "查了潜力值规则 · 3 秒")
        try await m.stream(answer, """
            摘星就是潜力值（PTT）到 **12.00**：名字旁的框上会多一颗星，到 **12.50** 是第二颗。

            先说一件很多攻略还没跟上的事：**7.0 改了潜力值的算法**。网上常说的「B30 + R10」已经不是现在的规则了，最近打的几把不再单独算。

            ### 现在怎么算

            每张谱打一次，得到一个单曲潜力值：

            - 980 万分以上：定数 + 1 + (分数 − 980 万) ÷ 20 万；全 Pure（PM）直接算定数 + 2
            - 980 万以下：定数 + (分数 − 950 万) ÷ 30 万
            - 打完没断（Easy 过关也算），再加 0.2

            总潜力值取你最好的 50 个成绩：**前 10 名算两遍**，第 11 到 50 名算一遍，一共除以 60。

            ```floo.draw
            分数和单曲潜力值的关系，标出 12.00 那条线
            card: arcaea
            ```

            """, perSecond: 70, finishing: false)
        let curve = Task { @MainActor in try await m.draw("arcaea") }
        // You ask while it's still writing: it waits until the answer is done.
        let aside = Task { @MainActor in
            try await m.wait(5000)
            return try await m.typeWhileWriting("定数在哪看")
        }
        try await m.stream(answer, """
            这条线在 980 万有个拐点：**之前每 30 万分才 +1，之后每 20 万分就 +1。** 同样多推 10 万分，980 万以上能多 0.5，以下只多 0.33。

            ### 要到 12.00，每张谱要打多少

            前 50 张平均（前 10 张算两遍）到 12.00 就摘星。换成单张谱的分数：

            | 定数 | 要打到 |
            |---|---|
            | 9.8 | 理论值（PM） |
            | 10.0 | 996 万 |
            | 10.3 | 990 万 |
            | 10.5 | 986 万 |
            | 10.8 | 980 万 |
            | 11.0 | 974 万 |

            ### 怎么推

            1. **先推前 10 名。** 它们算两遍：挑你最拿手的 10 张高定数谱推到 990 万以上，比铺新谱划算。
            2. **第 11 到 50 名求稳。** 定数 10.3 到 10.8、你能稳定 EX+ 的谱，每张推到表里那条线附近就够。
            3. **别断。** 打完就有 0.2；同样的分数，Track Lost 就白丢这 0.2。

            我手上没有你的成绩。发一张成绩页截图，我按你的前 50 张算出最该推的是哪几张。
            """, perSecond: 70)
        m.mark(ask, .answered)
        try await curve.value
        let asked = try await aside.value
        try await m.wait(600)
        m.land(asked)
        try await m.wait(500)
        let reply = m.begin(.butler, at: "22:41", marks: [.continuing("接着你刚问的")])
        try await m.stream(reply, "游戏里只显示等级（比如 10、10+），不显示定数。Arcaea 中文维基有定数表，每次更新都会跟着改。也可以直接把成绩页截图发我，我认出是哪几张谱，替你查。")
        m.mark(asked, .answered)
    }

    // MARK: Errands

    /// Things asked for one after another, nothing to do with each other: each is taken on
    /// where it was asked, the line over the composer says how many are in hand, and each comes
    /// back when it's done, in whatever order that is. Asked how one is going, it says.
    private static func errands(_ m: FlooDemo) async throws {
        m.reset(title: "管家")
        m.time("20:30")
        let gptAsk = try await m.type("GPT-6 出了，帮我看看 floo 要不要换")
        try await m.wait(400)
        m.mark(gptAsk, .read)
        let gpt = m.begin(.butler, at: "20:30")
        gpt.processAfterText = true
        try await m.stream(gpt, "好，我去看看，看完跟你说。")
        m.mark(gptAsk, .answered)
        m.takeOn(gpt, "GPT-6 值不值得换")
        m.spawn(gpt, "read", "看发布和评测")
        m.progress(gpt, "read", "在读 OpenAI 的发布说明", source: "openai.com")
        m.spawn(gpt, "bill", "算 floo 这周的账", waiting: "等评测看完")
        let gptWork = Task { @MainActor in
            for (step, source) in [
                ("在读 VentureBeat：Sol 和 Luna 发布", "venturebeat.com"),
                ("在读 llm-stats 的跑分", "llm-stats.com"),
                ("在读 Digital Applied：Sol 和 Luna 的取舍", "digitalapplied.com"),
            ] {
                try await m.wait(3200)
                m.progress(gpt, "read", step, source: source)
            }
            try await m.wait(6000)
            m.complete(gpt, "read", "读了 4 篇：贵 20 倍，跑分只高几个点")
            m.progress(gpt, "bill", "在读 floo 这周的用量")
            try await m.wait(3000)
            m.complete(gpt, "bill", "luna $6.02，Sol $120.40")
        }

        try await m.wait(1800)
        m.time("20:31")
        let trainAsk = try await m.type("对了，周六去苏州的高铁也帮我看下，上午的")
        try await m.wait(400)
        m.mark(trainAsk, .read)
        let train = m.begin(.butler, at: "20:31")
        train.processAfterText = true
        try await m.stream(train, "好，也去看。")
        m.mark(trainAsk, .answered)
        m.takeOn(train, "周六去苏州的高铁")
        m.step(train, "在查周六上午，上海到苏州")
        let trainWork = Task { @MainActor in
            try await m.wait(3000)
            m.step(train, "在比 3 班车的时间和余票")
            try await m.wait(4200)
        }

        try await m.wait(1200)
        m.time("20:32")
        let fixAsk = try await m.type("还有 #482 让 codex 修一下")
        try await m.wait(400)
        m.mark(fixAsk, .read)
        let fix = m.begin(.butler, at: "20:32")
        fix.processAfterText = true
        try await m.stream(fix, "交给 Mac 上的 codex 了，修好告诉你。")
        m.mark(fixAsk, .answered)
        m.takeOn(fix, "修 #482")
        m.step(fix, "Mac 上的 codex 在读 SyncClient.swift")
        let fixWork = Task { @MainActor in
            try await m.wait(3500)
            m.step(fix, "codex 在改重连时的去重")
            try await m.wait(5000)
            m.step(fix, "codex 在跑测试，12 个里过了 9 个")
            try await m.wait(6000)
        }

        // What's in hand, opened from the line over the composer.
        try await m.wait(1500)
        m.showsErrands = true
        try await m.wait(3800)
        m.showsErrands = false

        // The tickets are back first.
        try await trainWork.value
        m.finishWork(train, "比了 3 班车 · 2 分钟")
        try await m.wait(600)
        m.time("20:34")
        let trainBack = m.begin(.butler, at: "20:34", marks: [.continuing("接着 周六的高铁")])
        try await m.stream(trainBack, """
            周六上午最合适的是 **G7315**：9:15 虹桥发车，9:48 到苏州，二等座还有票。早一班 8:05 的只剩一等座。

            ```floo.choice
            - G7315 · 9:15
              from: g7315
              detail: 二等座有票，9:48 到
              send: 就 G7315，周六 8:30 提醒我出发
            - G7001 · 8:05
              from: g7001
              detail: 只剩一等座
              send: 坐 8:05 的 G7001，周六 7:20 提醒我出发
            ```
            """)
        let remind = Task { @MainActor in
            try await m.awaitChoice(trainBack, autoAfter: 9000, auto: 0)
        }

        // How is the other one going: from where it's at.
        try await m.wait(1800)
        m.time("20:35")
        let how = try await m.type("GPT-6 看得怎么样了")
        try await m.wait(400)
        m.mark(how, .read)
        let soFar = m.begin(.butler, at: "20:35", marks: [.soFar("按目前进度：看了 4 篇，账还没算")])
        try await m.stream(soFar, "看了 4 篇：Sol 比 luna 贵 20 倍，跑分只高几个点，目前看是先不换。floo 这周的账还在算，算完给你准话。")
        m.mark(how, .answered)

        let chosen = try await remind.value
        try await m.wait(500)
        let promise = m.begin(.butler, at: "20:36")
        try await m.stream(promise, "好，周六 8:30 提醒你出发。")
        m.mark(chosen.said, .answered)

        // More for a thing in hand: it goes in with it, and comes back with it.
        try await m.wait(1000)
        let more = try await m.type("GPT-6 那个，顺便看下 Claude Sonnet 5 的价格")
        try await m.wait(400)
        m.mark(more, .read)
        let joined = m.begin(.butler, at: "20:36", marks: [.joined("GPT-6 值不值得换")])
        try await m.stream(joined, "好，并进去一起看，结果放一起给你。")
        m.spawn(gpt, "claude", "Claude Sonnet 5 的价格", added: "20:35")
        m.mark(more, .answered)
        let claude = Task { @MainActor in
            try await m.wait(1200)
            m.progress(gpt, "claude", "在读各家价格对比", source: "digitalapplied.com")
            try await m.wait(4000)
            m.complete(gpt, "claude", "$2 / $10，和 Sol 同价")
        }
        // Where it went, as a tap on the mark shows it.
        try await m.wait(900)
        m.jumpToErrand(titled: "GPT-6 值不值得换")
        m.toggle(m.workRow(gpt))
        try await m.wait(3800)
        m.backToLatest()

        try await fixWork.value
        m.finishWork(fix, "codex 修好了，测试全过 · 5 分钟")
        try await m.wait(600)
        m.time("20:37")
        let fixBack = m.begin(.butler, at: "20:37", marks: [.continuing("接着 修 #482")])
        try await m.stream(fixBack, """
            #482 修好了，12 个测试全过，codex 提了 PR：

            ```floo.mention
            pr482
            ```
            """)

        try await gptWork.value
        try await claude.value
        m.finishWork(gpt, "读了 5 篇，算了账 · 8 分钟")
        try await m.wait(600)
        m.time("20:38")
        let gptBack = m.begin(.butler, at: "20:38", marks: [.continuing("接着 GPT-6 值不值得换")])
        try await m.stream(gptBack, """
            **先不换。** 和刚才说的一样：Sol 贵 20 倍，跑分只高 2 到 12 个点。你后来加的 Claude Sonnet 5 是输入 $2、输出 $10，和 Sol 同价。按 floo 这周的用量算：

            ```floo.card
            cost
            ```

            以后要做操作电脑的活，再单独看 Sol——那项它比 luna 高得最多。
            """)
    }

    // MARK: Pushes

    /// What it says with nobody asking: the morning brief, a reminder that rang and why, a
    /// change worth knowing, and your reply to one of them.
    private static func pushes(_ m: FlooDemo) async throws {
        m.reset(title: "管家")
        m.time("07:30")
        let brief = m.begin(.butler, at: "07:30", marks: [.proactive])
        try await m.stream(brief, """
            早。**15 点起有雨**，出门带伞；昨晚睡了 7 小时 21 分，比平时多一点。

            ```floo.card
            weather
            sleep
            ```

            今天只有一个会：

            ```floo.mention
            review
            ```
            """)
        try await m.wait(1500)
        m.time("08:00")
        let reminder = m.begin(.butler, at: "08:00", marks: [.proactive, .notified("你昨晚让我 8 点提醒")])
        try await m.stream(reminder, "记得把体检报告带上。")
        try await m.wait(1500)
        m.time("14:38")
        let rain = m.begin(.butler, at: "14:38", marks: [.proactive, .notified("雨比早报说的早，你 15 点要出门")])
        try await m.stream(rain, """
            雨提前了，大概 **15:00** 开始，小雨下到 16:10 左右。要出门的话现在走，或者 16:15 以后。

            ```floo.card
            rain
            ```
            """)
        try await m.wait(1200)
        let reply = try await m.type("那我 16:15 以后走")
        try await m.wait(400)
        m.mark(reply, .read)
        let answer = m.begin(.butler, at: "14:39")
        try await m.stream(answer, "好，16:10 我再看一眼雨停没停，停了告诉你。")
        m.mark(reply, .answered)
    }
}

enum FlooDemoMentions {
    /// A time of the scripted week, on this device's clock.
    static func clock(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute)) ?? .now
    }

    /// That time as a mention's moment.
    static func date(_ day: Int, _ hour: Int, _ minute: Int) -> When {
        .moment(Moment(Timestamp(clock(day, hour, minute)), in: ZoneName(TimeZone.current.identifier) ?? .utc))
    }

    static let all: [String: Mention] = [
        "issue509": Mention(
            kind: .web,
            source: "github.com/floo/floo",
            date: date(29, 23, 12),
            title: "#509 登录偶发 401",
            quote: "… refresh token 过期后的第一次请求返回 **401**，重试一次就好 …"
        ),
        "pr482": Mention(
            kind: .web,
            source: "github.com/floo/floo",
            date: date(30, 14, 29),
            title: "Fix #482: 断线重连后不再重复发送",
            quote: "… 重连时按消息 id 去重，**12 个测试**全部通过 …"
        ),
        "alignment": Mention(
            kind: .web,
            source: "digitalapplied.com",
            date: date(22, 20, 0),
            title: "GPT-6 Sol and Luna: API Prices, Benchmarks and Trade-offs",
            quote: "… Sol circumvented warnings in **64.4%** of stress tests — enforce your guardrails in code …"
        ),
        "review": Mention(
            kind: .event,
            source: "工作",
            date: date(30, 10, 0),
            end: date(30, 11, 0),
            title: "设计评审",
            quote: "4B 会议室 · 和 Mia、Tom 等 5 人"
        ),
    ]
}
