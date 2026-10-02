# GoodTripPlus

《以撒的结合：忏悔+》的小地图传送模组，基于 **Goodtrip MLX's Tweak**（Steam 创意工坊 3749565569）二次开发。

与上游相比只做两处改动：

1. **修复**了使用控制台 `rewind` 指令后，小地图上所有掉落物图标全部消失的问题（见第一节）。
2. **合并**了 Lazy Delver 的隐藏房候选标记，并把标记对齐到 MinimapAPI 的真实布局（见第二节）。

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

## 三、安装 / 与上游共存

1. 把本仓库同步到游戏 mods 目录（mod 目录名必须是 `goodtripplus`）：

   ```bash
   bash deploy.sh
   ```

2. 本模组与上游 `goodtrip_mlxtweak`（以及原版 Goodtrip）功能完全重叠，
   **同时启用会重复注册回调、出现双光标等问题**，务必只启用其中一个。
   当前 `mods/goodtrip_mlxtweak_3749565569/` 下已有 `disable.it`（即在游戏内被禁用），保持这样即可。

3. 已经合并了 Lazy Delver 的功能，**请把 `lazy_delver_3751630929` 也在游戏内禁用**。

4. 运行需要 **MinimapAPI**；可选 **Mod Config Menu**（用于游戏内设置）。

---

## 四、目录结构

```
issacMod/                       ← 本 git 仓库（源码唯一来源）
├── main.lua                    ← 入口：加载 gtrep + gtp_rewindfix + gtp_delver
├── metadata.xml                ← mod 元数据（name / directory / id）
├── gtconfig.lua                ← 静态默认值（可被 MCM 覆盖）
├── deploy.sh                   ← 同步到游戏 mods/goodtripplus
├── resources/gfx/goodtripplus/ ← 隐藏房候选标记的精灵（marker.anm2 / marker.png）
└── scripts/
    ├── gtrep.lua               ← 上游 MLX's Tweak 主逻辑（仅改名重写）
    ├── gtp_rewindfix.lua       ← rewind 掉落物图标修复（不依赖具体回调的帧末监视）
    ├── gtp_delver.lua          ← 隐藏房候选标记的回调接线 + MCM 开关
    └── delver/                 ← 移植自 Lazy Delver（MIT），仅改了 require 路径
        ├── const.lua           ← 常量表
        ├── geometry.lua        ← 形状占据格、相邻格、门槽映射
        ├── log.lua             ← 原版调试日志（默认静默）
        ├── state.lua           ← 楼层 / 维度 / 道具持有状态
        ├── map.lua             ← 房间表、候选推演、真假候选判定
        ├── room.lua            ← 门位检查、炸弹排除
        ├── render.lua          ← **已改写**：坐标改用 gt:gid_to_rtmap_pos()
        └── LICENSE-lazy-delver.txt
```

对应游戏内路径：`F:/Steam/steamapps/common/The Binding of Isaac Rebirth/mods/goodtripplus`

---

## 五、与上游 / 来源的差异清单

| 位置 | 改动 |
| --- | --- |
| `scripts/gtrep.lua` | `RegisterMod` 名、ModConfigMenu 配置键 / 标题全部改为 `GoodTripPlus`；新增 MCM 开关 `ShowSecretMarkers`；其余逻辑与 MLX's Tweak 完全一致 |
| `scripts/gtp_rewindfix.lua` | 新增文件，rewind 图标修复 |
| `scripts/gtp_delver.lua` | 新增文件，隐藏房候选标记的回调接线 |
| `scripts/delver/*` | 从 Lazy Delver 原样移植（仅改写 `require` 路径），`render.lua` 重写了定位部分 |
| `resources/gfx/goodtripplus/*` | 从 Lazy Delver 复制标记精灵，换到自己的路径避免与它本体冲突 |
| `main.lua` / `metadata.xml` / `gtconfig.lua` / `deploy.sh` | 新增 / 重写 |

---

## 六、开发流程

```bash
# 改完源码后
bash deploy.sh          # 同步到游戏目录
# 重启游戏（Lua 不会热重载）

git add -A && git commit -m "..."
```

调试时可在 `gtconfig.lua` 里打开 `gt.DebugMod = true`，修复模块会往控制台 / log.txt 输出命中信息。
