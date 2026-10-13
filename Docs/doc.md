# floo · 文档(Doc)

> 2026-10-04 起草。标注约定同 floo `docs/cards.md`:**【定】** · **【倾向】** · **【待定】**。
> 内部名 `Doc`,避开小程序那条线已经占用的 `Page`(`PageStorage`、`page_store`、`Apps/PageLab`)。给用户看的名字叫"文档";英文名【待定】。

---

## 0. 目标

一种人和 agent 都能写的文档,在 iPhone、Mac(Catalyst)和 Web 上都能看、都能改。

- 支持 MarkdownView 现有的全部设计:标题、列表、引用、代码、公式、表格、链接 chip、脚注、CJK 强调。在这之外,还支持可视化卡片、多维表格和看板。
- **查看**:性能接近聊天里的 MarkdownView(最长帧 118–160ms,滚动卡顿约 2ms/s),reveal 也和聊天里一样。
- **编辑**:比 flowith Composer 好。撤销/重做要可靠;要有实时同步和版本记录;agent 的修改能看见、也能撤回。
- **编辑和查看是同一种实现**:同一个块视图、同一个文本视图、同一套排版,查看就是关掉编辑。切换时内容不跳,两种模式的视觉不会走样。
- **reveal 只给 agent 的输出用**:agent 在写的时候,文档一定处于不可编辑的预览模式。打开文档、自己输入、别的设备同步过来的改动,都直接显示,不淡入。

**对标 Craft**(本机 Craft 3.5.3 的二进制,加上它公开的 Connect API。没有源码,下面是推断):
- 原生端是 Catalyst,界面是 UIKit 加 SwiftUI。编辑器模块叫 `CraftBlockEditor`,一块一个文本视图(`v2BlockTextView`)。
- 本地数据用 Realm 存块(`BlockStorage`)。同步走 WebSocket(`wss://api.craft.do/ws/v1`),实时协作另有一条通道(`ws-rtc/v1`)。
- 冲突按块处理(`BlockConflictResolver`、`BlockSyncSnapshot`),表格的冲突单独处理。
- 版本记录叫 Snapshots,带列表和详情界面。
- 多维表格和看板是同一份数据(collection)的不同视图。
- 对外 API 里每块是 `{id, type, textStyle, indentationLevel 0–5, listStyle, markdown}`,整篇也能按 `text/markdown` 导出。

所以 Craft 的真实模型是**平铺的块,加缩进层级**;Markdown 只出现在对外接口上。floo 采用同样的分层,冲突粒度比 Craft 细:到字,而不是到块。

## 1. 结论一览

| 问题 | 决定 |
|---|---|
| 存储格式 | 结构化模型:平铺块 + 缩进,块内是文字加标记区间。Markdown 只做交换格式(agent 读写、导出、复制粘贴、搜索)【定】 |
| 基础代码 | MarkdownView 的逐块渲染。Composer 只借设计,不搬代码【定】 |
| 改动的表达 | 封闭枚举的可逆 step。撤销、同步、版本、agent 编辑都建立在 step 上【定】 |
| 同步 | 服务端定序,客户端 rebase(prosemirror-collab 的做法)。不用 CRDT【定】 |
| 版本记录 | 检查点 + step 日志。恢复旧版本 = 追加新 step,历史只往前走【定】 |
| reveal | 只在 agent 写文档时用;此时整篇是只读预览。打开文档、本地输入、其他设备的改动都不淡入【定】 |
| 多维表格 / 看板 | 文档内的一个数据库块,表格和看板是它的两种视图【定】 |
| 卡片 | 卡片块,和 `AnswerCard` 同构(source + data + size)【定】 |
| agent 编辑 | 块级操作(插入、改写、改一句、删除、移动、改类型、改卡片、改数据库),按块 id 定位;边写边经运行事件流显示在原位,每个操作写完才提交,能单独撤回【定】 |
| Web | 用 TypeScript 再写一份核心,两边跑同一套黄金用例;编辑视图倾向用 ProseMirror【倾向】 |

## 2. 为什么不直接存 Markdown【定】

1. **块没有身份。** MarkdownView 的块 id 跟位置绑定,`NodeViewCache` 的 key 和 descriptor id 都是内容哈希:中间插一块,后面全部错位。实时同步、撤销、评论、agent"改这一块",都需要稳定的块 id。
2. **块的属性放不进去。** 卡片的 data、表格的列定义、看板分组、作者(人或 agent),塞进 fence 或 HTML 注释都只是变通。
3. **并发合并会改坏语法。** `**` 本身就是文字。两端同时改一段,合并后可能变成没闭合的粗体。存成"文字 + 标记区间",就没有这个问题。
4. **撤销和版本只能靠文本 diff。** 不准,也没法知道是谁改的。
5. **Web 编辑器是树模型。** ProseMirror、Lexical 都是;存 Markdown,两端都要反复解析。

## 3. 文档模型(DocKit)

DocKit 是纯 Swift,不依赖 UIKit,要能在 Linux 上编译,因为服务端和 agent 也要读写文档。

### 3.1 结构【定】

```swift
struct Doc: Hashable, Sendable, Codable {
    var id: DocID
    var blocks: [Block]            // 平铺,顺序即文档顺序
}

struct Block: Hashable, Sendable, Codable, Identifiable {
    var id: BlockID                // 随机生成,终身不变
    var kind: BlockKind
    var indent: Int                // 0…6;列表嵌套、折叠的从属都靠它
    var text: RichText             // 不带文字的块(分隔线、卡片、数据库)为空
    var decoration: BlockDecoration?  // 装饰(Craft 的 Block:灰底加内边距),任何种类的块都能有;相邻的共用一个框
}

enum BlockKind: Hashable, Sendable, Codable {
    case paragraph
    case heading(level: Int)                   // 1…6
    case listItem(ListStyle)                   // bullet / numbered / task(done) / toggle(open)
    case quote                                 // 格式面板里是「装饰」,不是文字大小
    case caption                               // 说明:比正文小一号、次要色(Craft 的 Caption)
    case code(language: String?)
    case math                                  // 显示公式,text 是 LaTeX
    case divider
    case image(DocImage)                       // source、alt;适应/填充、自动/大图
    case link(DocLink)                         // 书签:url、标题、摘要、预览图、布局
    case file(DocFile)                         // 附件:blob、文件名、大小、布局
    case card(DocCard)                         // §3.4
    case database(DatabaseID, DatabaseView)    // §3.5
}
```

**为什么平铺、不嵌套:**
- 和 Craft 一致。
- MarkdownView 本来就把每个列表项拆成单独的块渲染,用 `ListItemContext.depth` 表示层级;一块正好对应 TiledView 的一行。
- 跨块选择、拖动、step 的寻址都更简单。

真正需要嵌套的东西(表格的行和格、数据库、卡片)自成一块,内部有自己的结构。引用先做成块的一个种类;引用里套列表、套多段,到时候看需求再定【待定】。

### 3.2 块内文字【定】

```swift
struct RichText: Hashable, Sendable, Codable {
    var string: String             // 偏移一律按 UTF-16 码元(TextKit 和 JS 用的都是它)
    var marks: [MarkSpan]          // 按起点排序,同种标记不重叠
}
struct MarkSpan { var range: Range<Int>; var mark: Mark }
enum Mark { case bold, italic, strike, code, link(URL), highlight(color), mention(EntityRef), inlineMath, cite, color(token), pen(kind, color) }
```

- 颜色是 MarkdownView 的颜色 token(`MarkdownColorToken`):Craft 色板的名字(gray、slate、purple、blue、cyan、mint、green、lemon、yellow、red)或 `#hex`,深浅色各有可读的色值。文字颜色、高亮颜色、笔迹(`circle` / `wavy`,MarkdownView 的笔迹注记)的墨色都用它。

- 行内原子(提及、行内公式、链接 chip)在 `string` 里占一个 U+FFFC,内容放在这个位置的 mark 上。光标不能停在原子中间。
- **标记在边界处要不要延伸**(在粗体末尾打字,新字是否还是粗体),按标记种类写死:粗体、斜体、高亮、文字颜色延伸;代码、链接、笔迹不延伸。

### 3.3 Markdown 互转【定】

- **导出** `Doc → Markdown`:
  - 卡片写成 ```` ```floo.card ```` fence(和聊天里一样),数据库按当前视图导出成 GFM 表格。
  - 每块单独导出一份 markdown,渲染(§6)、agent 读取(§9)和搜索都用它。
- **导入** `Markdown → Doc`:
  - 用 swift-markdown 解析,和 MarkdownView 用的是同一个 cjk fork;块 id 新生成。
  - 粘贴的流水线借 Composer 的:HTML 表格 → TSV → markdown。
- **黄金用例**:导入再导出必须等于规范化后的原文,用例和 Web 共用(§10)。

- **说明**(caption)写成 `<small>文字</small>` 一段;段落中间的 `<small>` 仍属于段落。格式面板的六种文字样式(标题、副标题、小标题、强调、正文、说明,⌃1–⌃6)对应 heading 1–4、paragraph、caption。

- **装饰**不进 Markdown,和布局一样是展示信息;agent 改写一块(删了重插)时装饰会丢,到时候看需要再定。

- **书签和附件**写成带 title 的链接,单独一行:书签 `[标题](url "bookmark")`,附件 `[文件名](blob:… "file")`,和引用的 `"cite"` 同一种写法。只有一条普通链接的段落仍是段落。摘要、预览图、文件大小和布局是展示信息,不进 Markdown。

- **颜色和笔迹**写成行内属性(swift-markdown 的 InlineAttributes,cmark 原生解析,内容可以嵌套加粗、链接等):`^[文字](color: red)`、`^[文字](highlight: yellow)`、`^[文字](pen: circle, ink: blue)`;默认颜色的高亮仍是 `==文字==`。导入也认 MarkdownView 的笔迹文本语法 `:circle[文字]{color=blue}`。文字里的 `^[` 转义成 `\^[`。

### 3.4 卡片块【定】

`DocCard{size, view?, source?, data: JSONValue?}`,和 `Wire.AnswerCard` 去掉 fence/item 之后的部分相同。

- 渲染用 `CardView`,和聊天里画出来的卡片是同一个组件,生成中同样用 shimmer。
- agent 可以重画一张卡(替换 source),也可以只更新 data。
- 用户能把聊天里的卡片直接拖进或复制进文档。

视图块 `DocView{source, data: JSONValue?}`(markdown 里是 ` ```floo.view ` 围栏,内容为 JSON):不是卡片,没有尺寸档,和页面同宽、按内容取高、不加外框(Cards 的 `ViewFrame`),用来放看板、对比、表单这类 OpenUI 式的内联应用。源码里没写样式的控件用 FlooDesign 的(`flooDesignControls()`),链接除外,仍按链接画;视图里的控件可以直接点,选中和拖动都交给块的把手。它的工具由宿主执行,其中 `send(message:)` 把内容发回会话。

### 3.4.1 链接、附件、图片、卡片的布局【定】

照 Craft:书签和附件共用一套布局 `DocLayout`——小(和名字一样宽的胶囊)、常规(整行:缩略图、标题、详情)、卡片(页面的一栏宽:预览在上,文字在下)。图片另有两项:适应 / 填充,自动 / 大图。改布局是 `setBlock` 换一个 kind,一次撤销退回;多选时一起改,是一个事务。连续的卡片并排,连续的图片成排。卡片照 Craft 窗口变窄时量的:每栏不窄于 140 时一行三张,不窄于 100 时两张,再窄一张,卡片间隔 8;卡片一样宽一样高(链接和附件同高);灰底块里并排的卡片各有一个灰底。每行只记它在哪一组、第几个,横向放在哪、多宽由列表排版时按实际宽度算,和文字换行一样,所以页面变宽变窄、旁边有侧栏都照样排对。拖放时块带着布局动效移到新位置:让位的行从原处滑到新处(TiledView 把同一项的删除再插入当作移动,不淡入),被移动的行先隐藏,系统的拖动图飞到它的新位置,落下后它才显示。

并排和成排不合并行:每一块仍是自己的一行,行 id 就是块 id。书签、附件、图片的行由 TiledView 按位置摆(`itemPlacement`:从页面左边起的 x、宽度、和前一行是否同一排),一排和其中最高的一块一样高(同一排的卡片取同一高度)。一串卡片或一组图片按 `DocMediaLayout.runFrames` 分排;缩进或装饰不同就断开。所以一块换布局、加入或离开一排,都是它这一行原地更新,不删不插,别的行只是换了位置。

floo 的卡片(`.card`,markdown 里是 ` ```floo.card ` 围栏,内容是尺寸、源码和数据的 JSON)也是这样一块:它按卡片包的拼接模式画(`CardGrid.tiled(gap: 8)`,8 是页面上媒体块之间的间隔;360 宽的一栏里 glance 176×176、summary 360×176、detail 360×360),整个缩放到给它的宽度(FlooDesign 的 `flooDesignScaled`:里面按设计宽度排,不重新折行,报给外面的是缩放后的高度),所以页面多宽它都是同样的样子。页面没有超大号:collection 按 detail 画,多出的内容按卡片的溢出规则裁掉。连续的卡片排成栏:页面放得下两栏(两张 summary 并排,卡片不小于设计的四分之三)就两栏,否则一栏;一栏分两个 glance 的位置,glance 占一个,其余尺寸占一栏;放不下就换到下一排。拼块同排等高,横向纵向都隔 8 按卡片的比例:每张卡片上方自带这段间隔(`DocCardGap`,按卡片自己的宽度算,不用知道页面多宽),卡片行在模型里不另加上间距。卡片在卡片包里画成方角(`CardFrame(cornerRadius: 0)`),缩放后套上链接和图片的框(`flooDesignMediaBox`:8 点圆角、淡描边),所以圆角在任何比例下都和它们一样。卡片没有布局可换。卡片的源码和数据随文档载入时编译,按卡片缓存:第一张会启动卡片运行时(约 240 ms),不能落在滚动或动画里。打开一张卡片(Mac 双击、手机轻点)交给 app(`DocBlockController.openCard`,没设就不打开);卡片要 app 做的事(调工具、取图片)走 `DocBlockController.cardHost`。卡片包用的是 floo 仓库里的 `Packages/Cards`(同级目录,本地包引用)。

书签只带地址和标题(markdown 里是 `[标题](url "bookmark")`);摘要和预览图由 app 从网页的 Open Graph 标签(没有就用 `<title>` 和 description)取来,只填书签空着的项。填写是 app 自己的事务,和 agent 的一样不进人的撤销栈,只让历史映射过去;每个地址只取一次。在空行里粘贴一个网址,这一行变成它的书签,光标到下面的新行(Craft 的做法),一次撤销退回。

改布局、改图片的大小或填充、改块的类型,都在 `withAnimation(Motion.layout)` 里做(`DocBlockController.reshape`);只换字号的六种文字样式(⌃1–⌃6)除外:文字没法插值,文字视图的 frame 被插值只会让它按半路的尺寸排版(多出来的行先不见、再一行行冒出来),所以它们不带动画,整行连同后面的行一步到位。其余不另画覆盖层:块自己变成新的样子,后面的行跟着走到新位置。书签和附件画在一个"盒子"里,盒子的大小只按当前布局算。三种布局用的是同一组部件(预览或图标、标题、摘要或详情、底栏),由布局(`DocLinkLayout`、`DocFileLayout`)摆到各自的位置;换布局时盒子从旧尺寸变到新尺寸,每个部件从旧位置走到新位置,文字的字号用 `contentTransition(.interpolate)` 过渡,图标按一个尺寸画、缩放到各布局的大小,新布局没有的部件淡出。这些都是 SwiftUI 自带的动画,在渲染时插值,和 TiledView 移动行的时钟在同一帧;逐帧重算 body 的自定义 Animatable 视图会在列表测量时就开始,比行早一帧,所以不用。图片是一个裁切的框,里面的图按原图比例算出画多大(适应:放进框里;填充:盖满框),框和画的大小都是普通的尺寸,所以适应和填充、自动和大图、画廊和单独之间都是插值过去的,不换 `contentMode`。行的位置由 TiledView 移动:带动画的 transaction 里来的 `.update`,被改的行在同一个动画里重绘内容,所有换了位置的行(往下,也往旁边)每一帧跟着它的动画进度走(同一个 SwiftUI 时钟,所以内容的底边和下一行始终贴着,不会差一帧)。动画没走完又来一次更新(快速连点)时,SwiftUI 让旧动画接着走、新动画把新旧终点的差叠上去(弹簧是线性的,这和从当前值、当前速度重新起一个弹簧是同一条轨迹);行也照这样叠加:每次更新记下各行布局上的位移,在途的移动不停,行的偏移是各次"位移 × 该次剩下的进度"之和。每次更新在行内容的时钟上占一个槽位(四个槽位的向量,各分量各走各的),给出它自己的进度。换到另一排的块从旧位置走到新位置,盒子同时从旧尺寸变到新尺寸;行的内容总按页面宽度排,不随行宽跳。块换类型或加减灰底块时，行的视图不换:文字行无论是不是引用都是同一个 `MarkdownSelectableText`,引用的样子(`markdownBlockQuote`)和灰底块(`DocRowBoxing`)都只是数值(内边距、底色透明度、圆角)随状态变,没有分支,所以文字视图留着,样子跟着行一起插值过去;换成另一个视图的话,SwiftUI 只能拆掉重建,块会瞬间变样。TiledView 那边有一条:含 UIKit 视图(文字视图)的 host,如果在画出带动画的新内容之前先被测量,新内容会在测量时被一次收下,动画就没了(纯 SwiftUI 的内容不受影响,和 UIKit 的动画开关无关);所以带动画的更新,cell 先按要测的宽度把新内容画出来再测。这时 host 还是旧高度,cell 的根撑满 host、内容贴顶(`TiledCellRootLayout`),host 换成新高度时内容不会因为居中而跳。撤销重做不带动画。Mac 上行在指针下移动时(滚动、改形状),指针下是哪一块等列表这次更新做完再查:更新中途对行做命中测试,会让行的 SwiftUI 内容先按行的旧尺寸排一次,它的动画就丢了。

单击选中,双击打开。打开都交给 SwiftUI 的 `openURL`(和 MarkdownView 正文里的链接一样),App 用自己的 `OpenURLAction` 接管:书签和网址附件给它的网址,本地附件给文件网址,图片写成文件再给文件网址(网上的图片给网址)。App 不接管时由系统打开;系统打不开的本地文件(手机上)用 Quick Look。`blob:` 附件还没有存储,双击不响应——附件放在哪里(本机、floo 服务端)待定。

### 3.5 数据库块:多维表格和看板【定】

```swift
struct Database { var id: DatabaseID; var columns: [Column]; var rows: [Row] }
struct Column { var id: ColumnID; var name: String; var type: ColumnType }   // 文本 / 数字 / 单选 / 多选 / 日期 / 勾选 / 链接 / 人
struct Row { var id: RowID; var cells: [ColumnID: CellValue] }
enum DatabaseView { case table(…), kanban(groupBy: ColumnID, …) }           // 列的显示、筛选、排序都放在视图里
```

- 数据库属于文档,存在同一个 Doc 里,改动走同一条 step 日志。
- 同一个数据库可以放多个视图块,比如一个表格加一个看板,它们看到的是同一份数据。
- 单元格里的文字先只做纯文本加简单标记,不在格子里嵌整篇文档。

## 4. 改动:step【定】

文档的每次改动都是一个 step。step 是封闭枚举,带足够的信息,能求出自己的逆。

```swift
enum DocStep: Hashable, Sendable, Codable {
    case insertText(BlockID, at: Int, String, marks: [Mark])
    case deleteText(BlockID, Range<Int>, removed: RichText)              // 带上被删的内容,才能求逆
    case setMark(BlockID, Range<Int>, Mark, on: Bool, previous: [MarkSpan])
    case splitBlock(BlockID, at: Int, newID: BlockID, newKind: BlockKind, newDecoration: BlockDecoration?)  // 回车:新块留在原块的框里
    case joinBlock(BlockID, into: BlockID, removed: Block)               // 退格把一块并进上一块
    case insertBlocks([Block], after: BlockID?)
    case deleteBlocks([Block], after: BlockID?)                          // 带内容和原位置
    case moveBlocks([BlockID], after: BlockID?, from: BlockID?)
    case setBlock(BlockID, kind: BlockKind, indent: Int, previous: (BlockKind, Int))
    case setDecoration(BlockID, BlockDecoration?, previous: BlockDecoration?)
    case database(DatabaseID, DatabaseStep)                              // 改格子、加删行、移行、改列、改视图
}
```

- **寻址用 `(BlockID, UTF-16 偏移)`,不用全文偏移。** 块 id 稳定,远端在别的块里改动,不会挪动本地的位置。
- `apply(_:to:) throws -> Doc`:target 块不存在就抛错,调用方负责丢弃这个 step。
- `invert(_:) -> DocStep`:有了逆,撤销和版本恢复都只是"追加逆 step"。
- `map(_ position:, through:) -> Position?`:把位置映射过一个 step。块被删了就返回 nil。rebase、远端改动后的选区还原、撤销都用它。
- **事务** `DocTransaction{steps, selectionBefore, selectionAfter, author, time}`:一次用户操作对应一个事务,比如回车、粘贴、加粗。

**测试**(swift-testing,属性测试):
- 随机文档上随机生成 step:先 apply 再 invert 回到原样;
- 随机并发 rebase 后,所有端收敛;
- Markdown 往返;
- 和 Web 共用 JSON 黄金用例。

## 5. 同步与协作:服务端定序【定】

### 5.1 做法

这是 prosemirror-collab 的思路,和 floo 现有的"云端为准 + 游标补拉 + SSE 门铃"同构:

1. 每篇文档在服务端有一条 step 日志,序号 `seq` 从 1 单调递增,和对话的 `pts` 是一回事。
2. 客户端本地先应用 step,同时放进待确认队列。提交时带上 `base`,也就是自己见到的最后一个 seq。
3. 服务端只做一件事:`base == head` 就接受并分配 seq,否则返回 409,带上缺的那些 step。服务端**不需要读懂 step**,payload 可以是密文。
4. 客户端拿到缺的 step 后先应用它们,再把自己待确认的 step 映射过去(rebase),然后重新提交。
5. 新 seq 到达时,SSE 只发门铃(`doc N 到了 seq M`),各端按游标补拉。

**为什么不用 CRDT:**
- 所有端都按服务端的同一个顺序应用 step,天然收敛。不需要 OT 的变换性质,也不需要 CRDT 的墓碑和元数据。
- Loro 的 Swift 绑定是实验性的,只有 xcframework;automerge-swift 在 Linux 上直接编译报错。服务端和 agent 都在 Linux 上,用它们就得自己编 Rust FFI。
- SyncKit 的定位本来就写着"不用 CRDT"。

**代价**:两台设备都长时间离线、改同一句话,回来后按到达顺序 rebase,两边的字会交错,不会智能合并。文档场景能接受。被删块里的待提交改动会被丢弃,丢弃时要提示用户。

### 5.2 服务端【倾向】

```sql
create table floo.doc_step (
    account_id uuid   not null,
    doc_id     uuid   not null,
    seq        bigint not null,       -- 每篇文档内单调,从 1 起
    op_id      uuid   not null,       -- 客户端生成,重复提交去重
    client_id  uuid   not null,       -- 设备或 agent 运行
    payload    bytea  not null,       -- EncryptKit 信封:[DocStep] + 作者 + 时间
    created_at timestamptz not null default now(),
    primary key (account_id, doc_id, seq)
);
```

- **端点**:
  - `POST /v1/docs/{id}/steps {base, op_id, steps}` → `{seq}`;落后时返回 409 加缺的 step;
  - `GET /v1/docs/{id}/steps?after=`;
  - `GET /v1/docs/{id}/events`(SSE 门铃)。
- **文档元数据和检查点**:
  - 用现有的 `record` 存,集合叫 `docs`,内容是标题、`checkpoint_seq`、检查点快照或它的 BlobRef。文档列表因此直接走 SyncKit。
  - 检查点每 200 个 step 或空闲 30 秒打一次,由提交方顺手上传。
- **加密**:集合 `docs` 用一把云端打得开的 DEK,和对话一样,这样 agent 才能读写。
- **在线状态**:"agent 正在写"(§6.3)是必需的,带 run id 和过期时间;别的设备的光标可有可无。走一条不落库的 SSE 通道,具体形状【待定】。

### 5.3 设备端

- 本地 GRDB 存检查点、已确认的 step 和待确认队列。打开文档时先读本地,不等网络。
- 离线编辑照常进待确认队列,恢复网络后自动 rebase 并提交。

## 6. 渲染:编辑和查看同一种实现【定】

### 6.1 结构

- 文档是一个 TiledView,一块一行,行 id 就是 `BlockID`。块身份的问题就此解决:插入一块只是插入一行。
- 锚定在顶部:`autoScrollsToBottomOnAppend` 和 `scrollsToBottomOnReplace` 都关掉,这两个开关默认就是关的。
- 每块的视图 `DocBlockView`:
  - 文字类块(段落、标题、列表项、引用、说明)用 `MarkdownSelectableText`,输入是 DocKit 直接从模型建的节点树(`Doc.markupTree(of:)` → `MarkdownTree`),不写成 markdown 也不解析:用户打的字原样显示,不会被当成语法(`==`、`$`、`:circle[`);颜色、高亮、笔迹、行内公式是树里的节点。这棵树和这一块的编辑用 markdown 解析出来的结构相同(DocKit 测试逐块比对),渲染器原样复用:设计、缓存、`RichTextViewPool`、数学公式高度缓存、reveal 都不变。agent 写作中的临时层是模型流出来的 markdown,照旧按 markdown 渲染,提交成块后就走树。
  - 代码、公式、分隔线和表格同样由 DocKit 建树(代码块、`math` 指令、分隔线、表格节点),交给 `MarkdownBlockView(tree:)`,走 MarkdownView 原来的 SwiftUI 路径;树的文字不读文本层语法,表格单元格(数据库的值,公式列显示算出来的结果)也原样显示。只有链接、文件、图片是 App 自己画的,没有树。编辑时换成各自的编辑器。代码借 Composer 的做法用 Runestone 编辑器,公式是源码加实时预览。
  - 卡片、数据库是 App 自己的视图,和现在 `floo.draw`/`floo.card` 走 `customFence` 一样。
- 性能沿用聊天里调好的那些手段:只测量视口内的行、按长度估高、后台解析、行 Equatable。行的比较改成按 `(BlockID, 块的修订号)`。

### 6.2 编辑在同一个文本视图里

- 获得焦点的块,它的 UITextView 打开 `isEditable`;其余块保持只读,点进去时再打开。
- **输入的路径**:
  1. `shouldChangeTextIn` 把这次改动翻成 step;
  2. step 应用到模型;
  3. 先让 TextKit 自己改 storage(快);
  4. 再用模型重新渲染这一块,和 storage 比较:一样就什么都不做;不一样(比如触发了 markdown 快捷键)就替换 storage,并按 step 映射还原光标。
- **偏移换算**:storage 是列表符号加上模型的文字(空块和空的末行补一个零宽空格),偏移按这个前缀换算;不在同步状态时不信任 storage。
- **IME**:有 marked text 时不生成 step,上屏后一次提交。这一点借 Composer。
- **快捷操作**:
  - 回车拆块,在空列表项上回车退出列表;
  - 块开头按退格并进上一块,Tab / Shift-Tab 改缩进;
  - `# `、`- `、`1. `、`[] `、`> `、` ``` `、`---` 变换块类型;
  - 行内 `**x**`、`` `x` `` 变换标记;
  - `/` 唤出命令菜单(Craft 的):打出 `/`(中文输入法的「、」也算,在词后面也算;键盘栏的 `/` 键也打出一个),字符留在文字里,菜单打开;接着打的字过滤命令(展开成平铺列表,开头对上的排前面),一个都对不上(打的是路径、分数)就关掉,↑↓ 移动,回车或点按选择,退格在分组里是返回上一级(不删字),Esc、空格或点菜单外任何地方关闭(这一下只关菜单)。菜单是 Craft 的样子:透明玻璃外壳,里面隔一点边距叠一层高模糊材质(thick material);在光标那一行上方(上面放不下才放下面,两边都不够就放宽的一边、少露几行),可以盖住键盘栏的上半(下沿到栏的中间为止,照 Craft 量的),碰不到键盘,出现和消失都用 FlooDesign 的出现/消失动效(从光标那侧,出现 0.2 秒缓出、消失 0.13 秒缓入,缩放 0.975),关掉时在原处带着原来的内容退场;Mac 上指针悬停的行就是高亮行,靠右,每行图标加标题,分组带 ›,高度随行数、最高 320 点(Mac 260)、其余滚动,第一行高亮。位置在打开时定下:分组点进去、打字过滤都在原处换内容。菜单开着时页面不滚动。Mac 上同一个菜单(行矮一些、字小一些),方向键选择,回车选择或进分组,退格返回或关闭,Esc 关闭、斜杠留下。内容按 Craft 的顺序,只放 DocKit 做得到的:列表 ›、缩进 ›、文字样式 ›、操作 ›(复制、创建副本)、装饰 ›(引用、块)、颜色 ›、插入表格 ›、代码块、公式块、分割线、清除格式(标记、颜色、块框去掉,类型不变)、删除块;Craft 的助手、对齐、字体、提醒、每日笔记、社交、片段、封面、合集没有对应功能,不放。
  
  每一种都是一个事务,一次撤销就能退回。
- **风险**:`MarkdownSelectableText` 现在靠"原文相等就跳过更新"来保住 reveal 的着色;编辑时每次按键原文都会变。好在编辑和 reveal 不会同时发生(§6.3):编辑时环境里没有 reveal manager,不存在着色被刷掉的问题。剩下的是性能和光标:需要一个钩子,让正在编辑的块直接沿用 TextKit 已经改好的 storage,不必每键整块重建。D3 第一件事就是把这个钩子原型做出来(§11)。

### 6.3 reveal:只给 agent 的输出【定】

- 复用 `StreamingRevealCoordinator`、`RevealCoordinator` 和 `markdownFadeReveal`,不另做。
- **什么时候不淡入**:打开文档(和聊天里加载历史消息一样,环境里不放 reveal manager,直接显示全文)、本地输入、其他设备同步过来的改动。
- **agent 写文档时**:
  - 整篇切到只读预览:所有块关掉 `isEditable`,本地不再产生 step。进入时先把本地待确认的 step 提交掉,收起键盘。
  - agent 写到一半的内容经运行的事件流到达各端,画在原位并 reveal,节奏和视觉与聊天里的流式回答完全相同;每个操作写完才提交成 step(§9.3)。
  - 新块:整块进入 reveal,逐字淡入;块尾追加:现有逻辑已经只淡入尾部。
  - **块中间插入或替换**(agent 改写某一句,§9.3):要新增一种按区间淡入的方式。`RevealCoordinator.contentDidChange` 现在只比较公共前缀;再加上公共后缀的比较,只给中间那段新字打首见时间戳。
  - agent 写完,reveal 播完后回到编辑模式。中途要能停下 agent;停下时已经提交的部分保留,作为 agent 那次事务的一部分,能整体撤回(§8)。"停下"长什么样在 demo 里定。
- **其他设备也一起进入预览**:"agent 正在写这篇文档"作为文档的在线状态广播出去(§5.2),带 run id 和过期时间。agent 异常退出时,过期后自动解除。
- 因为 agent 写的时候没人能编辑,agent 的 step 和人的输入在同一篇文档里不会交错。§5 的 rebase 仍然保留,用来处理多台设备之间的并发和离线编辑。

### 6.4 选择

- **块内选择**:就是 UITextView 自己的选择。
- **块选择**:沿用 `MarkdownBlockSelectionController`,用来批量移动、删除、改类型。
- **Mac 上的点击**:单击一个块选中它(⇧ 扩展、⌘ 增减),在块上任何地方按住拖动就直接拖走,旁边的手柄也一样。只有选中的块自己接收点击:指针在选中块的文字上才变成 I 形,再点一次才放下光标开始编辑;表格的格子、代码和公式也是第二次点才进入编辑。进入编辑以后,所有有文字可编辑的块(文字、表格、代码、公式)都接收点击,指针在上面就是 I 形,点哪里就直接编辑哪里;点链接、文件、图片、分隔线仍是选中它,编辑随之结束,之后又回到先选中再编辑。编辑时按 Esc(斜杠菜单开着时先关菜单)结束编辑,选中正在编辑的块(文字、格子所在的表格、代码、公式都一样),回到选中状态。链接、文件、图片、分隔线选中后再点仍是选中,双击打开。没选中的行不做命中测试(`allowsHitTesting`),点击和拖动交给列表上的按压手势(`DocBlockController.blockTakes`)。agent 写作时整页是只读预览,行照常接收点击。手机不变:长按拿起或开始选择。
- **手机上的点按**:点一下就编辑(文字放光标),链接、文件、图片点一下就打开。长按拿起块(列表项只拿起它自己,下面的子项开始拖动后才加入):拖动就移动,不动松手就进入选择模式,不等块落回(系统要等落回才告诉拖拽,所以列表上有个只看不认的手势 `DocTouchEnds` 看手指抬起;这次按压不算点按,松手不编辑也不打开:拿起时取消按下处的手势)。在块上左右滑动(任一边,横向超过 80 点)也选中它(flowith Composer 的:行跟手位移,带阻尼最多约 72 点,松手 0.2 秒缓出回位,快速轻扫 0.15 秒);正在编辑文字时不能拖块,长按留给文字(放大镜、选字)。
- **手机上的块选择模式**:和聊天里的多选块模式是同一个(`MarkdownBlockSelectionController` 和 `MarkdownBlockSelectionOverlay`,样式在 `MarkdownBlockSelectionStyle`)。圆点画在页面上方的浮层里,不占布局,页面左右边距相同。模式里行不接收点按:点任何块都是选中或取消它,不会进入编辑;从右侧 64 点的圆点列按下拖动,经过的块一起选中或取消(由第一个块决定),到上下边缘会自动滚动;滑动也增减一个;选空了就退出。文档关掉了按组选(聊天按消息选)。
- **选中的样式**:强调色 10% 的填充、圆角 10、没有边框,每个块各自一块,相邻的不连起来(Craft 的,也是聊天的)。手机上由浮层画在行上,Mac 上由文档画在页面两侧各宽出 10 点;上下比文字各多出 3 点(块之间的间距让相邻的仍分开)。链接、文件、图片不填色,只描自己的边框。
- **选中和拖动列表项**:选中列表项只选它自己,高亮也只在它上面;拖动、删除、复制时带上嵌套在它下面的项。
- **拖放**:用系统的拖放(`UIDragInteraction` / `UIDropInteraction`),和 Craft 一样。每个移动的块一个拖动项,系统显示数量角标。每个块从自己的行上抬起:手机上衬着抬起的页面底色,移动时叠成一摞缩小在手指下;Mac 上没有底色,系统画成半透明的行。拖动时原来的行变暗;松手时块先移到新位置、列表立刻排好,系统把预览飞到新行上,飞到之前新行保持变暗。落点的线和自动滚动是自己算的。
- **Mac 上选中文字的工具条**(仿 Craft):选区停稳约 0.2 秒、文字视图有焦点时,在选区第一行上方、从块文字起点出现一条胶囊:高亮(⌘⇧B)、颜色、加粗、斜体、删除线、代码(⌘⇧X、⌘E)、链接、格式面板。颜色在原处展开:无、七种高亮、任意色相的高亮、六种文字颜色、任意文字颜色;选好回到按键。光标、只读预览、跨块选择时不出现。iOS 用系统编辑菜单和键盘上方的工具栏,不用它。Craft 的文字颜色是渐变,行内公式、@ 和评论三个键 demo 里还没有对应功能,先不放。
- **手机上的格式**(仿 Craft):
  - 键盘上方的工具栏(Craft 的做法:是页面自己的一条实心栏,不是系统的输入附件;贴在键盘顶上随键盘升降,底色一直铺到键盘下面,从键盘后面滑出、滑回,命令菜单可以盖在它上面):有光标时是 `/`(打出斜杠并打开命令菜单,在词后面也打开)、`Aa`(选中光标所在的块,弹出格式 sheet)、`⋮`(选中光标所在的块,进入块选择;选择结束回到编辑,光标复原),右边收键盘,空行多一个分割线键;选中文字时是高亮、加粗、斜体、删除线、代码、链接、收键盘,高亮键在上方弹出颜色:上排无颜色、六种文字颜色、任意文字颜色,下排七种高亮、任意高亮。
  - 格式面板两处打开:选中块时底部的「样式」,和键盘栏的 `Aa`(选中光标所在的块再弹出;关掉 sheet 回到编辑,光标复原)。主页是两种常用样式和「更多…」、列表与缩进、引用与块、颜色、`…`;「更多…」是六种样式,颜色页是默认、十种颜色和任意颜色(系统取色器),`…` 是加粗斜体删除线代码和拷贝/粘贴格式(块的类型、装饰和整块的标记,一次撤销)。各页同高,选了就回主页。手机上选中块时,操作栏的「样式」和「布局」打开系统 sheet,高度量内容定死(`presentationDetents` 的 `.height`,Craft 的做法:浮在底部、四边留空),打开时操作栏让开,下拉或退出选择就关。操作栏一直在视图里,显隐只由「在选择且没开 sheet」决定(滑动加淡入淡出,不插入移除),退出选择时键盘回来也不会留下;sheet 里的「更多…」、颜色、`…` 各是叠在上面的新 sheet,选了或下拉回到主页。这些 sheet 用系统的手柄和下拉,不另加手势(加了会挡住 sheet 自己的)。Craft 的对齐、字体、页面/卡片 DocKit 还没有,不放。
- **跨块文字选择**:文档层自己维护 `(块, 偏移)` 的锚点和焦点。中间的块整块画选中,两端的块用各自的 UITextView 选区。复制、删除、加标记都按文档选区生成 step。Composer 没有这项,放在 D6。

## 7. 撤销 / 重做【定】

- **每个客户端只撤销自己的改动。** 历史里存的是自己的事务(step 的逆加上选区)。
- **撤销**:取最近一个事务的逆 step,映射过这之后到达的远端 step 再应用。远端改动不会清空本地历史(Composer 的 `applyRemoteDocument` 会清空,这是它的问题之一)。映射后目标已经不存在的 step 丢弃;整个事务都丢光了,就跳过它,接着撤销上一个。
- **合并**:连续输入按 `(块, 输入会话)` 在 1.5 秒内并成一次;换块、移动光标、空格加停顿都会断开。这一点借 Composer 的 intent/session 设计。
- 只有一套撤销,所有改动都走事务,不会有 Composer 那种新旧两套撤销并存。
- 撤销栈属于文档会话,不是全局静态的,所以同时开多个编辑器也互不干扰。
- 重做栈在有新的本地改动时清空,远端改动不清空它。
- 键盘 ⌘Z / ⇧⌘Z,iPhone 上摇一摇和三指手势,都接到系统 `UndoManager` 上,只是它的实现是我们的事务栈。

## 8. 版本记录【定】

- **自动版本**:按作者和时间切成一段一段,比如"你,10:02–10:15""agent,10:16"。列表从 step 日志和检查点算出来,不额外存数据。
- **命名版本**:在某个 seq 上打一个名字,存在文档元数据里。
- **查看旧版本**:从最近的检查点重放 step 到那个 seq,用同一个渲染器以只读方式显示,和当前版本之间的差异逐块标出。
- **恢复**:算出"从当前到旧版本"的 step,作为一个新事务提交。历史不改写;恢复本身也能撤销,也会出现在版本列表里。
- **撤回 agent 的一次修改**:就是把 agent 那次事务的逆 step rebase 到当前状态。这和 Composer 的 diff 卡片对应,但能真正撤回。
- **保留期限**:step 日志多久合并一次,检查点保留多少【待定】,先全部保留。

## 9. agent 读写与编辑

### 9.1 读【倾向】

`doc_read` 返回每块的 `{id, kind, markdown}`,这是 Craft API 的形状,模型最熟悉。数据库返回列加行,卡片返回 size 和 data 的摘要。长文档可以只读一个范围(从某块起若干块),或者按文字搜到块。

### 9.2 写:块级操作【定】

`doc_edit` 收一组操作,每个操作独立:

| 操作 | 参数 | 说明 |
|---|---|---|
| `insert` | `after` / `before` 某块,或文档开头、结尾;`markdown` | 一段 markdown 可以变成多块 |
| `replace` | 一块或连续几块;`markdown` | 改写;新内容可以比原来多块或少块 |
| `edit` | 一块;`find`、`replace` | 只改块里的一句、一个词。最省 token,也最不容易误伤 |
| `delete` | 一块或连续几块 | |
| `move` | 一块或连续几块;`after` / `before` 某块 | |
| `set` | 一块;类型、缩进、勾选状态 | 例如把段落变成标题、把任务勾掉 |
| `card` | 一块;新的 source,或只给新的 data | 重画或更新卡片 |
| `database` | 一个数据库;改格子、加删行、移行、改列 | |

- **定位**:用 `doc_read` 给出的块 id。按"模型什么字段都会填"的经验,解析要宽容:id 不存在时,按块的文字开头去匹配;还是找不到,就返回错误并附上附近几块的 id 和开头,让 agent 重试,而不是猜。
- **翻成 step**:服务端在提交时的最新版本上把操作翻成 step。
  - `replace` / `edit` 对新旧文本做最小 diff,只生成真正变了的插入和删除,原有标记和块 id 尽量保留。
  - 新块的 id 在操作开始时就由操作 id 和序号确定,提交前后不变(见 §9.3)。
  - 操作指向的块已经被别的设备删掉:这一个操作失败,返回给 agent,其余照常。
- **一个操作一个事务**:每个操作单独成一个事务,作者是这次运行。所以既能撤回 agent 这次运行的全部修改,也能只撤回其中一处。

### 9.3 边写边看【定】

agent 写一段新内容或改写一块要花几秒,各端都要看到它在原位写出来,但写到一半的内容不能进 step 日志。

- **过程走运行的事件流,结果走 step 日志。** agent 生成操作时,`markdown` 是一边生成一边推的,经现有的 `runs/{id}/events` SSE 发出。"正在写"的在线状态里带着 run id,其他设备据此订阅。
- 各端把写到一半的操作画成一层**临时内容**,叠在文档对应的位置。它不进模型,也不进撤销栈。
  - 临时内容用 Markdown 导入(§3.3)增量转成块,渲染和 reveal 与聊天里的流式回答完全相同(`MarkdownStreamParser` → 块 → reveal)。
  - 新块的 id 一开始就确定,所以提交时临时块直接变成真块,行不重建、不闪。
- **操作写完即提交**:服务端翻成 step、分到 seq,各端收到后丢掉临时层。内容一模一样,屏幕上没有变化。
- **各操作在屏幕上的样子**:
  - `insert`:新块在位置上出现,逐字淡入,和聊天一样。
  - `edit`:被替换的那几个字换成新字,只淡入新字(§6.3 的按区间淡入)。
  - `replace`:改写一整块时,旧内容和新内容怎么过渡(例如旧文字变淡、新文字在原处写出),在 demo 里做两三种给你看【待定】。
  - `delete` / `move` / `set`:直接生效,用 TiledView 已有的行动画。
- **跟随**:agent 改的地方不在屏幕上时,第一处改动开始前滚过去;用户自己滚开后就不再跟,出现一个"回到 agent 正在写的地方"的入口。入口的样子在 demo 里定。
- **中途停下或出错**:已经提交的操作保留;正在写的 `insert` 保留已经写完的整行,和聊天里停下时一样;正在写的 `replace` / `edit` 丢弃,原文不动,因为改写到一半比原文更糟。

### 9.4 和对话的关系【倾向】

- agent 在对话里改文档,对话里出一张工具卡:写明改了哪几处,点一下跳到文档里的对应块,每一处都能单独撤回。这接替 Composer 的 diff 卡片,但能真正撤回。
- 工具的具体形状写进 floo 的 agent-kernel 文档;这里定的是"块 id + markdown + 操作列表"这一层,以及边写边看的机制。

## 10. Web【倾向】

- **核心**:用 TypeScript 写一份 `@floo/doc`,包括模型、step、apply/invert/map、rebase 和 Markdown 互转。
  - 正确性靠共享黄金用例保证:Swift 测试生成 JSON 用例(文档 + step 序列 + 期望结果),两边都必须通过。
  - 不把 Swift 编译成 Wasm 给 Web 用:包太大,而且核心逻辑不多。
- **编辑视图**:倾向 ProseMirror。它的 schema 能和平铺块一一对应;再用一层桥,把 PM 的 transaction 翻成我们的 step。
- **视觉**:按同一套设计写一份 CSS 版,reveal 用逐字的 CSS 动画移植。
- 不在第一期。先把模型格式和 step 的线上格式定死,保证 Web 以后能接上。

## 11. 实施(demo 先行)

所有界面都先在 MarkdownView-demos 里做,你确认后才移植到 floo。

| 阶段 | 内容 | 验收 |
|---|---|---|
| D1 | DocKit:模型、step、事务、撤销栈、Markdown 互转、内存里的"服务端"和 rebase | swift-testing 属性测试全部通过;macOS 和 Linux 都能编译 |
| D2 | demo 里的文档页:只读渲染、顶部锚定;一个脚本化的 agent 在文档里插入新段落、改一句话、改写一块、删除和移动,整篇只读并 reveal;`replace` 的几种过渡给你挑 | 用一篇长文档跑聊天那套基准,最长帧和滚动卡顿接近聊天;agent 每种操作各录一段 |
| D3 | 在同一个视图里编辑:输入、IME、拆块合块、快捷变换、斜杠菜单、撤销重做。第一件事是 §6.2 的 storage 钩子原型 | 录屏;撤销重做的脚本化测试 |
| D4 | 卡片块、数据库块(表格视图 + 看板视图)的显示和编辑 | 录屏 |
| D5 | 模拟协作:同一屏两个编辑器,加一个脚本化的 agent,经过内存服务端互相同步;agent 写时两边一起进预览;版本记录面板 | 录屏;随机并发测试收敛 |
| D6 | 跨块文字选择 | 录屏 |
| 之后 | 移植进 floo:DocKit 进 Core,服务端加 `doc_step` 和端点,App 接入;再做 Web | 走 floo 的流程 |

界面上的尺寸、颜色、动效和可复用组件在单独的仓库 `FlooDesign`(Swift Package,iOS 和 Mac Catalyst;仿 Matrix HQ 的 `MatrixDesignSystem`)。`FlooDesignTokens` 先按家族——状态、颜色角色、透明度与材质、字、间距、控件、图标、圆角、描边、阴影、动效——再按组件;颜色用 UIKit 的语义色,只在指针和手指确实不同的地方分开(`Platform.value`)。所有动画都是 `Motion` 里的角色(反馈、布局、滚动、出现/消失),减弱动态效果时去掉位移和缩放、保留淡入淡出;唯一例外是键盘栏跟随键盘自己的曲线。组件:锚定浮层、命令菜单、原生菜单的触发按钮、出现/消失(`flooDesignReveal`,视图一直在、只跟随状态)、底部操作面板、选项、分段、色块与取色(彩虹色块上叠系统取色器)、各种按钮样式(主要/次要/无边框文字按钮、键、瓷片、圆形完成键;Mac 上统一有悬停、按下、禁用状态)、按内容定高的 sheet、徽标、玻璃、浮在文字上的胶囊工具条、链接和文件卡片(小/常规/卡片三种)、文件图标、布局示意图、媒体外框和选中描边、拖动手柄与落点线(UIKit)、键盘栏按键;UIKit 视图用 `UIKitColor` 取同一套颜色角色。文档页只保留自己的版式数值(`FlooDesignTokens+App.swift` 里对 `Component` 的扩展,取自家族)和文档内容本身的排版(`DocTypography`、MarkdownView 的块选择样式),组件和状态一律用 FlooDesign 的。文档内容自己的字体和行距仍在 `DocTypography`。Mac 版是 Mac 的界面(Optimize for Mac,不按 iPad 缩小画),Mac 的文字样式比手机小(正文 13 点),所以正文放大 1.16 倍、标题 1.24 倍(代码、表格、说明跟正文),和 Craft 在 Mac 上的字一样大(从同一段文字的截图量出)。这个倍数是 MarkdownView 的(`MarkdownTextScale`),聊天里的 Markdown 也一样。

动效只有几种角色:`feedback`(控件的回应,snappy 0.18 秒)、`layout`(东西换尺寸、换位置,以及被它带动的行:无回弹弹簧 0.34 秒)、`scroll`(列表自己滚动:无回弹弹簧 0.5 秒)、出现和消失(easeOut 0.20 / easeIn 0.13 秒)。系统"减弱动态效果"打开时 feedback 和 layout 不动,淡入淡出保留。两个包各自暴露同样的角色:MarkdownView 的 `MarkdownMotion`(feedback、layout、reveal 曲线和时长,`.markdownMotion(_:)`),MessagingUI 的 `TiledMotion`(layout、scroll、feedback、reveal 时长,`.tiledMotion(_:)`);默认值取包原来最常用的值(原先各处零散的 0.15–0.4 秒归到这几个角色上),app 在根上用 `Motion.markdown` 和 `Motion.tiled` 把自己的 token 交给它们。代码里不写动画的数字,只写角色。

界面文字也照 Matrix HQ 的做法本地化:一个 `Localizable.xcstrings`,英文原文当 key,简体中文手写,快捷键符号原样保留(「Highlight · ⌘⇧B」→「高亮 · ⌘⇧B」),格式占位符两边一致。文档内容和示例语料不翻译。目前覆盖文档页和侧栏的 floo 三项;floo 对话 demo 的界面文字和它的中文剧本混在一起,还没拆。

D1 是纯模型,不涉及界面,可以直接开工。工具栏、斜杠菜单、版本面板的样子都在 demo 里给你看过再定,这份文档不决定界面。

## 12. 从 Composer 借什么、不借什么

- **借**:
  - intent → 事务、按输入会话合并,以及它的历史测试用例(改写成我们的);
  - IME 期间不记历史;
  - 解码时保留不认识的块;
  - 粘贴流水线;
  - 远端到达时有未保存编辑就先暂存,保存后再应用(在我们这里由 rebase 取代)。
- **不借**:
  - 两套撤销并存;
  - 整篇快照式的历史;
  - 每次改动重配所有 cell;
  - 远端到达清空历史;
  - 全局静态的活跃控制器;
  - AI 工具直接改 `vm.document`;
  - 表格用 `UITextField`;
  - 整篇最后写入者胜。
