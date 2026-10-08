--[[
  GoodTripPlus - 虚空层「精神错乱（Delirium）boss 房」标记
  ============================================================

  需求（docs/FEATURES.md 待实现 #5）
  ----------------------------------
  虚空层（The Void）里有 6~8 间 boss 房，其中**只有一间**是精神错乱（Delirium）。
  其它 boss 房都是随机旧 boss。玩家想知道「哪一间是 Delirium」，好先去别的 boss 房
  捡完道具再打，或者提前知道要小心哪一间。本模块把这间房在地图上标出来。

  怎么认出哪间是 Delirium（不是逆向猜的，是游戏自己的数据）
  --------------------------------------------------------
  1. **层**：虚空层 = `LevelStage.STAGE7`（= 12，见原版 enums.lua；
     注意 STAGE8 = 13 是 Home，不是虚空层）。回溯线 / 贪婪模式不参与。
  2. **房间**：Delirium 的房在引擎里是一间 **2x2 的 boss 房**
     （wiki「Locating Delirium」与 MinimapAPI 自己的 `main.lua` 都这么认定，
     它把 2x2 boss 房当 Delirium 处理；Mr. Fred 是 1x2，不受影响）。
     所以判据 = `RoomDescriptor.Data.Type == RoomType.ROOM_BOSS`
     且 `Data.Shape == RoomShape.ROOMSHAPE_2x2`。
  3. **兜底**：`RoomDescriptor.DeliriumDistance`（引擎字段，官方注释：
     "Helper for The Void stage, holds the distance to the Delirium boss in room nr."）
     —— Delirium 那间房的距离为 0。仅当上面找不到任何 2x2 boss 房时才用它兜底。

  标记方式：复用 MinimapAPI 的房间图标系统（与骷髅房同思路）
  --------------------------------------------------------
  用 `MinimapAPI:AddIcon` 注册自定义图标 `Delirium`（素材
  `resources/gfx/goodtripplus/Delirium.png` + `Delirium.anm2`，16x16、pivot 0,0；
  图案＝粉色圆脸（黑描边）+ 两只黄眼，与 TintedSkull 同样约 8x8 偏左上）。

  与骷髅房不同的一点，也是本模块唯一需要留神的地方：
    * 骷髅房塞的是 `VisitedIcons`（进过才画）；
    * 本模块要塞 **`PermanentIcons`** —— 我们想在**进那间房之前**就看出它是
      Delirium（进都进去了就没意义了）。`PermanentIcons` 只要房间在地图上
      「有图标」就画（`IsIconVisible()` = DisplayFlags 的 show-icon 位），
      没探索到的房间 MinimapAPI 自己不会显示，防剧透规则照旧由它保证。
    * **必须放在图标列表的第 1 位**：MinimapAPI 的 1x1 房间多图标位置表
      （`RoomShapeIconPositions[2][ROOMSHAPE_1x1]`）只给了 **1 个**位置，
      排在后面的图标会因为取不到坐标而**不画**。而虚空层默认（未开
      OverrideVoid）会把 Delirium 的 2x2 房按 1x1 显示，所以一定要插到最前。
      我们把 Delirium 图标插到第 1 位，原有的 "Boss" 图标留在后面
      （OverrideVoid 开着时是 2x2，两个图标都会画）。

  为什么每帧「确保」
  ------------------
  同骷髅房：MinimapAPI 在换层 / rewind 等时机会整表重建房间对象，
  重建后 `PermanentIcons` 回到它自己算的初值。每帧补一次最省事且能自愈，
  只遍历当前层几十个房间，命中集合为空时直接 return，开销可忽略。

  开关：MCM → GoodTripPlus → 「标记虚空层的精神错乱房」，或 gtconfig.lua 里
  gt.DeliriumRoom = true（**默认关**，属超定位的显示功能）。

  诊断：控制台 `gtpdiag` 会附带 delirium.* 统计，并列出本层所有 boss 房 /
  距离为 0 的房（gid / type / shape / dd），便于现场核对判据。
]]--

local GTP_DELIRIUM = {}

-- 虚空层 = LevelStage.STAGE7（= 12）。常量缺失时退回数字，避免环境差异。
local VOID_STAGE = (LevelStage and LevelStage.STAGE7) or 12

-- 判据用到的枚举（同样退回数字）
local BOSS_ROOM_TYPE = (RoomType and RoomType.ROOM_BOSS) or 5
local SHAPE_2X2 = (RoomShape and RoomShape.ROOMSHAPE_2x2) or 8

-- 自己的标记图标：resources/gfx/goodtripplus/Delirium.png（16x16，随本模组分发）
local MARKER_ICON_ID = "Delirium"
local MARKER_ICON_ANIM = "Delirium"

-- 兜底图标：AddIcon 不可用 / 精灵加载失败时，退回 MinimapAPI 自带的 Boss 图标，
-- 至少不破坏房间原有的标记
local FALLBACK_ICON_ID = "Boss"

-- 图标注册状态：nil = 还没成功过（下次再试）；true / false = 已定论
local marker_icon_state = nil

local stats = {
  scans = 0,          -- 重新扫描当前层的次数（每层一次）
  found_rooms = 0,    -- 最近一次扫描找到的 Delirium 房数量
  applied = 0,        -- 累计往房间图标表里补了多少次
  used_fallback = 0,  -- 其中靠 DeliriumDistance 兜底命中的次数
  last_result = "not triggered",
}

-- 本层「Delirium 房」集合，键为网格索引；层身份变化时重建
local marked_rooms = {}
local marked_key = nil
-- 最近一次扫描的现场记录（gtpdiag 用）
local last_scan_lines = {}

local function log(message)
  if gt:is_debug() then
    require("scripts.gtp_console").write("[GoodTripPlus] " .. message .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. message)
  end
end

local function is_enabled()
  -- 显示类功能，默认关（超定位）；需玩家在 MCM 或 gtconfig 里开
  return gt:get_config_bool("DeliriumRoom", false)
end

-- 懒注册我们的 Delirium 图标（放到运行时做，确保 MinimapAPI 已经加载）
local function register_marker_icon()
  if marker_icon_state ~= nil then
    return marker_icon_state
  end
  if not (MinimapAPI and MinimapAPI.AddIcon) then
    return false -- 还没就绪，下次再试（刻意不缓存失败）
  end

  local ok, sprite = pcall(function()
    local s = Sprite()
    s:Load("gfx/goodtripplus/Delirium.anm2", true)
    return s
  end)

  if ok and sprite then
    marker_icon_state = true
    MinimapAPI:AddIcon(MARKER_ICON_ID, sprite, MARKER_ICON_ANIM, 0)
    log("Delirium: registered custom icon " .. MARKER_ICON_ID)
  else
    marker_icon_state = false
    log("Delirium: icon registration failed; fallback=" .. FALLBACK_ICON_ID)
  end
  return marker_icon_state
end

local function marker_icon_id()
  return register_marker_icon() and MARKER_ICON_ID or FALLBACK_ICON_ID
end

-- 是否身处虚空层（回溯线 / 贪婪模式不算）
local function is_void(level)
  if not level then return false end
  if level:GetStage() ~= VOID_STAGE then return false end
  if level:IsAscent() then return false end
  if Game():IsGreedMode() then return false end
  return true
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

-- 读 RoomDescriptor.DeliriumDistance；拿不到返回 nil。
-- 该字段只在虚空层有意义，且并非所有版本都暴露，所以 pcall 包住。
local function delirium_distance(descriptor)
  if not descriptor then return nil end
  local ok, value = pcall(function() return descriptor.DeliriumDistance end)
  if ok and type(value) == "number" then
    return value
  end
  return nil
end

-- 重建「本层 Delirium 房」集合 + 现场记录
-- 判据：boss 房且 2x2 → 命中；若一个 2x2 boss 房都没有，退用 DeliriumDistance == 0
local function rebuild_marked_rooms(level)
  marked_rooms = {}
  last_scan_lines = {}
  stats.found_rooms = 0
  stats.used_fallback = 0

  local primary = {}
  local fallback = {}
  local scan = {}

  local rooms = level:GetRooms()
  if rooms then
    for i = 0, rooms.Size - 1 do
      local rd = rooms:Get(i)
      if rd and rd.Data then
        local gid = rd.SafeGridIndex or rd.GridIndex
        local dd = delirium_distance(rd)
        local is_boss = (rd.Data.Type == BOSS_ROOM_TYPE)
        -- 现场记录：boss 房，或距离为 0 的房（都值得看一眼）
        if is_boss or (dd ~= nil and dd == 0) then
          scan[#scan + 1] = string.format(
            "gid=%s type=%d shape=%d dd=%s visited=%d clear=%s",
            tostring(gid), rd.Data.Type, rd.Data.Shape, tostring(dd),
            rd.VisitedCount or 0, tostring(rd.Clear))
        end
        if is_boss and gid then
          if rd.Data.Shape == SHAPE_2X2 then
            primary[gid] = true
          elseif dd == 0 then
            fallback[gid] = true
          end
        end
      end
    end
  end

  -- 优先用 2x2 判据；没有 2x2 boss 房时（理论上不该发生）才用距离兜底
  if next(primary) ~= nil then
    marked_rooms = primary
  else
    marked_rooms = fallback
    for _ in pairs(fallback) do
      stats.used_fallback = stats.used_fallback + 1
    end
  end

  for _ in pairs(marked_rooms) do
    stats.found_rooms = stats.found_rooms + 1
  end

  last_scan_lines = scan
  stats.scans = stats.scans + 1
  stats.last_result = string.format(
    "scans=%d, Delirium rooms on floor=%d%s",
    stats.scans, stats.found_rooms,
    stats.used_fallback > 0 and (" (fallback=" .. stats.used_fallback .. ")") or "")
  log("Delirium: rooms found on floor=" .. stats.found_rooms)
end

-- 确保房间的 PermanentIcons 第 1 位是我们的图标；返回是否真的改动了
local function ensure_icon(room)
  local icon_id = marker_icon_id()
  local icons = room.PermanentIcons
  if type(icons) ~= "table" then
    icons = {}
    room.PermanentIcons = icons
  end
  if icons[1] == icon_id then
    return false
  end

  -- 插到最前：1x1 房间 MinimapAPI 只画第 1 个图标的位置表只有 1 项，
  -- 放后面会取不到坐标而不画（虚空层默认把 Delirium 的 2x2 房按 1x1 显示）。
  table.insert(icons, 1, icon_id)
  -- 去掉可能重复的自身
  for i = #icons, 2, -1 do
    if icons[i] == icon_id then
      table.remove(icons, i)
    end
  end
  return true
end

local function update()
  if not is_enabled() then return end
  if not MinimapAPI or not MinimapAPI.GetLevel then return end

  local level = Game():GetLevel()
  if not is_void(level) then
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
    local gid = descriptor and (descriptor.SafeGridIndex or descriptor.GridIndex)
    if gid and marked_rooms[gid] then
      if ensure_icon(room) then
        stats.applied = stats.applied + 1
        stats.last_result = string.format("marked room=%s, total applications=%d",
          tostring(gid), stats.applied)
        log("Delirium: added icon to room " .. tostring(gid))
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
-- 统一注册块里按用户指定顺序注册（本功能配置键 = DeliriumRoom，默认关；
-- 文案在 gtrep.lua 的 GT_STRINGS.delirium_*）。

-- 把统计并入统一的 gtpdiag 输出（与骷髅房 / rewind 修复共用同一条命令）
gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
  if not command or command:lower() ~= "gtpdiag" then
    return
  end
  -- 诊断自身出错也不能拖垮控制台命令：整段包一层 pcall
  local ok, diag = pcall(function()
    local lines = {}
    local level = Game():GetLevel()
    lines[#lines + 1] = "delirium.enabled=" .. tostring(is_enabled()) ..
      " stage=" .. tostring(level and level:GetStage()) ..
      " isVoid=" .. tostring(is_void(level)) ..
      " ascent=" .. tostring(level and level:IsAscent())
    lines[#lines + 1] = "delirium.scans=" .. stats.scans ..
      " foundRooms=" .. stats.found_rooms ..
      " applied=" .. stats.applied ..
      " usedFallback=" .. stats.used_fallback
    lines[#lines + 1] = "delirium.lastResult=" .. stats.last_result
    lines[#lines + 1] = "delirium.icon=" .. tostring(marker_icon_id()) ..
      (marker_icon_state == true and " (custom)" or " (fallback)")

    local ids = {}
    for grid_index in pairs(marked_rooms) do
      ids[#ids + 1] = tostring(grid_index)
    end
    table.sort(ids)
    lines[#lines + 1] = "delirium.rooms={" .. table.concat(ids, ",") .. "}"

    if is_void(level) then
      for _, s in ipairs(last_scan_lines) do
        lines[#lines + 1] = "deliriumScan " .. s
      end
    end
    return table.concat(lines, "\n")
  end)
  -- ⚠️ 不返回字符串（MC_EXECUTE_CMD 返回多行串在本机会闪退），逐行 ConsoleOutput + DebugString
  if not ok then
    diag = "delirium ERROR: " .. tostring(diag)
  end
  for line in tostring(diag):gmatch("[^\n]+") do
    require("scripts.gtp_console").write("[GoodTripPlus] " .. line .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. line)
  end
end)

GTP_DELIRIUM.stats = stats
return GTP_DELIRIUM
