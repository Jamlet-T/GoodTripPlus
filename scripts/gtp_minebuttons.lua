--[[
  GoodTripPlus - 矿洞 II 的「黄色轨道按钮」（Rail Plate）房间标记
  ============================================================

  需求：矿洞二层（Mines II / Ashpit）里散布着 3 个黄色轨道按钮（Rail Plate），
  全部踩下后放下通往刀片碎片 2（Knife Piece 2）的轨道桥（腐妈支线必经）。
  玩家需要在地图上知道按钮在哪个房间、哪些已经踩过。

  识别依据（三条独立证据链互相咬合，无一处靠猜）
  ---------------------------------------------------
  * 运行时身份：网格实体 GridEntityType.GRID_PRESSURE_PLATE（= 20，游戏自带
    resources/scripts/enums.lua 第 489 行）+ 变体 PressurePlateVariant 的
    MINES_PUZZLE / RAIL_PLATE（= 3，REPENTOGON `repentogon/resources/scripts/enums_ex.lua`
    第 1729 行；本机 stats-plus 自带的 isaac-typescript-definitions 同值）。
  * 生成表写法：StbGridType.PRESSURE_PLATE（= 4500，同 enums_ex.lua）+ Variant 3。
    注意生成表里的类型不是运行时的 GridEntityType（骷髅房那条 1008 同理）。
  * 原版数据实测：用 gibbed 式读取器（社区项目 zdd14990/isaac-offline-map-generator 的
    archive.py / resources.py，Gibbed.Rebirth 的干净移植）解开本机
    `resources/packed/rooms.a` 等档案的 STB1 房间数据库：`29.mines.stb` /
    `30.ashpit.stb` 里所有名为 "Button Room" 的房间（variant 5000+）每间恰好 1 条
    `type=4500 / variant=3` 的生成条目，其它楼层没有 4500/3。房间名与社区 mod
    guidepost（按 `Data.Name == 'Button Room'` 识别）互相印证。
    我们按生成表识别，比按房间名更稳（生成表是游戏加载时真实消费的数据）。

  层判定 = STAGE2_1（Mines I）/ STAGE2_2（Mines II）且非回溯线。**生成表本身是
  准入门**——按钮只在持刀片碎片 1 时生成（wiki：Rail Plate 仅在此条件下出现），
  没接钥匙的层扫出来是空集，什么都不标；主路径楼层（洞窟/地下墓穴等）的布局数据里
  本来就没有 4500/3，扫了也不会误标。

  标记方式：复用 MinimapAPI 的房间图标系统（与骷髅房 / Delirium 房同思路）
  --------------------------------------------------------
  懒注册自定义图标 `MineButton`（素材 resources/gfx/goodtripplus/MineButton.png +
  MineButton.anm2，16x16、pivot 0,0，图案约 8x8 偏左上，与 TintedSkull 同规格），
  塞进房间的 **`VisitedIcons`**——只在玩家**进过房间**后才标注，与骷髅房同语义
  （v2.0.x 修正：初版误用 `PermanentIcons`，房间一显示在地图上就画，等于剧透了
  没进过的按钮房；按钮房的位置本该由玩家自己探索发现）。进入判定与骷髅房一致：
  `descriptor.VisitedCount > 0` 时才补，MinimapAPI 画 `VisitedIcons` 时自己也再判一次。
  按钮房是 1x1 普通房、没有其它图标，append 即可（Delirium 的「插第 1 位」是
  2x2 boss 房被按 1x1 显示时的坑，这里用不上）。
  图标注册失败**不退回**语义不符的内置图标（宁可没有），与骷髅房退回 Card 不同。

  图标一经标注就永久保留
  ----------------------
  按用户拍板（2026-10-04）：不做「已踩自动撤标」——标过的房间图标一直保留到
  换层。（v2.0.x 曾做过自动撤标：先因「Room:GetGridIndex 的房间内局部索引 vs
  marked_rooms 的楼层系 SafeGridIndex 键，两套坐标系对不上」从未触发过，修好
  后需求又取消，整套机制已移除。留下的教训：这两套网格索引不能互比。）

  为什么每帧都要「确保」：同骷髅房——MinimapAPI 在换层 / rewind 时会整表重建
  房间对象，重建后图标表回到它自己的初值，每帧补一次可自愈，开销可忽略。

  开关：MCM → GoodTripPlus → 「标记矿洞 II 的轨道按钮房」，或 gtconfig.lua 里
  gt.MineButtonRoom = true（默认开）。

  诊断：控制台 `gtpdiag` 附带 mineButtons.* 统计。
]]--

local GTP_MINEBUTTONS = {}

-- 层：矿洞 I / 矿洞 II（LevelStage.STAGE2_1 = 3、STAGE2_2 = 4；常量缺失退回数字）
local STAGE_MINES_1 = (LevelStage and LevelStage.STAGE2_1) or 3
local STAGE_MINES_2 = (LevelStage and LevelStage.STAGE2_2) or 4

-- 生成表（StbGridType）里的按钮身份
local SPAWN_TYPE_PLATE = 4500    -- StbGridType.PRESSURE_PLATE
local PLATE_VARIANT_RAIL = 3     -- PressurePlateVariant.MINES_PUZZLE / RAIL_PLATE

-- 自己的标记图标：resources/gfx/goodtripplus/MineButton.png（16x16，随本模组分发）
local MARKER_ICON_ID = "MineButton"
local MARKER_ICON_ANIM = "MineButton"

local stats = {
  scans = 0,          -- 重新扫描生成表的次数（每层一次）
  found_rooms = 0,    -- 最近一次扫描找到的按钮房数量
  applied = 0,        -- 累计往房间图标表里补了多少次
  last_result = "not triggered",
}

-- 本层「含黄色按钮」的房间集合，键为网格索引；层身份变化时重建
local marked_rooms = {}
local marked_key = nil

local function log(message)
  if gt:is_debug() then
    require("scripts.gtp_console").write("[GoodTripPlus] " .. message .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. message)
  end
end

local function is_enabled()
  return gt:get_config_bool("MineButtonRoom", true)
end

-- 懒注册按钮图标（放到运行时做，确保 MinimapAPI 已经加载）。
-- 失败不退回内置图标（语义都不符，宁可没有）；刻意不缓存失败，下次再试。
local marker_icon_state = nil -- nil = 还没成功过；true / false = 已定论
local function register_marker_icon()
  if marker_icon_state ~= nil then
    return marker_icon_state
  end
  if not (MinimapAPI and MinimapAPI.AddIcon) then
    return false -- MinimapAPI 还没就绪
  end

  local ok, sprite = pcall(function()
    local s = Sprite()
    s:Load("gfx/goodtripplus/MineButton.anm2", true)
    return s
  end)

  if ok and sprite then
    marker_icon_state = true
    MinimapAPI:AddIcon(MARKER_ICON_ID, sprite, MARKER_ICON_ANIM, 0)
    log("mine buttons: registered custom icon " .. MARKER_ICON_ID)
  else
    marker_icon_state = false
    log("mine buttons: icon registration failed; feature unavailable (no fallback icon)")
  end
  return marker_icon_state
end

-- 层身份：判断缓存是否还有效。换层（含 rewind 回来的层）时至少一个字段会变
local function floor_key(level)
  return table.concat({
    tostring(level:GetStage()),
    tostring(level:GetStageType()),
    tostring(level:GetAbsoluteStage()),
    tostring(level:GetRooms().Size),
  }, "/")
end

-- 是不是矿洞层（矿洞 I / II；回溯线与贪婪模式不参与）
local function is_mines_stage(level)
  local stage = level:GetStage()
  return stage == STAGE_MINES_1 or stage == STAGE_MINES_2
end

-- 读一条生成表条目的 Type/Variant，拿不到返回 nil。
-- RoomSpawn:PickEntry(0) 是按权重选一条 SpawnEntry，属 REPENTOGON 提供的接口，
-- 用 pcall 包住：接口不存在时本功能静默不生效，而不是让 mod 报错。
local function spawn_entry_info(spawn)
  if type(spawn) ~= "table" and type(spawn) ~= "userdata" then
    return nil
  end
  local ok, entry = pcall(function() return spawn:PickEntry(0) end)
  if ok and entry ~= nil then
    local entry_type = entry.Type
    if type(entry_type) ~= "number" then
      entry_type = entry.type
    end
    local entry_variant = entry.Variant
    if type(entry_variant) ~= "number" then
      entry_variant = entry.variant
    end
    if type(entry_type) == "number" then
      return entry_type, entry_variant
    end
  end
  return nil
end

-- 这个房间的生成表里有「黄色轨道按钮」吗（type=4500 且 variant=3）
local function room_has_rail_button(descriptor)
  if not descriptor then return false end
  local config = descriptor.Data
  local spawns = config and config.Spawns
  if not spawns then return false end

  local ok, found = pcall(function()
    -- RoomSpawnList：Size + Get(i)，下标从 0 开始
    local size = spawns.Size
    if type(size) ~= "number" or size <= 0 then
      -- 兼容普通 Lua 数组形式
      size = #spawns
      for i = 1, size do
        local t, v = spawn_entry_info(spawns[i])
        if t == SPAWN_TYPE_PLATE and v == PLATE_VARIANT_RAIL then
          return true
        end
      end
      return false
    end
    for i = 0, size - 1 do
      local t, v = spawn_entry_info(spawns:Get(i))
      if t == SPAWN_TYPE_PLATE and v == PLATE_VARIANT_RAIL then
        return true
      end
    end
    return false
  end)

  return ok and found == true
end

-- 重建「本层按钮房」集合
local function rebuild_marked_rooms(level)
  marked_rooms = {}
  stats.found_rooms = 0

  local rooms = level:GetRooms()
  if rooms then
    for i = 0, rooms.Size - 1 do
      local descriptor = rooms:Get(i)
      if room_has_rail_button(descriptor) then
        local grid_index = descriptor.SafeGridIndex or descriptor.GridIndex
        if grid_index then
          marked_rooms[grid_index] = true
          stats.found_rooms = stats.found_rooms + 1
        end
      end
    end
  end

  stats.scans = stats.scans + 1
  stats.last_result = string.format("scans=%d, button rooms on floor=%d",
    stats.scans, stats.found_rooms)
  log("mine buttons: rooms found on floor=" .. stats.found_rooms)
end

-- 确保房间的 VisitedIcons 里有我们的图标（append；语义与骷髅房一致：
-- 只标进过的房间）；返回是否真的补上了
local function ensure_icon(room, descriptor)
  if not register_marker_icon() then
    return false
  end
  -- 只标记已探索过的房间。没进去过就不该知道里面有按钮（MinimapAPI 画
  -- VisitedIcons 时也会再判一次，这里判是为了不去改没意义的房间）
  if not descriptor or (descriptor.VisitedCount or 0) <= 0 then
    return false
  end
  local icons = room.VisitedIcons
  if type(icons) ~= "table" then
    icons = {}
    room.VisitedIcons = icons
  end
  for i = 1, #icons do
    if icons[i] == MARKER_ICON_ID then
      return false
    end
  end
  icons[#icons + 1] = MARKER_ICON_ID
  return true
end

local function update()
  if not is_enabled() then return end
  if not MinimapAPI or not MinimapAPI.Levels or not MinimapAPI.GetLevel then return end

  local level = Game():GetLevel()
  if not level then return end

  -- 只在矿洞 I / II 干活；其它楼层连生成表都不扫
  if not is_mines_stage(level) or level:IsAscent() or Game():IsGreedMode() then
    return
  end

  local key = floor_key(level)
  if key ~= marked_key then
    marked_key = key
    rebuild_marked_rooms(level)
  end

  if next(marked_rooms) == nil then return end

  local rooms = MinimapAPI:GetLevel()
  if not rooms then return end

  for _, room in ipairs(rooms) do
    local descriptor = room.Descriptor
    local grid_index = descriptor and (descriptor.SafeGridIndex or descriptor.GridIndex)
    if grid_index and marked_rooms[grid_index] then
      if ensure_icon(room, descriptor) then
        stats.applied = stats.applied + 1
        stats.last_result = string.format("marked room=%s, total applications=%d",
          tostring(grid_index), stats.applied)
        log("mine buttons: added icon to room " .. tostring(grid_index))
      end
    end
  end
end

gt:AddCallback(ModCallbacks.MC_POST_UPDATE, update)

-- 换层时清掉层缓存（下次 update 会按新层重建）
gt:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
  marked_key = nil
end)

-- MCM 开关：不在本模块注册——2026-10-04 起全部 MCM 项集中在 gtrep.lua 的
-- 统一注册块里按用户指定顺序注册（本功能配置键 = MineButtonRoom，默认开；
-- 文案在 gtrep.lua 的 GT_STRINGS.minebutton_*）。

-- 把统计并入统一的 gtpdiag 输出（MC_EXECUTE_CMD 的返回串会自动拼接）
gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
  if not command or command:lower() ~= "gtpdiag" then
    return
  end
  -- 诊断自身出错也不能拖垮控制台命令：整段包一层 pcall
  local ok, diag = pcall(function()
    local level = Game():GetLevel()
    local lines = {}
    lines[#lines + 1] = "mineButtons.enabled=" .. tostring(is_enabled()) ..
      " stage=" .. tostring(level and level:GetStage()) ..
      " isMines=" .. tostring(level and is_mines_stage(level) or false)
    lines[#lines + 1] = "mineButtons.scans=" .. stats.scans ..
      " foundRooms=" .. stats.found_rooms ..
      " applied=" .. stats.applied
    lines[#lines + 1] = "mineButtons.lastResult=" .. stats.last_result
    lines[#lines + 1] = "mineButtons.icon=" ..
      (marker_icon_state == true and MARKER_ICON_ID .. " (custom)"
        or marker_icon_state == false and "none (registration failed)"
        or "pending")

    local ids = {}
    for grid_index in pairs(marked_rooms) do
      ids[#ids + 1] = tostring(grid_index)
    end
    table.sort(ids)
    lines[#lines + 1] = "mineButtons.rooms={" .. table.concat(ids, ",") .. "}"
    return table.concat(lines, "\n")
  end)
  -- ⚠️ 不返回字符串：MC_EXECUTE_CMD 的返回值会被引擎逐行打印到控制台，
  -- 多行串在本机会当场闪退（同骷髅房/delirium 的处理），改逐行输出，回调返回 nil。
  if not ok then
    diag = "mineButtons ERROR: " .. tostring(diag)
  end
  for line in tostring(diag):gmatch("[^\n]+") do
    require("scripts.gtp_console").write("[GoodTripPlus] " .. line .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. line)
  end
end)

GTP_MINEBUTTONS.stats = stats
return GTP_MINEBUTTONS
