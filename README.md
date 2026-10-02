# GoodTripPlus

《以撒的结合：忏悔+》的小地图传送模组，基于 **Goodtrip MLX's Tweak**（Steam 创意工坊 3749565569）二次开发。

与上游相比只做三处改动：

1. **修复**了使用控制台 `rewind` 指令后，小地图上所有掉落物图标全部消失的问题（见第一节）。
2. **合并**了 Lazy Delver 的隐藏房候选标记，并把标记对齐到 MinimapAPI 的真实布局（见第二节）。
3. **新增**了「传送到未探索的相邻房间」功能，默认关闭（见第三节）。

---

## 一、修复的 Bug

### 现象

在小地图传送游玩过程中，如果打开控制台输入：

```
rewind
```

`rewind` 会「撤销当前房间内产生的所有变化，并把你送回上一个房间」（相当于强化版后悔药 / 发光沙漏效果）。

此时小地图上**所有房间的掉落物图标（道具、卡片、药丸等）会全部消失**，而且不会自己恢复——
必须重新走进每一个房间，那个房间的掉落物图标才会重新出现。

### 根因

掉落物图标是由 **MinimapAPI** 负责绘制的，数据缓存在 MinimapAPI 自己的房间对象上：`room.ItemIcons`。

关键点在于：**MinimapAPI 每帧只会重算「玩家当前所在房间」的图标**
（`MinimapAPI:GetCurrentRoomPickupIDs()` 内部用的是 `Isaac.GetRoomEntities()`，只能拿到当前房间的实体）。
其余房间的 `ItemIcons` 一直保留着「玩家当时待在那个房间里」看到的那一份。

`rewind` 本质上是一次**关卡状态回滚**（和发光沙漏同一套机制），它会让 MinimapAPI 把整张地图的数据
重建一遍。MinimapAPI 里负责重建的代码是：

```lua
-- minimapi/scripts/minimapapi/main.lua
function MinimapAPI:LoadDefaultMap(dimension)
    ...
    MinimapAPI.Levels[dimension] = {}
    ...
        ItemIcons = {},   -- 所有房间对象重新生成，图标一律为空
    ...
end
```

所有房间对象被丢弃重建，新对象一律 `ItemIcons = {}`。而图标只在「玩家待在房间里」时才会产生，
所以回滚之后整张地图的掉落物图标都是空的，只能一个个重新进房间刷出来——与现象完全吻合。

**已实测确认的触发点**：`rewind` 会触发 `MC_POST_GAME_STARTED`（`continued=true`），
MinimapAPI 注册在这个回调上的 `MinimapAPI.OnGameLoad` → `LoadSaveTable` 会把整张地图数据重建一遍。
游戏内 `gtpdiag` 在那一帧记录到的是 `rebuilt=1 lost=4 sameFloor=true`
（1 个维度的房间数组被换掉，4 个原本有图标的房间同时清空）。
第一版修复曾把这个触发点猜成 `MC_POST_NEW_LEVEL`，**实测该回调在 rewind 时根本不触发**，因此作废。

（发光沙漏为什么没这个问题：MinimapAPI 为它单独留了一条 `CopyLevels` / `RewindLevels` 通路，
由 `MC_USE_ITEM` 触发，会在重建后用备份把图标贴回来。`rewind` 是控制台指令，不会设置那个标记，
所以走不到这条恢复路径。）

### 修复方式

`scripts/gtp_rewindfix.lua`。既然根因已确认，为什么不直接挂 `MC_POST_GAME_STARTED`？
因为监视方案不依赖触发点，将来游戏或 MinimapAPI 改动触发路径时修复依然有效，代价只是每帧遍历一次
MinimapAPI 的房间表（几十个房间，远小于 MinimapAPI 自己每帧的开销）。做法：

1. 每帧（`MC_POST_UPDATE`）读取一次 MinimapAPI 的地图数据，保存：
   - 各维度**房间数组本身**（用来识别 `ClearLevels()` + `LoadDefaultMap()` 是否重建过地图）；
   - 各维度「有图标的房间」及其 `ItemIcons` 的**深拷贝**。
2. 与上一帧比较，判定是否发生「整批清空」：
   - 上一帧有图标、这一帧变空的房间 **≥ 2 个**；或
   - 地图被重建（房间数组被换掉）且**至少丢了 1 个**房间的图标。
   一次合法拾取最多只能让 1 个房间变空，所以不会被误判。
3. 判定为整批清空、且**层身份一致**（同层回滚）时，把上一帧（= 回滚前）的 `ItemIcons`
   贴回**当前为空**的房间——只填空房间，绝不覆盖 MinimapAPI 自己算出来的数据。
   层身份由 `stage / stageType / absoluteStage / startSeed / 房间数 / IsAscent` 组成，
   正常下楼换层时身份会变，地图依旧从干净状态开始。
4. **只还原「已探索过」的房间**（`Descriptor.VisitedCount > 0`）。
   `rewind` 会把「你刚离开的那个房间」回滚成没进去过的状态（`VisitedCount` 归 0），
   它在地图上应当只是一块未探索的深色格子。但它此刻是当前房间的邻居，
   MinimapAPI 会给它来一发 `adjroom.DisplayFlags |= AdjacentDisplayFlags`（通常 = 5，含 bit4 图标位），
   于是 `IsIconVisible()` 为真——如果不加判断，就会把回滚前那一帧记下的掉落物图标贴回去，
   出现「没探索过的房间却显示掉落物」。所以未探索的房间一律跳过。

   判定刻意读**当前存活的** `room.Descriptor.VisitedCount`，而不是 MinimapAPI 房间对象上的
   `Visited` 缓存：后者是重建那一刻写下的快照，存活描述符才是游戏此刻的真实状态。
5. 关卡重建发生在 update 阶段，而 `MC_POST_UPDATE` 在 update 末尾、渲染之前执行，
   所以还原发生在这一帧被画出来之前，不会出现闪烁。

**这是一个 bug 修复，没有开关**：只要模组启用就一直生效，MCM 和 `gtconfig.lua` 里都不提供该选项。

### 自查手段

游戏内控制台输入 `gtpdiag`，会打印层身份、修复开关、累计命中次数、各维度房间数与带图标房间数，
以及最近 16 条事件（`POST_NEW_LEVEL` / `POST_NEW_ROOM` / `POST_GAME_STARTED` 的触发、
每次判定为清空时的 `rebuilt/lost/sameFloor` 与前后层身份、恢复了多少个房间）。

命中修复时控制台会直接打印：

```
[GoodTripPlus] rewind fix: 检测到整批图标丢失，已恢复 N 个房间的图标（跳过 M 个未探索房间）
```

`M` 里就包含「你刚 rewind 出来的那个房间」——它被回滚成未探索，所以不还原图标。

---

## 二、隐藏房候选标记（合并自 Lazy Delver）

功能来自 **Lazy Delver**（作者 dokee，MIT 许可，许可证原文见 `scripts/delver/LICENSE-lazy-delver.txt`），
候选位置的推演逻辑原样移植，只替换了「标记画在哪里」这一层。

按住地图键（默认 TAB）时，在小地图上标出隐藏房 / 超级隐藏房 / 究极隐藏房的**可能位置**，随探索逐步排除：

- 白色 = 普通隐藏房候选，金色 = 超级隐藏房候选，红色 = 究极隐藏房候选（持有红钥匙 / 红钥匙碎片 / 该隐的魂石时才显示）
- 明亮 = 该候选所有相邻房间都已探查；暗淡 = 还有相邻房间没去过
- 进房间后若「门 → 墙」的路径被挡（实心墙、无门）→ 排除该候选
- 炸弹在门位附近爆炸（半径约 80px）→ 排除对应的假候选
- 真隐藏房在地图上出现后，同类假候选自动清除

### 为什么原版会错位

MinimapAPI 画地图时，房间的屏幕坐标是这样算出来的：

```lua
offsetVec = (GetScreenTopRight().X - PositionX, GetScreenTopRight().Y + PositionY)
unboundedMapOffset = (-maxx, -miny)          -- 由「可见房间」的边界决定
roomOffset = (GlobalScaleX * roomPos.X, roomPos.Y) + unboundedMapOffset
RenderOffset = offsetVec + roomOffset * (17, 15) + 居中偏移
```

原版 Lazy Delver 复刻了这套公式（连大图 17×15、镜像世界的 `-9px` 都对得上），
**但它算 `maxx / miny` 用的是游戏的 `RoomDescriptor.DisplayFlags`，而 MinimapAPI 用的是它自己的
房间对象标志 `GetDisplayFlags()`**（= 自身标志 ∪ 描述符标志 ∪ 指南针加成，并受 `Hidden` /
`IgnoreDescriptorFlags` 影响）。两个集合只要在边缘房间上差一个，整张地图的锚点就平移一格
（横向 17px / 纵向 15px），所有标记一起偏移。

GoodTripPlus 的传送光标用的是 `gt:gid_to_rtmap_pos()`，它**逐项照抄 MinimapAPI 的判定**，
所以构造上必然对齐。这次的合并就是把标记也接到同一套投影上：

```lua
local pos = gt:gid_to_rtmap_pos(cid)   -- 与光标共用一套投影
```

顺带还修了第二个问题：原版在 `MC_POST_RENDER` 画标记，而 MinimapAPI 在 REPENTOGON 下是
`MC_POST_HUD_RENDER` 画地图（更晚），所以标记其实一直被地图压着——只是候选格恰好是空格子才露出来。
现在标记和光标同层（`MC_POST_HUD_RENDER`，优先级比光标早 1），画在地图之上。

**开关**：Mod Config Menu → GoodTripPlus → 「显示隐藏房候选标记」，或 `gtconfig.lua` 里
`gt.ShowSecretMarkers = false`。

**启用本功能时请禁用 Lazy Delver 本体**，否则两套标记会同时画出来。

---

## 三、传送到未探索的相邻房间（可选，默认关闭）

开关：**Mod Config Menu → GoodTripPlus → 「允许传送到未探索的相邻房间」**，
或 `gtconfig.lua` 里设 `gt.AllowUnexploredNeighbor = true`。

上游的逻辑里，传送目标必须同时满足「已探索（`VisitedCount > 0`）」和「已清理（`Clear`）」，
所以任何没进去过的房间都会被直接拦下。这个开关放宽「未探索」这一条，但**依然要求目标贴着你的探索边界**：

- 目标房间 `VisitedCount == 0`（从未进入）；
- 它上下左右四个相邻格子里，至少有一个 `VisitedCount > 0`（已探索）；
- 若「禁用未连通房间传送」开着（默认开），那个已探索邻居还必须能**从当前房间沿已探索路径抵达**。

所以它不会让你跳到地图另一头，只能扎进你已经探索到的边界外侧一格。

实现上动的是 `gt:check_teleble()` 里的准入分支，新增判定 `gt:has_reachable_explored_neighbor()`
（左右两侧按列号排除了跨行越界；直接紧邻当前房间时，路径判定自然通过）。

两点注意：

- 这类房间通常**还没清怪**，传送进去会直接落在敌群里，请自行判断风险——这正是它的用途。
- 诅咒房（进出扣血的那种）依旧受「禁止传送进诅咒房」约束，未探索的诅咒房也照样被拦下。
- 模组自带的调试模式（`gtconfig.lua` 里 `gt.DebugMod = true`）本来就能传送到任意房间，与本开关无关。

---

## 四、安装 / 与上游共存

1. 把本仓库同步到游戏 mods 目录（mod 目录名必须是 `goodtripplus`）：

   ```bash
   bash deploy.sh
   ```

2. 本模组与上游 `goodtrip_mlxtweak`（以及原版 Goodtrip）功能完全重叠，
   **同时启用会重复注册回调、出现双光标等问题**，务必只启用其中一个。
   当前 `mods/goodtrip_mlxtweak_3749565569/` 下已有 `disable.it`（即在游戏内被禁用），保持这样即可。

3. 已经合并了 Lazy Delver 的功能，**请把 `lazy_delver_3751630929` 也在游戏内禁用**。

4. 运行需要 **MinimapAPI**；可选 **Mod Config Menu**（用于游戏内设置）。

### 分享给朋友 / 分发单包

`dist/goodtripplus-1.1.0.zip` 就是可直接发人的完整包——解压丢进 `mods/` 即可。
它只含运行必需的 19 个文件，**不含 `deploy.sh`**（那是开发机上的同步脚本，里面写死了本机路径）。

朋友那边需要满足这几条：

1. **装 MinimapAPI**（必需），**建议同时装 REPENTOGON**。
   严格说 REPENTOGON 不是硬依赖：它提供的唯一东西是 `ModCallbacks.MC_POST_HUD_RENDER` 这个回调
   （定义在 `Repentogon/resources/scripts/enums_ex.lua`，原版自带的 `enums.lua` 里没有它）。
   MinimapAPI 和本模组都写了三分支回退——REPENTOGON → StageAPI → 原版 `MC_POST_RENDER`，
   所以没装 REPENTOGON 时地图与光标/标记会一起退回 `MC_POST_RENDER`，理论上功能照旧。
   但这属于「作者写了、我们没实测」的路径，**建议还是装上**（它和本模组的测试环境一致）。
   > 另外提醒：REPENTOGON 装好后 **Steam 直接启动也会注入**，不必每次都开它的启动器——
   > 安装器已经就地改过主程序（`isaac-ng.exe`）。想确认自己有没有在跑 REPENTOGON，
   > 看游戏根目录的 `Repentogon/repentogon.log`，或在游戏内输入 `gtpdiag`。
2. **Mod Config Menu 可选**，只决定能不能在游戏内改设置（没有它也能用，只是选项改不了）。
3. 解压后**文件夹名必须正好是 `goodtripplus`**——不能是 `goodtripplus (1)`、`goodtripplus-1.1.0` 之类，
   否则游戏可能找不到它（`metadata.xml` 里的 `<directory>` 写的就是这个名字）。
4. **停用 `goodtrip_mlxtweak` 和原版 `Goodtrip`**，否则两边重复注册回调、出现双光标。
5. 如果他装了 `Lazy Delver`，也让他停用，否则地图上会有两套隐藏房标记。
6. 装完**重启游戏**（Lua 不热重载）。

包里的 `LICENSE`、`THIRD_PARTY.md`、`scripts/delver/LICENSE-lazy-delver.txt` **别删**：
Lazy Delver 是 MIT 许可，要求许可证文本随副本一起分发。
**私下发给朋友没问题**；但**公开上传到创意工坊要先拿到 MLX's Tweak 作者的许可**，见第八节。

改动源码后重新打包：

```bash
bash pack.sh        # 产出 dist/goodtripplus-<版本>.zip
```

---

## 五、目录结构

```
issacMod/                       ← 工作区 git 仓库（可容纳多个 mod）
└── goodtripplus/               ← 本 mod 的源码目录（自包含，可独立打包/拆出）
    ├── main.lua                ← 入口：加载 gtrep + gtp_rewindfix + gtp_delver
    ├── metadata.xml            ← mod 元数据（name / directory / id）
    ├── gtconfig.lua            ← 静态默认值（可被 MCM 覆盖）
    ├── deploy.sh               ← 同步到游戏 mods/goodtripplus（开发机用）
    ├── pack.sh                 ← 打包成 dist/goodtripplus-<版本>.zip（分发用）
    ├── dist/                   ← 打包产物（不进版本控制）
    ├── LICENSE                 ← MIT（仅覆盖本项目自有代码）
    ├── THIRD_PARTY.md          ← 各来源的授权状况与发布路线
    ├── resources/gfx/goodtripplus/ ← 隐藏房候选标记的精灵（marker.anm2 / marker.png）
    └── scripts/
        ├── gtrep.lua           ← 上游 MLX's Tweak 主逻辑（仅改名重写 + 准入判定扩展）
        ├── gtp_rewindfix.lua   ← rewind 掉落物图标修复（不依赖具体回调的帧末监视）
        ├── gtp_delver.lua      ← 隐藏房候选标记的回调接线 + MCM 开关
        └── delver/             ← 移植自 Lazy Delver（MIT），仅改了 require 路径
            ├── const.lua       ← 常量表
            ├── geometry.lua    ← 形状占据格、相邻格、门槽映射
            ├── log.lua         ← 原版调试日志（默认静默）
            ├── state.lua       ← 楼层 / 维度 / 道具持有状态
            ├── map.lua         ← 房间表、候选推演、真假候选判定
            ├── room.lua        ← 门位检查、炸弹排除
            ├── render.lua      ← **已改写**：坐标改用 gt:gid_to_rtmap_pos()
            └── LICENSE-lazy-delver.txt
```

`deploy.sh` 用脚本自身所在目录当源码根，所以在仓库根跑 `bash goodtripplus/deploy.sh`
或在 `goodtripplus/` 里跑 `bash deploy.sh` 都可以；仓库根还提供 `deploy-all.sh` 一次同步全部 mod。

对应游戏内路径：`F:/Steam/steamapps/common/The Binding of Isaac Rebirth/mods/goodtripplus`

---

## 六、与上游 / 来源的差异清单

| 位置 | 改动 |
| --- | --- |
| `scripts/gtrep.lua` | `RegisterMod` 名、ModConfigMenu 配置键 / 标题全部改为 `GoodTripPlus`；新增 MCM 开关 `ShowSecretMarkers`、`AllowUnexploredNeighbor`，并放宽 `check_teleble()` 的准入判定；其余逻辑与 MLX's Tweak 完全一致 |
| `scripts/gtp_rewindfix.lua` | 新增文件，rewind 图标修复 |
| `scripts/gtp_delver.lua` | 新增文件，隐藏房候选标记的回调接线 |
| `scripts/delver/*` | 从 Lazy Delver 原样移植（仅改写 `require` 路径），`render.lua` 重写了定位部分 |
| `resources/gfx/goodtripplus/*` | 从 Lazy Delver 复制标记精灵，换到自己的路径避免与它本体冲突 |
| `main.lua` / `metadata.xml` / `gtconfig.lua` / `deploy.sh` | 新增 / 重写 |

---

## 七、开发流程

```bash
# 改完源码后
bash deploy.sh          # 同步到游戏目录
# 重启游戏（Lua 不会热重载）

git add -A && git commit -m "..."
```

调试时可在 `gtconfig.lua` 里打开 `gt.DebugMod = true`，修复模块会往控制台 / log.txt 输出命中信息。

---

## 八、授权与发布

本仓库的内容来自三个来源，授权状况**互不相同**，详见 [`LICENSE`](LICENSE) 与 [`THIRD_PARTY.md`](THIRD_PARTY.md)。

| 来源 | 授权 | 状态 |
| --- | --- | --- |
| 本项目自有代码（rewind 修复、隐藏房标记对接、构建脚本） | MIT | ✅ |
| Lazy Delver（`scripts/delver/*`、`resources/gfx/goodtripplus/marker.*`，作者 dokee） | MIT | ✅ 已随包携带其许可证 |
| **Goodtrip MLX's Tweak**（`scripts/gtrep.lua` 的基底）+ 其上游 **tarako 的 GoodTrip** | **无许可证文件 = 保留所有权利** | ⚠️ **未获授权** |
| MinimapAPI | 仅运行时依赖，本仓库不含其任何代码/素材 | ✅ 无需许可 |

**所以：在取得上游作者许可之前，不要把包含 `scripts/gtrep.lua` 的完整包公开上传**（包括 Steam 创意工坊）。
两条可行路线（只发布自有模块作为附加组件 / 先取得许可）与发布检查清单写在 `THIRD_PARTY.md` 里。
