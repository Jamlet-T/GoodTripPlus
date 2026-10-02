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

`rewind` 本质上是一次**关卡状态回滚**（和发光沙漏同一套机制），它会让关卡被重建，
于是 `MC_POST_NEW_LEVEL` 被触发。而 MinimapAPI 在 `MC_POST_NEW_LEVEL` 里的处理是：

```lua
-- minimapi/scripts/minimapapi/main.lua
MinimapAPI:AddCallbackFunc(ModCallbacks.MC_POST_NEW_LEVEL, CALLBACK_PRIORITY, function(_)
    MinimapAPI:ClearLevels()      -- 丢掉所有房间对象
    MinimapAPI:LoadDefaultMap()   -- 按 RoomDescriptor 重建，ItemIcons = {}
    ...
end)
```

所有房间对象被丢弃重建，新对象一律 `ItemIcons = {}`。而图标只在「玩家待在房间里」时才会产生，
所以回滚之后整张地图的掉落物图标都是空的，只能一个个重新进房间刷出来——与现象完全吻合。

（发光沙漏为什么没这个问题：MinimapAPI 为它单独留了一条 `CopyLevels` / `RewindLevels` 通路，
由 `MC_USE_ITEM` 触发。`rewind` 是控制台指令，不会设置那个标记，所以走不到这条恢复路径。）

### 修复方式

`scripts/gtp_rewindfix.lua`：

1. 每帧记录「层身份」（`stage / stageType / absoluteStage / startSeed / 房间数 / IsAscent` 的组合），
   并记录玩家最后一次所在房间的状态。
2. 以 **EARLY 优先级**注册 `MC_POST_NEW_LEVEL`——在 MinimapAPI 把自己的地图推平之前，
   先把所有维度、所有房间的 `ItemIcons` 抓一份快照。
3. 以 **LATE 优先级**注册 `MC_POST_NEW_LEVEL`——等 MinimapAPI 重建完之后，把快照贴回**当前为空**的房间
   （只填空房间，绝不覆盖 MinimapAPI 自己算出来的数据）。
4. **同层判断**：只有当「重建前」和「重建后」的层身份完全一致时才贴回。
   正常下楼换层时层身份会变，地图依旧从干净状态开始，不会有上一层残留的图标。
5. 额外在 `MC_POST_NEW_ROOM` 上补一次（限定在重建后 5 帧窗口内），
   防止 MinimapAPI 在某些版本里改在换房回调中重建地图。

可以在 **Mod Config Menu → GoodTripPlus → 修复 rewind 后掉落物图标消失** 里开关；
也可以在 `gtconfig.lua` 里设置 `gt.FixRewindPickupIcons = false`。

### 自查手段

游戏内控制台输入 `gtpdiag`，会打印当前层身份、修复开关、上一次恢复结果、
各维度房间数与带图标房间数，方便确认修复是否命中。

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
