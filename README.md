# GoodTripPlus

《以撒的结合：忏悔+》的小地图传送模组，基于 **Goodtrip MLX's Tweak**（Steam 创意工坊 3749565569）二次开发。

与上游相比**只做了一处修改**：修复了使用控制台 `rewind` 指令后，小地图上所有掉落物图标全部消失的问题。

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
4. 关卡重建发生在 update 阶段，而 `MC_POST_UPDATE` 在 update 末尾、渲染之前执行，
   所以还原发生在这一帧被画出来之前，不会出现闪烁。

可以在 **Mod Config Menu → GoodTripPlus → 修复 rewind 后掉落物图标消失** 里开关；
也可以在 `gtconfig.lua` 里设置 `gt.FixRewindPickupIcons = false`。

### 自查手段

游戏内控制台输入 `gtpdiag`，会打印层身份、修复开关、累计命中次数、各维度房间数与带图标房间数，
以及最近 16 条事件（`POST_NEW_LEVEL` / `POST_NEW_ROOM` / `POST_GAME_STARTED` 的触发、
每次判定为清空时的 `rebuilt/lost/sameFloor` 与前后层身份、恢复了多少个房间）。

命中修复时控制台会直接打印：

```
[GoodTripPlus] rewind fix: 检测到整批图标丢失，已恢复 N 个房间的图标
```

---

## 二、安装 / 与上游共存

1. 把本仓库同步到游戏 mods 目录（mod 目录名必须是 `goodtripplus`）：

   ```bash
   bash deploy.sh
   ```

2. 本模组与上游 `goodtrip_mlxtweak`（以及原版 Goodtrip）功能完全重叠，
   **同时启用会重复注册回调、出现双光标等问题**，务必只启用其中一个。
   当前 `mods/goodtrip_mlxtweak_3749565569/` 下已有 `disable.it`（即在游戏内被禁用），保持这样即可。

3. 运行需要 **MinimapAPI**；可选 **Mod Config Menu**（用于游戏内设置）。

---

## 三、目录结构

```
issacMod/                     ← 本 git 仓库（源码唯一来源）
├── main.lua                  ← 入口：加载 gtrep + gtp_rewindfix
├── metadata.xml              ← mod 元数据（name / directory / id）
├── gtconfig.lua              ← 静态默认值（可被 MCM 覆盖）
├── deploy.sh                 ← 同步到游戏 mods/goodtripplus
└── scripts/
    ├── gtrep.lua             ← 上游 MLX's Tweak 主逻辑（仅改名重写）
    └── gtp_rewindfix.lua     ← 本次新增：rewind 掉落物图标修复
```

对应游戏内路径：`F:/Steam/steamapps/common/The Binding of Isaac Rebirth/mods/goodtripplus`

---

## 四、与上游的差异清单

| 位置 | 改动 |
| --- | --- |
| `scripts/gtrep.lua` | `RegisterMod` 名、ModConfigMenu 配置键 / 标题全部改为 `GoodTripPlus`；新增一个 MCM 开关 `FixRewindPickupIcons`；其余逻辑与 MLX's Tweak 完全一致 |
| `scripts/gtp_rewindfix.lua` | 新增文件，实现上述修复 |
| `main.lua` / `metadata.xml` / `gtconfig.lua` | 新增 / 重写 |

---

## 五、开发流程

```bash
# 改完源码后
bash deploy.sh          # 同步到游戏目录
# 重启游戏（Lua 不会热重载）

git add -A && git commit -m "..."
```

调试时可在 `gtconfig.lua` 里打开 `gt.DebugMod = true`，修复模块会往控制台 / log.txt 输出命中信息。
