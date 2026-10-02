--[[
  GoodTripPlus - "rewind" 掉落物图标修复
  ============================================================

  问题现象
  --------
  在控制台输入 rewind（撤销当前房间的所有变化，并退回上一个房间）之后，
  小地图上所有房间的掉落物图标全部消失，必须重新进入每个房间才会恢复。

  根因
  ----
  掉落物图标由 MinimapAPI 绘制，数据缓存在它自己的房间对象上：room.ItemIcons。
  MinimapAPI 每帧只会重算「玩家当前所在房间」的图标
  （见 MinimapAPI:GetCurrentRoomPickupIDs），其它房间的 ItemIcons 一直保留着
  「玩家当时在那个房间里」看到的那一份。

  rewind 本质上是一次关卡状态回滚（和发光沙漏同类机制），它会让关卡被重建，
  因此 MC_POST_NEW_LEVEL 会被触发。MinimapAPI 在 MC_POST_NEW_LEVEL 里执行的是
  ClearLevels() + LoadDefaultMap()：所有房间对象被丢弃重建，新建的房间
  ItemIcons = {}。而图标只在「玩家待在房间里」时才会产生，所以回滚之后整张地图的
  掉落物图标都是空的，只能靠一个个重新进房间刷出来。

  （发光沙漏之所以没这个问题，是因为 MinimapAPI 为它单独留了一条
  CopyLevels/RewindLevels 通路，由 MC_USE_ITEM 触发；rewind 指令不会设置那个标记。）

  修复思路
  --------
  在 MinimapAPI 响应 MC_POST_NEW_LEVEL 之前（EARLY 优先级）先把整张地图各房间的
  ItemIcons 抓一份快照，等 MinimapAPI 重建完成之后（LATE 优先级）再贴回去；
  随后一两个换房回调里再补一次，防止 MinimapAPI 在 MC_POST_NEW_ROOM 里又重建一遍。

  只有当「重建前后是同一层」时才贴回（用 stage / stageType / absoluteStage /
  startSeed / 房间数 / IsAscent 组合出的层身份判断），所以正常下楼换层时地图依旧
  是干净的，不会有上一层残留的图标。

  关掉这个修复：Mod Config Menu 里的 "修复 rewind 后掉落物图标消失"，或 gtconfig.lua
  里设置 gt.FixRewindPickupIcons = false。
]]

local GTP = {}

-- 优先级锚点：MinimapAPI 自己用 CallbackPriority.IMPORTANT - 1 注册
-- MC_POST_NEW_LEVEL（见 minimapapi/constants.lua），所以这里取 ±1000 保证
-- 一个稳稳地跑在它前面、一个稳稳地跑在它后面。
local ANCHOR = (CallbackPriority and CallbackPriority.IMPORTANT) or 0
local EARLY_PRIORITY = ANCHOR - 1000
local LATE_PRIORITY = ANCHOR + 1000

-- 快照在重建后保留的帧数，用于兜底再贴一次。
local PENDING_WINDOW_FRAMES = 5

local pending = nil         -- { identity = ..., levels = ..., frame = ... }
local last_identity = nil
local last_restore = "尚未触发"
local saw_rewind_command = false

local function debug_log(message)
  if not gt.DebugMod then
    return
  end
  Isaac.ConsoleOutput("[GoodTripPlus] " .. message .. "\n")
  Isaac.DebugString("[GoodTripPlus] " .. message)
end

local function fix_enabled()
  return gt:get_config_bool("FixRewindPickupIcons", true)
end

-- 用一组在「同一层」内稳定的字段拼出层身份。
-- 换层时 stage / absoluteStage / 种子 / 房间数 至少有一个会变，
-- 而 rewind 回滚到同一层时这组值完全一致。
local function level_identity()
  local level = Game():GetLevel()
  if not level then
    return nil
  end
  local rooms = level:GetRooms()
  return table.concat({
    level:GetStage(),
    level:GetStageType(),
    level:GetAbsoluteStage(),
    Game():GetSeeds():GetStartSeed(),
    rooms and rooms.Size or -1,
    level:IsAscent() and 1 or 0,
  }, ":")
end

local function copy_icons(icons)
  local copy = {}
  for i = 1, #icons do
    copy[i] = icons[i]
  end
  return copy
end

-- 抓取 MinimapAPI.Levels 里所有维度、所有房间的掉落物图标。
-- 这里覆盖全部维度（0 / 1 镜像 / 2），所以镜像世界里的图标也能一起保住。
local function capture_item_icons()
  local snapshot = {}
  if not MinimapAPI or not MinimapAPI.Levels then
    return snapshot
  end
  for dimension, rooms in pairs(MinimapAPI.Levels) do
    local dimension_snapshot = {}
    for _, room in ipairs(rooms) do
      local descriptor = room.Descriptor
      local icons = room.ItemIcons
      if descriptor and descriptor.ListIndex and icons and #icons > 0 then
        dimension_snapshot[descriptor.ListIndex] = copy_icons(icons)
      end
    end
    snapshot[dimension] = dimension_snapshot
  end
  return snapshot
end

-- 把快照贴回重建后的房间。只填「当前是空的」房间，绝不覆盖 MinimapAPI 已经算好的数据。
local function restore_item_icons(snapshot)
  if not MinimapAPI or not MinimapAPI.Levels then
    return 0
  end
  local restored_rooms = 0
  for dimension, rooms in pairs(MinimapAPI.Levels) do
    local dimension_snapshot = snapshot[dimension]
    if dimension_snapshot then
      for _, room in ipairs(rooms) do
        local descriptor = room.Descriptor
        local list_index = descriptor and descriptor.ListIndex
        local icons = list_index and dimension_snapshot[list_index]
        if icons and (not room.ItemIcons or #room.ItemIcons == 0) then
          room.ItemIcons = copy_icons(icons)
          restored_rooms = restored_rooms + 1
        end
      end
    end
  end
  return restored_rooms
end

-- 把暂存的快照贴回去（如果还处在有效窗口内，且确实是同一层）。
local function apply_pending(reason)
  if not pending then
    return
  end
  if Game():GetFrameCount() - pending.frame > PENDING_WINDOW_FRAMES then
    pending = nil
    return
  end
  if not fix_enabled() then
    return
  end
  if not pending.identity or pending.identity ~= level_identity() then
    -- 换了层：地图本来就该是干净的，什么也不做。
    last_restore = "换层，正常清空"
    return
  end

  local restored_rooms = restore_item_icons(pending.levels)
  last_restore = "同层回滚（" .. reason .. "），恢复 " .. restored_rooms .. " 个房间的图标"
  debug_log("rewind fix: " .. last_restore)
end

-- 每帧记录当前层身份，供换层判断使用。
gt:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
  last_identity = level_identity()
end)

-- 抓快照：必须跑在 MinimapAPI 的 MC_POST_NEW_LEVEL 处理之前。
gt:AddPriorityCallback(ModCallbacks.MC_POST_NEW_LEVEL, EARLY_PRIORITY, function()
  pending = {
    identity = last_identity,
    levels = capture_item_icons(),
    frame = Game():GetFrameCount(),
  }
end)

-- 贴快照：跑在 MinimapAPI 重建完 MinimapAPI.Levels 之后。
gt:AddPriorityCallback(ModCallbacks.MC_POST_NEW_LEVEL, LATE_PRIORITY, function()
  apply_pending("post_new_level")
end)

-- 兜底：万一 MinimapAPI 是在换房回调里才重建地图，这里再补一次。
gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
  apply_pending("post_new_room")
end)

-- 记录是否真的出现过 rewind 指令（仅用于诊断输出）。
gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
  if command and command:lower() == "rewind" then
    saw_rewind_command = true
    debug_log("detected 'rewind' console command")
  end
end)

-- 诊断指令：控制台输入 gtpdiag
gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
  if not command or command:lower() ~= "gtpdiag" then
    return
  end
  local function out(message)
    Isaac.ConsoleOutput("[GoodTripPlus] " .. message .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. message)
  end
  out("REWIND FIX DIAGNOSTICS BEGIN")
  out("identity=" .. tostring(level_identity()) ..
    " tracked=" .. tostring(last_identity))
  out("fixEnabled=" .. tostring(fix_enabled()) ..
    " lastRestore=" .. tostring(last_restore) ..
    " sawRewindCmd=" .. tostring(saw_rewind_command))
  out("pending=" .. (pending and ("yes frame=" .. tostring(pending.frame)) or "no") ..
    "  MinimapAPI=" .. tostring(MinimapAPI ~= nil))
  if MinimapAPI and MinimapAPI.Levels then
    for dimension, rooms in pairs(MinimapAPI.Levels) do
      local with_icons, total_icons = 0, 0
      for _, room in ipairs(rooms) do
        local icons = room.ItemIcons
        if icons and #icons > 0 then
          with_icons = with_icons + 1
          total_icons = total_icons + #icons
        end
      end
      out("dim=" .. tostring(dimension) .. " rooms=" .. #rooms ..
        " roomsWithIcons=" .. with_icons .. " icons=" .. total_icons)
    end
  end
  out("REWIND FIX DIAGNOSTICS END")
  return true
end)

return GTP
