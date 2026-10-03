--[[
  GoodTripPlus - 深牢 II 的「标记骷髅」房间标记
  ============================================================

  需求：深牢 II（Depths II）里有一个特殊的骷髅障碍物，炸掉后固定掉落愚者卡牌
  （The Fool）。玩家需要在地图上知道它在哪个房间。

  识别依据（不是逆向猜的，都是游戏/API 里的正式数据）
  ---------------------------------------------------
  * 游戏自带 `resources/scripts/enums.lua` 第 497 行：
      GRID_ROCK_ALT2 = 26, -- special skull in Depths 2
    这就是那个骷髅的网格类型，注释直接写明了「Depths 2 的特殊骷髅」。
  * 房间的**生成表**里，网格物件的类型用的不是 GridEntityType 而是 StbGridType
    （REPENTOGON 的 `Repentogon/resources/scripts/enums_ex.lua` 第 1625 行）：
      ALT_ROCK_MARKED = 1008, MARKED_SKULL = 1008,
    所以「这个房间会生成这个骷髅」= 生成表里存在 Type == 1008 的条目。
  * 层判定用 `Level:GetStage() == LevelStage.STAGE3_2`（= 6），即深牢 II
    （同章第二层的其它变体 Necropolis II / Dank Depths II 一并覆盖）。

  为什么用「生成表」而不是「扫实体」
  ----------------------------------
  1. 骷髅可能在玩家进房前就被炸掉/不存在了，扫实体拿不到；生成表是布局自带的，永远在。
  2. 生成表可以在地图重建后重新读取，不需要缓存房间内容快照（rewind 之后也不会丢）。

  标记方式：复用 MinimapAPI 的房间图标系统
  ----------------------------------------
  MinimapAPI 的房间对象有 `PermanentIcons` / `VisitedIcons` 两个图标名数组，
  渲染时 `VisitedIcons` 只在「房间已探索」时才画（见它的 renderIconsInlineFunc 调用处）。
  它自己标镜子房 / 矿车房用的就是这个机制（`t.VisitedIcons = {"MirrorRoom"}`）。

  所以这里做两件事：
    1. 启动时用 `MinimapAPI:AddIcon` 注册一个自己的图标 `TintedSkull`
       （素材 `resources/gfx/goodtripplus/TintedSkull.png`，16x16，随本模组走）；
    2. 把那个图标 ID 塞进对应房间的 `VisitedIcons`。
  好处是：
    * 坐标、缩放、大小图切换、地图滑动全部由 MinimapAPI 自己算，天然对齐；
    * 「没进去过的房间不显示」这条防剧透规则是 MinimapAPI 自己执行的，不用我们重写。
  注意图标尺寸必须与 MinimapAPI 的图标一致（16x16、pivot 0,0），否则它的图标位置计算会错位；
  万一 `AddIcon` 不存在或精灵加载失败，会退回它自带的 `"Card"` 图标（见 FALLBACK_ICON_ID）。

  为什么每帧都要「确保」
  ----------------------
  MinimapAPI 会在换层、rewind（MC_POST_GAME_STARTED）等时机整表重建房间对象，
  重建后 `VisitedIcons` 会回到它自己算的初值，我们塞进去的图标就没了。
  每帧补一次是最省事且能自愈的做法：只遍历当前层的房间（几十个），
  命中集合为空时直接 return，开销可忽略。

  诊断：控制台 `gtpdiag` 会附带本模块的统计（与 rewind 修复共用同一条命令）。
]]--

local GTP_SKULL = {}

-- 生成表里的网格类型：StbGridType.MARKED_SKULL / ALT_ROCK_MARKED
-- 等价于 GridEntityType.GRID_ROCK_ALT2（= 26，原版 enums.lua 注释「special skull in Depths 2」）
local MARKED_SKULL_SPAWN_TYPE = 1008

-- 自己的标记图标：resources/gfx/goodtripplus/TintedSkull.png（16x16，随本模组分发）
-- 通过 MinimapAPI:AddIcon 注册进它的图标表，之后就能像内置图标一样塞进 room.VisitedIcons。
-- 尺寸必须与 MinimapAPI 的图标一致（16x16、pivot 0,0），否则它的图标位置计算会错位。
local MARKER_ICON_ID = "TintedSkull"
local MARKER_ICON_ANIM = "TintedSkull"

-- 兜底图标：万一 MinimapAPI 太老没有 AddIcon、或精灵加载失败，
-- 退回它自带的卡牌图标（语义相近，功能不至于整个失效）
local FALLBACK_ICON_ID = "Card"

-- LevelStage.STAGE3_2 —— 深牢 II
local TARGET_STAGE = 6

-- 图标注册状态：nil = 还没成功过（下次再试）；true = 已注册；false = 本环境没戏
local marker_icon_state = nil

local stats = {
  scans = 0,          -- 重新扫描生成表的次数（每层一次）
  found_rooms = 0,    -- 最近一次扫描找到的骷髅房数量
  applied = 0,        -- 累计往房间图标表里补了多少次
  last_result = "尚未触发",
}

-- 本层「含标记骷髅」的房间集合，键为网格索引；层身份变化时重建
local marked_rooms = {}
local marked_key = nil

local function log(message)
  if gt.DebugMod then
    Isaac.ConsoleOutput("[GoodTripPlus] " .. message .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. message)
  end
end

local function is_enabled()
  return gt:get_config_bool("FoolsSkullRoom", true)
end

-- 懒注册我们的骷髅图标（放到运行时做，确保 MinimapAPI 已经加载）
local function register_marker_icon()
  if marker_icon_state ~= nil then
    return marker_icon_state
  end
  if not (MinimapAPI and MinimapAPI.AddIcon) then
    return false -- 还没就绪，下次再试（刻意不缓存失败）
  end

  local ok, sprite = pcall(function()
    local s = Sprite()
    s:Load("gfx/goodtripplus/TintedSkull.anm2", true)
    return s
  end)

  if ok and sprite then
    marker_icon_state = true
    MinimapAPI:AddIcon(MARKER_ICON_ID, sprite, MARKER_ICON_ANIM, 0)
    log("标记骷髅：已注册自定义骷髅图标 " .. MARKER_ICON_ID)
  else
    marker_icon_state = false
    log("标记骷髅：骷髅图标注册失败，退回 " .. FALLBACK_ICON_ID)
  end
  return marker_icon_state
end

local function marker_icon_id()
  return register_marker_icon() and MARKER_ICON_ID or FALLBACK_ICON_ID
end

-- 层身份：用于判断缓存是否还有效。换层（含 rewind 回来的层）时至少一个字段会变
local function floor_key(level)
  return table.concat({
    tostring(level:GetStage()),
    tostring(level:GetStageType()),
    tostring(level:GetAbsoluteStage()),
    tostring(level:GetRooms().Size),
  }, "/")
end

-- 读一条生成表条目对应的类型，拿不到就返回 nil。
-- RoomSpawn:PickEntry(0) 是按权重选一条 SpawnEntry，属于 REPENTOGON 提供的接口，
-- 所以这里用 pcall 包住：万一接口不存在，本功能静默不生效，而不是让 mod 报错。
local function spawn_entry_type(spawn)
  if type(spawn) ~= "table" and type(spawn) ~= "userdata" then
    return nil
  end
  local ok, entry = pcall(function() return spawn:PickEntry(0) end)
  if ok and entry ~= nil then
    local entry_type = entry.Type
    if type(entry_type) ~= "number" then
      entry_type = entry.type
    end
    if type(entry_type) == "number" then
      return entry_type
    end
  end
  return nil
end

-- 这个房间的生成表里有「标记骷髅」吗
local function room_has_marked_skull(descriptor)
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
        if spawn_entry_type(spawns[i]) == MARKED_SKULL_SPAWN_TYPE then
          return true
        end
      end
      return false
    end
    for i = 0, size - 1 do
      if spawn_entry_type(spawns:Get(i)) == MARKED_SKULL_SPAWN_TYPE then
        return true
      end
    end
    return false
  end)

  return ok and found == true
end

-- 重建「本层骷髅房」集合
local function rebuild_marked_rooms(level)
  marked_rooms = {}
  stats.found_rooms = 0

  local rooms = level:GetRooms()
  if rooms then
    for i = 0, rooms.Size - 1 do
      local descriptor = rooms:Get(i)
      if room_has_marked_skull(descriptor) then
        local grid_index = descriptor.SafeGridIndex or descriptor.GridIndex
        if grid_index then
          marked_rooms[grid_index] = true
          stats.found_rooms = stats.found_rooms + 1
        end
      end
    end
  end

  stats.scans = stats.scans + 1
  stats.last_result = string.format("扫描 %d 次，本层找到 %d 个骷髅房",
    stats.scans, stats.found_rooms)
  log("标记骷髅：本层找到 " .. stats.found_rooms .. " 个房间含该骷髅")
end

-- 确保某个房间的图标表里有我们的标记；返回是否真的补上了
local function ensure_icon(room, descriptor)
  -- 只标记已探索过的房间。没进去过就不该知道里面有东西（MinimapAPI 画
  -- VisitedIcons 时也会再判一次，这里判是为了不去改没意义的房间）
  if not descriptor or (descriptor.VisitedCount or 0) <= 0 then
    return false
  end

  local icon_id = marker_icon_id()
  local icons = room.VisitedIcons
  if type(icons) ~= "table" then
    icons = {}
    room.VisitedIcons = icons
  end
  for i = 1, #icons do
    if icons[i] == icon_id then
      return false
    end
  end
  icons[#icons + 1] = icon_id
  return true
end

local function update()
  if not is_enabled() then return end
  if not MinimapAPI or not MinimapAPI.Levels or not MinimapAPI.GetLevel then return end

  local level = Game():GetLevel()
  if not level then return end

  -- 只在深牢 II 干活；其它楼层连生成表都不扫
  if level:GetStage() ~= TARGET_STAGE or level:IsAscent() then
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
        stats.last_result = string.format("已标记房间 %s（累计 %d 次）",
          tostring(grid_index), stats.applied)
        log("标记骷髅：房间 " .. tostring(grid_index) .. " 已加上骷髅图标")
      end
    end
  end
end

gt:AddCallback(ModCallbacks.MC_POST_UPDATE, update)

-- rewind / 换层会让 MinimapAPI 重建房间对象，缓存本身仍有效（同一层），
-- 但为了让「上次结果」在诊断里可读，这里更新一下描述
gt:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
  marked_key = nil
end)

-- 把统计并入统一的 gtpdiag 输出（MC_EXECUTE_CMD 的返回串会自动拼接）
gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
  if not command or command:lower() ~= "gtpdiag" then
    return
  end
  -- 诊断自身出错也不能拖垮控制台命令：整段包一层 pcall
  local ok, diag = pcall(function()
  local lines = {}
  lines[#lines + 1] = "skullRoom.enabled=" .. tostring(is_enabled()) ..
    " stage=" .. tostring(Game():GetLevel() and Game():GetLevel():GetStage())
  lines[#lines + 1] = "skullRoom.scans=" .. stats.scans ..
    " foundRooms=" .. stats.found_rooms ..
    " applied=" .. stats.applied
  lines[#lines + 1] = "skullRoom.lastResult=" .. stats.last_result
  lines[#lines + 1] = "skullRoom.icon=" .. tostring(marker_icon_id()) ..
    (marker_icon_state == true and " (custom)" or " (fallback)")

  local ids = {}
  for grid_index in pairs(marked_rooms) do
    ids[#ids + 1] = tostring(grid_index)
  end
  table.sort(ids)
  lines[#lines + 1] = "skullRoom.rooms={" .. table.concat(ids, ",") .. "}"
  return table.concat(lines, "\n")
  end)
  -- ⚠️ 不返回字符串：MC_EXECUTE_CMD 的返回值会被引擎逐行打印到控制台，
  -- 多行串在本机（REPENTOGON 的 ImGui 控制台）会当场闪退（2026-10-03 实测：
  -- 输出打印完立刻 "Lua stack trace:"（空栈）+ "Caught exception, writing minidump..."；
  -- 同环境 MinimapAPI 的 mapitel 返回 nil 就正常）。改逐行 ConsoleOutput + DebugString，
  -- 回调返回 nil。
  if not ok then
    diag = "skullRoom ERROR: " .. tostring(diag)
  end
  for line in tostring(diag):gmatch("[^\n]+") do
    Isaac.ConsoleOutput("[GoodTripPlus] " .. line .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. line)
  end
end)

GTP_SKULL.stats = stats
return GTP_SKULL
