# GoodTripPlus

《以撒的结合：忏悔+》的小地图传送模组，基于 **Goodtrip MLX's Tweak**（Steam 创意工坊 3749565569）二次开发。

> **项目定位（2026-10-03 起）**：**MinimapAPI 的外置传送插件**。
> MinimapAPI 已经把地图显示、缩放、图标、战斗隐藏等地图能力做得很好，
> 本模组不再追求「全家桶」，只在其基础上搭建 GoodTrip 的传送玩法
> （传送光标、传送准入、传送相关开关与修复），运行必需 MinimapAPI。

与上游相比主要有以下改动：

1. **修复**了使用控制台 `rewind` 指令后，小地图上所有掉落物图标全部消失的问题（见第一节）。
2. （已移除）大地图黑边修复：遇黑边请直接关 MinimapAPI 菜单里的 "Show Room Outlines"（见第二节）。
3. **合并**了 Lazy Delver 的隐藏房候选标记，并把标记对齐到 MinimapAPI 的真实布局（见第三节）。
4. **准入与传送判定整体移植**自 GoodTrip [Fixed]（选项同名同默认值，见第四节）。
5. **新增**了深牢 II 愚者骷髅房的标记，默认开启（见第五节）。
6. **战斗时地图隐藏**：跟随 MinimapAPI 自带的 "Hide Map in Combat"，让本模组自绘的标记一起隐藏（见第六节）。
7. **新增**了「房间里出现奖励房间的门（恶魔房 / 天使房 / Boss Rush / 死寂）时禁止传送」，**常开**（见第四节末尾）。
8. **新增**了「地图边界房间高亮」：按住地图键时画出贴着 13×13 边界的房间外沿，默认开启（见第六节）。
9. **（v1.8.2）合并**了传送范围的设置：把 Fixed 的 `AllowNeighborRoom` + `AllowAnyRoom` 两项
   合成一个三选一 `TravelMode`，MCM 里显示为「可以传送到」——「任意房间 / 相邻房间 / 已探索房间」，
   默认「相邻房间」（行为等价于原来的默认组合），见第四节。

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

> **诊断输出怎么看（2026-10-03 实测）**：
> - **主力入口：按住地图键 + F4**（两种环境都可用）→ 判定直接画在**屏幕左上角**
>   （15 秒后自动消失），同时写进 `log.txt`。（光标没启用时用当前房间作为目标；连按限流 20 帧）
> - 把 `gtconfig.lua` 里 `gt.DebugMod` 改成 `true`：按住地图键瞄一下隐藏房再松手，
>   会自动弹出同一份浮层，连按键都不用。**（默认关闭：不改这个开关时，正式游玩不会
>   往 `log.txt` 写任何诊断行）**
> - **控制台命令**（`gtpdiag [格子编号]`、`gtpd`）只在「用 REPENTOGON 启动器启动」时可用：
>   实测不用它启动时，控制台是原版 Rep+ 的「Repentance+ Console」，**不把自定义命令
>   派发给 mod**（我们的命令、别人的 `mapitel` 都零反应）。用 rgon 启动器时派发正常。
> - ⚠️ **`MC_EXECUTE_CMD` 的回调不要返回字符串**：返回值会被引擎逐行打印到控制台，
>   而本机环境下**返回多行字符串会当场闪退**（2026-10-03 实测：我们的输出打印完立刻
>   `Lua stack trace:`（空栈）→ `Caught exception, writing minidump...`；同环境里
>   MinimapAPI 的 `mapitel` 返回 nil 就正常）。所以本 mod 所有 `gtpdiag` 回调一律
>   `return nil`，输出只走 `Isaac.ConsoleOutput`（逐行直写）与 `Isaac.DebugString`（落 log）；
>   浮层延到下一帧渲染阶段再弹，避免在命令处理阶段碰字体资源。
> - 命令签名是 `(Mod, command, args)`——参数在第三个参数里，不是塞在 `command` 里；
>   大小写、前后空格、整行都做了容错。
> - 启动打两行：`[GoodTripPlus] vX.Y.Z loaded (console command: gtpdiag)` 与
>   `[GoodTripPlus] ready: repentogon=<是否在跑> postHudRender=<有没有> render=<走的哪条回调>`
>   —— 确认「改完重启了没、哪一版、在哪个环境」看这两行。
> - 诊断回调统统包了 `pcall`：Lua 侧出错只打一行 ERROR，不会把游戏带崩。

命中修复时控制台会直接打印：

```
[GoodTripPlus] rewind fix: 检测到整批图标丢失，已恢复 N 个房间的图标（跳过 M 个未探索房间）
```

`M` 里就包含「你刚 rewind 出来的那个房间」——它被回滚成未探索，所以不还原图标。

---

### 迷失诅咒下仍然显示隐藏房候选（v1.7.1 修复）

**现象**：先看过完整地图（隐藏房候选已经算出来），之后因为药丸 / 道具突然被赋予迷失诅咒时，
长按 TAB 仍会画出候选标记；换一次房间之后才正常消失。

**根因**：本功能移植自 Lazy Delver，上游把「本层是否迷失诅咒」缓存成 `lost_cursed`，
只在 `M.check()` 跑到末尾时才更新，而 `state.check()` 只挂在 `MC_POST_NEW_ROOM`（换房间）上
（`gtp_delver.lua`）。吃药丸不换房，缓存就一直停在 `false`。诅咒是**运行中可以变化**的状态，
按「换房间」为节奏缓存本身就选错了时机。

**修法**：在 `gtp_delver.lua` 里把 `state.is_lost_cursed` 覆盖为**实时读取**
（`level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST`）—— 只覆盖这一个访问器，
不动上游移植文件 `delver/state.lua`；`GetCurses()` 每帧查一次的开销可忽略。

## 二、大地图四周的黑边（修复已移除）

2026-10-03 项目定位收缩为「MinimapAPI 的外置传送插件」时，`scripts/gtp_mapoutline.lua`
已随包移除——地图显示问题应回到 MinimapAPI 侧解决。

黑边本身是 MinimapAPI 的房间轮廓（`RoomOutline`）在大地图渐显到不透明度 1 时突然开画所致。
如果还遇到它，两个现成的绕法：

- 关掉 MinimapAPI 菜单里的 **"Show Room Outlines"**（MCM → Minimap API → Map(1)）；
- 或保持大地图**常驻**（点按地图键）而不是按住，透明度不到 1 时轮廓不画。

技术细节存档：门槛在 `MinimapAPI:renderRoomShadows()` 开头的
`GetTransparency() == 1` 判断；修法可参考当年做法——包装该函数、`IsLarge()` 时跳过。

---

## 三、隐藏房候选标记（合并自 Lazy Delver）

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

## 四、传送准入与传送判定（2026-10-03 起整体移植自 GoodTrip [Fixed]）

本节原为「传送到未探索的相邻房间」（`AllowUnexploredNeighbor`）的说明。
2026-10-03 按项目定位变更，**准入与传送判定整体忠实移植自 GoodTrip [Fixed]**
（其 `rules.lua` 全部 + `floor.lua` 门图/邻接基础设施 + `trip.lua` 传送与诅咒过路费），
选项与 Fixed 同名同默认值（**例外**：`AllowNeighborRoom` + `AllowAnyRoom` 已在 v1.8.2
合并为一个三选一设置 `TravelMode`，MCM 里显示为「可以传送到」，默认「相邻房间」＝原默认组合；
`FastTransition` 默认改为开）：

| 选项 | 默认 | 作用 |
| --- | --- | --- |
| `FollowCurseOfLost` | 开 | 迷失诅咒下禁用传送 |
| `TravelMode`（MCM 显示「可以传送到」） | 相邻房间 | v1.8.2 由 Fixed 的 `AllowNeighborRoom` + `AllowAnyRoom` **合并**而成的三选一：**任意房间**＝所有已显示房间全部放行（＝原 `AllowAnyRoom` 开）；**相邻房间**＝已清且可达房间旁「已显示但未清/未探索」的房间放行（＝原默认组合；普通房/boss/小 boss/献祭房除外；红钥匙房、一层与水层镜像的商店/宝箱房豁免；虚空 Delirium boss 房角落特判）；**已探索房间**＝只认自己已清怪的房（＝原 `AllowNeighborRoom` 关） |
| `FairTripPath` | 开 | 目标必须沿「已探索+已清怪」的房间逐真门抵达（门图 BFS） |
| `ArriveAtDoor` | 关 | 落地在走路会走进来的门口（跨屏大房间远途会先经过前一格） |
| `FairTripTime` | 关 | 按传送距离与移速补回游戏时间 |
| `FastTransition` | 开 | 跳过传送动画（偏离 Fixed 的默认关；不进 MCM 菜单，仅 gtconfig.lua 可覆盖） |
| `HighlightCursorRoom` | 开 | 高亮光标下可传送的房间（不进 MCM 菜单，仅 gtconfig.lua 可覆盖） |
| —（常开，无开关） | 常开 | **本项目新增（非 Fixed 项）**：**判据＝当前房间里有没有道具生成的入口实体** —— 牌意解读（660）的传送门 = `EntityEffect` + `EffectVariant.PORTAL_TELEPORT`(161)、天堂阶梯（586）的台阶 = `EntityEffect` + `EffectVariant.TALL_LADDER`(156)。持有这两个道具之一、且房间里还有这枚入口时**禁止传送**（两者都是"一离开房间就销毁"，禁传送避免误触顶掉）；入口消失（即离开过）立刻恢复。不依赖任何"初始房间 / 本层离开过没有"的状态，所以回溯线等特殊路线也不会误禁。`gt.DebugMod` 调试模式仍可绕过 |

**道具入口禁传的判据（2026-10-03，回溯线实测后重做）**：早期版本靠
`Level:GetStartingRoomIndex()` + 房间类型去猜"初始房间"，但**回溯线（The Ascent）里这个索引
指向的是玩家进门的那间 boss 房**，会在 boss 房把传送误禁（用户实测）。现在直接看**房间里有没有
道具生成的入口实体**：牌意解读（660）的传送门 = `EntityEffect` + `EffectVariant.PORTAL_TELEPORT`
(161)，天堂阶梯（586）的台阶 = `EntityEffect` + `EffectVariant.TALL_LADDER`(156)。这两个入口
"一离开房间就随房间销毁"，所以**实体在＝别动它**；门没了禁令自动解除，**不需要任何层/房间状态**。
回溯线也自然正确 —— Wiki 写明那里的门生成在"通往下一层的那个起始房间"，不是进门那间 boss 房。

旧的 `AllowUnexploredNeighbor` / `RequireExploredPath` / `BlockCurseRoom` 三个开关已移除：
未探索场景并入 `TravelMode` 的「相邻房间」放宽逻辑；路径判定即 `FairTripPath`；
诅咒房不再禁止传送，改为进门扣血（`curse_toll_free`：Flat File / 深渊书免伤，
以撒的心脏 / 牙与甲照扣，尖刺状态从门两侧分别记录）。

**对 Fixed 的两处偏离**（都为了修实际 bug，理由都写在代码注释里）：
1. `check_neigh_connected()` 的类型白名单放进隐藏房 → 已炸开的隐藏房可以传送进入（见第 2 节）；
2. **回溯线放行「Mom / Ultra Greed 房一律禁传」这条规则**（`gt:teleport_to_grid_index()` 开头）：
   回溯线里 **Depths II 那层的 boss 房名字就是 `Mom`**，但那里 boss 早在正着走时打完、只是路过，
   于是正常传送被拦 —— 现象是"光标能呼出、能选格子，松手只响一声失败音"。
   现在 `not level:IsAscent()` 时该规则才生效；正常路线的 Mom / Ultra Greed 房照旧禁。
   诊断 dump 新增 `tripPrecheck` 行，会直接点名这条与"Mother's Shadow(867) 在场"这条静态失败规则。

核心机制（门图）：网格相邻分不清「门洞」和「隐藏房没炸开的墙」，所以按维度维护
一张逐房间学出来的门图（`sweep_doors` 只读当前房的门、跳过 `DOOR_HIDDEN`、双向记录，
换层清空），BFS 寻路与相邻放宽的最后一跳都要求**真实门**。

### 房间里出现「奖励房间的门」时禁用传送（常开）

打完 boss 后，游戏可能给 boss 房开出一扇通往**奖励房间**的门（恶魔房 / 天使房 / Boss Rush / 死寂）。
此时误触传送出房可能把它错过，所以：**当前房间里存在这类门时，传送整体禁用**；没有这样的门就
完全不拦 —— 正常打完 boss、没开出奖励门的房间照常可以传送。门还在房间里就一直拦，
因为奖励确实还摆在那儿。

- 判据读**门自己的目标房间**（遍历 `DoorSlot.NUM_DOOR_SLOTS` 个门槽，任一命中即拦）：
  `door.TargetRoomType == RoomType.ROOM_DEVIL`(14) / `ROOM_ANGEL`(15) / `ROOM_BOSSRUSH`(17)，
  或 `door.TargetRoomIndex == GridRooms.ROOM_BOSSRUSH_IDX`(-5) / `ROOM_BLUE_WOOM_IDX`(-8，死寂/Hush)。
  **注意 `DoorVariant` 里没有这些门型**（只有 0~8 九个普通值），所以必须看门的目标房间。
- **回溯线（The Ascent）不参与** —— 那里进门的就是 boss 房、只是路过，没有奖励门。
- 实现是独立模块 `scripts/gtp_bosswindow.lua`，**包一层 `gt.check_teleble()`**（不改 `gtrep.lua`），
  所以表现与其它准入拒绝完全一致：光标不高亮、按 TAB 不启用、松手也不会传。
- **常开、无开关**（用户 2026-10-03 要求：这类保护不给可选配置）；只有 `gt.DebugMod` 调试模式能绕过。

## 五、深牢 II 的愚者骷髅房标记（默认开启）

**背景**：深牢 II（Depths II）里有一个特殊的骷髅障碍物，炸掉后**固定掉落愚者卡牌**（The Fool）。
开启后，小地图会在它所在的房间上画一个卡牌图标，方便回头再找。

开关：**MCM → GoodTripPlus → 「标记深牢 II 的愚者骷髅房」**，或 `gtconfig.lua` 里 `gt.FoolsSkullRoom = false`。

### 怎么识别的（依据全在游戏自己的数据里，不是猜的）

| 依据 | 内容 |
| --- | --- |
| 游戏自带 `resources/scripts/enums.lua` 第 497 行 | `GRID_ROCK_ALT2 = 26, -- special skull in Depths 2` —— 注释直接写明「深牢 II 的特殊骷髅」 |
| REPENTOGON 的 `enums_ex.lua` 第 1625 行 | `StbGridType` 里 `ALT_ROCK_MARKED = 1008, MARKED_SKULL = 1008` —— 房间布局（`.stb`）里这个骷髅的类型 ID |
| 层判定 | `Level:GetStage() == LevelStage.STAGE3_2`（= 6），即深牢 II（含 Necropolis II / Dank Depths II 同类层） |

识别方式是读房间的**生成表**（`RoomDescriptor.Data.Spawns`）里有没有 Type == 1008 的条目，
而不是进房扫实体。理由：

- 骷髅可能在玩家进房前就被炸掉，扫实体拿不到；生成表是布局自带的，永远在；
- 生成表在地图被重建后仍能重新读取，**rewind 之后不会丢**（不需要维护快照）。

### 标记怎么画上去的

复用 MinimapAPI 自己的房间图标系统：它的房间对象有 `PermanentIcons` / `VisitedIcons` 两个图标名数组，
渲染 `VisitedIcons` 时**只在房间已探索时**才画（它标镜子房 / 矿车房用的就是这个机制）。
本模块在启动时用 `MinimapAPI:AddIcon` 注册一个**自己的图标** `TintedSkull`
（素材 `resources/gfx/goodtripplus/TintedSkull.png`，16x16，随本模组分发），再把它塞进对应房间的 `VisitedIcons`。

这样做的好处：坐标 / 缩放 / 大小图切换 / 地图滑动全由 MinimapAPI 自己算，天然对齐；
**「没进去过的房间不显示」这条防剧透规则也是 MinimapAPI 执行的**，不需要重写。

两个实现注意点：

- 图标尺寸必须与 MinimapAPI 的图标一致（**16x16、pivot 0,0**），否则它的图标位置计算会错位。
- 万一 `AddIcon` 不存在（MinimapAPI 版本太老）或精灵加载失败，会退回它自带的 `Card` 卡牌图标，
  功能不至于整个失效；`gtpdiag` 的 `skullRoom.icon=` 会显示当前实际用的是哪个。

因为 MinimapAPI 会在换层、rewind 等时机整表重建房间对象（重建后我们塞的图标会没），
本模块在每帧的 `MC_POST_UPDATE` 里**确保**一次：命中集合为空时直接返回，
只在深牢 II 才扫描生成表（每层一次，缓存在层身份上），开销可忽略。

### 自查手段

控制台输入 `gtpdiag`，会多出这几行：

```
skullRoom.enabled=true stage=6
skullRoom.scans=1 foundRooms=1 applied=1
skullRoom.lastResult=已标记房间 42（累计 1 次）
skullRoom.icon=TintedSkull (custom)
skullRoom.rooms={42}
```

`foundRooms=0` 说明本层生成表里没找到该骷髅（正常——不是每层都有）；
`rooms={...}` 是识别到的网格索引列表；`icon=` 后面 `(custom)` 表示用的是自绘骷髅图标。

---

## 六、地图边界房间高亮（默认开启）

以撒的地图上限是 13×13（初始房为中心，上下左右各 6 格）。按住地图键时，把**贴着地图
边界**的房间、**靠边的那条边**画出来（角房画两条），一眼就能看出「这一侧外面已经没有
房间了」—— 找隐藏房、决定往哪探索都用得上。

- **边界判定**：格号换 `col = gid % 13`、`row = floor(gid / 13)`，等于 0 或 12 即贴边
  （起始房正好是 `col=6 / row=6`）。
- **大房间占多格**：用 `delver/geometry.lua` 的 `SHAPE_OFFSETS` 取它占据的所有格逐格判断，
  最靠外的那格自然会被画到。
- **只画已探索的房间**（`RoomDescriptor.DisplayFlags & 1`），不会剧透还没探索的区域。
- **坐标**用 `gt:gid_to_rtmap_pos()` —— 与传送光标、隐藏房标记同一套投影，天然对齐。
- **画线**：Isaac 的 Lua **没有画矩形的 API**（本机所有 mod 都靠 Sprite），所以用 8×8 纯白
  贴图 `resources/gfx/goodtripplus/bounds.png`（配 `bounds.anm2`）按需要的宽高缩放绘制，
  颜色 / 透明度由 `sprite.Color` 控制。
- **显示时机 / 显示条件与隐藏房候选标记完全一致**：淡入直接读 `delver/render.lua` 的
  **同一份**帧计数（`get_fade()`，按住地图键才 > 0，返回 0~1 的系数；**松开地图键立即消失、
  不做淡出**），显示条件也逐条对齐 ——
  层被忽略（回溯线 / STAGE8 / 贪婪模式 / 镜像外维度）、**迷失诅咒**、房间不在网格上、
  MinimapAPI 战斗隐藏，任一命中都不画。只有开关是各自独立的。
- 为此 `gtp_delver.lua` 里那个「按住地图键」的计数**不再受隐藏房标记开关影响**（否则
  关掉标记会让边界高亮一起停摆），`delver/render.lua` 另外暴露了 `get_fade()` 与
  `minimapapi_hides_map` 供本模组其它模块复用。

开关：**MCM → GoodTripPlus → 「显示地图边界」**，或 `gtconfig.lua` 里
`gt.ShowMapBounds = false`（默认开启）。


## 七、战斗时地图隐藏（交给 MinimapAPI）

战斗时地图要不要隐藏，**由 MinimapAPI 自带的 "Hide Map in Combat" 决定**
（MCM → Minimap API，`1 = Never` / `2 = Bosses Only` / `3 = Always`，默认 1）。

MinimapAPI 的实现是在渲染回调**开头直接 `return`**——条件命中时整块地图
（含按住 TAB 的大地图）都不画：Mega Satan 战与 Beast 战无条件隐藏，
boss 开场过场隐藏，`2` 档在未清理的 boss 房、`3` 档在任意未清理房间隐藏。

### 本模组的自绘元素如何跟随

MinimapAPI 藏地图时管不到**本模组自己画的**元素。各元素的情况：

| 自绘元素 | 战斗中的行为 |
| --- | --- |
| 传送光标 / 光标房间高亮 | 无需处理——光标只在当前房已清理时激活，战斗中本就不绘制 |
| 隐藏房候选标记（Lazy Delver） | **需要跟随**：`delver/render.lua` 的 `minimapapi_hides_map()` 逐条镜像 MinimapAPI 的隐藏条件（含 Mega Satan/Beast 战、boss 开场过场、StageAPI 层间过场），命中任一条件时不画标记 |
| 骷髅房图标 | MinimapAPI 自己的房间图标，随地图一起消失，无需处理 |

历史上曾有一个专门的 `gtp_combatmap.lua` 负责这类跟随（2026-10-03 移除）：
它当时跟随的是初始房高亮，该高亮删除后模块一度整个撤去；
后来发现隐藏房候选标记同样需要跟随，就把镜像逻辑内联进了 `delver/render.lua`。

---

## 八、安装 / 与上游共存

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

改动源码后重新打包：

```bash
bash pack.sh        # 产出 dist/goodtripplus-<版本>.zip
```

---

## 九、目录结构

```
issacMod/                       ← 工作区 git 仓库（可容纳多个 mod）
└── goodtripplus/               ← 本 mod 的源码目录（自包含，可独立打包/拆出）
    ├── main.lua                ← 入口：加载 gtrep + gtp_rewindfix + gtp_delver + gtp_skullroom
    ├── metadata.xml            ← mod 元数据（name / directory / id）
    ├── gtconfig.lua            ← 静态默认值（可被 MCM 覆盖）
    ├── deploy.sh               ← 同步到游戏 mods/goodtripplus（开发机用）
    ├── pack.sh                 ← 打包成 dist/goodtripplus-<版本>.zip（分发用）
    ├── dist/                   ← 打包产物（不进版本控制）
    ├── LICENSE                 ← MIT（仅覆盖本项目自有代码）
    ├── THIRD_PARTY.md          ← 各来源的授权状况与发布路线
    ├── resources/gfx/goodtripplus/ ← 标记精灵：marker.*（隐藏房候选，来自 Lazy Delver）
    │                                 TintedSkull.*（愚者骷髅房图标，本模组自有素材）
    └── scripts/
        ├── gtrep.lua           ← 上游 MLX's Tweak 主逻辑（仅改名重写 + 准入判定扩展）
        ├── gtp_rewindfix.lua   ← rewind 掉落物图标修复（不依赖具体回调的帧末监视）
        ├── gtp_delver.lua      ← 隐藏房候选标记的回调接线 + MCM 开关
        ├── gtp_skullroom.lua   ← 深牢 II 愚者骷髅房标记（读房间生成表 → MinimapAPI 房间图标）
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

## 十、与上游 / 来源的差异清单

| 位置 | 改动 |
| --- | --- |
| `scripts/gtrep.lua` | `RegisterMod` 名、ModConfigMenu 配置键 / 标题全部改为 `GoodTripPlus`；新增 MCM 开关 `ShowSecretMarkers`、`FoolsSkullRoom`；传送准入与传送判定整体移植自 GoodTrip [Fixed]（选项同名同默认值，见第四节） |
| `scripts/gtp_rewindfix.lua` | 新增文件，rewind 图标修复 |
| `scripts/gtp_delver.lua` | 新增文件，隐藏房候选标记的回调接线 |
| `scripts/gtp_skullroom.lua` | 新增文件，深牢 II 愚者骷髅房标记（自己写的，未参考任何 mod 的实现代码） |
| `scripts/gtp_bosswindow.lua` | 新增文件，房间里出现「奖励房间的门」（恶魔房 / 天使房 / Boss Rush / 死寂）时禁用传送，常开（**包装 `gt.check_teleble`** 实现，不改 `gtrep.lua`） |
| `scripts/gtp_mapbounds.lua` | 新增文件，地图边界房间高亮（默认开；用一张 8×8 纯白贴图缩放画边） |
| `scripts/delver/*` | 从 Lazy Delver 原样移植（仅改写 `require` 路径），`render.lua` 重写了定位部分 |
| `resources/gfx/goodtripplus/*` | `marker.*` 从 Lazy Delver 复制（换到自己的路径避免与它本体冲突）；`TintedSkull.*` 是本模组自有的骷髅图标（16x16）；`bounds.*` 是本模组自有的纯白贴图（8×8，画地图边界线用） |
| `main.lua` / `metadata.xml` / `gtconfig.lua` / `deploy.sh` | 新增 / 重写 |

---

## 十一、开发流程

```bash
# 改完源码后
bash deploy.sh          # 同步到游戏目录
# 重启游戏（Lua 不会热重载）

git add -A && git commit -m "..."
```

调试时可在 `gtconfig.lua` 里打开 `gt.DebugMod = true`，修复模块会往控制台 / log.txt 输出命中信息。

---

## 十二、授权与发布

本仓库的内容来自三个来源，授权状况**互不相同**，详见 [`LICENSE`](LICENSE) 与 [`THIRD_PARTY.md`](THIRD_PARTY.md)。

| 来源 | 授权 | 状态 |
| --- | --- | --- |
| 本项目自有代码（rewind 修复、隐藏房标记对接、构建脚本） | MIT | ✅ |
| Lazy Delver（`scripts/delver/*`、`resources/gfx/goodtripplus/marker.*`，作者 dokee） | MIT | ✅ 已随包携带其许可证 |
| **Goodtrip MLX's Tweak**（`scripts/gtrep.lua` 的基底）+ 其上游 **tarako 的 GoodTrip** | **无许可证文件 = 保留所有权利** | ⚠️ **未获授权** |
| MinimapAPI | 仅运行时依赖，本仓库不含其任何代码/素材 | ✅ 无需许可 |

---

如果本项目的分发方式需要调整，或作为相关内容权利人的您希望修改署名 / 撤下部分或全部内容，
欢迎通过 [GitHub Issues](https://github.com/Jamlet-T/GoodTripPlus/issues) 联系我，我会尽快处理。
