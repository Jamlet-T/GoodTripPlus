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
  （GetCurrentRoomPickupIDs 用的是 Isaac.GetRoomEntities()，只能拿到当前房间的实体），
  其它房间的 ItemIcons 一直保留着「当时玩家待在那个房间里」看到的那一份。

  rewind 是一次关卡状态回滚，它会让 MinimapAPI 把整张地图的数据重建一遍
  （LoadDefaultMap：所有房间对象重新生成，ItemIcons 一律 {}）。
  而图标只在「玩家待在房间里」时才会产生，所以回滚之后整张地图的掉落物图标都是空的，
  只能一个个重新进房间刷出来。

  已确认的触发点（实测）
  --------------------
  rewind 会触发 MC_POST_GAME_STARTED（continued=true）。MinimapAPI 注册在这个回调上的
  MinimapAPI.OnGameLoad → LoadSaveTable 会把整张地图数据重建一遍，于是所有房间对象被重新生成、
  ItemIcons 全部变成空。实测那一帧的事件是：rebuilt=1 lost=4 sameFloor=true
  （1 个维度的房间数组被换掉，4 个原本有图标的房间同时清空）。

  不过修复本身**不去挂钩这个回调**，而是采用下面这种不依赖触发点的帧末监视，
  这样将来游戏或 MinimapAPI 改动触发路径时修复依然有效。

  修复做法（不依赖触发点）
  ----------------------
  在帧末（MC_POST_UPDATE）盯住 MinimapAPI 的数据结构：

    * 上一帧还带着图标的房间，这一帧整批变成空（>= 2 个房间），或者
    * MinimapAPI.Levels 的房间数组被整个换掉了（重建），同时又确实丢了图标

  就判定发生了「整批清空」，于是把上一帧（即回滚前）的 ItemIcons 贴回当前为空的房间。

  帧序保证了不会闪：关卡重建发生在 update 阶段，而 MC_POST_UPDATE 在 update 阶段末尾、
  渲染之前执行，所以还原发生在这一帧被画出来之前。

  只有当「回滚前后是同一层」时才贴回（用 stage / stageType / absoluteStage / startSeed /
  房间数 / IsAscent 组合出的层身份判断），所以正常下楼换层时地图依旧是干净的。

  只填空房间，绝不覆盖 MinimapAPI 已经算好的数据；一次合法的拾取最多只会让 1 个房间
  变空，因此不会被误判成「整批清空」。

  另外一条规则：**只还原「已探索过」的房间**
  ------------------------------------------
  rewind 会把「你刚离开的那个房间」（下称 B）回滚成没进去过的状态：
  B 的 RoomDescriptor.VisitedCount 归 0，地图上应该只显示一块未探索的深色格子。
  但因为你退回到了 B 的邻居 A，MinimapAPI 会给 B 来一发
  `adjroom.DisplayFlags |= AdjacentDisplayFlags`（通常 = 5，含 bit4 图标位），
  于是 IsIconVisible() 为真 —— 如果照搬回滚前那一帧的图标，B 就会显示它不该有的掉落物。

  所以还原时用当前存活的 `room.Descriptor.VisitedCount > 0` 做过滤：
  未探索的房间一律跳过、不贴图标。判定刻意不读 MinimapAPI 房间对象上的 `Visited` 缓存，
  那是重建那一刻的快照，而存活的描述符才是游戏此刻的真实状态。

  这是一个 bug 修复，没有开关：只要 mod 启用就一直生效。
  诊断：控制台输入 gtpdiag。
]]

local GTP = {}

local LOG_LIMIT = 16

local prev_state = nil
local events = {}
local stats = {
  wipes = 0,
  restored_rooms = 0,
  last_result = "尚未触发",
}

local function push_event(text)
  events[#events + 1] = text
  while #events > LOG_LIMIT do
    table.remove(events, 1)
  end
end

local function out(message)
  Isaac.ConsoleOutput("[GoodTripPlus] " .. message .. "\n")
  Isaac.DebugString("[GoodTripPlus] " .. message)
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

-- 这个房间是否「已探索过」（= 玩家进去过）。
-- 用**当前存活**的 RoomDescriptor.VisitedCount 判定，而不是 MinimapAPI 房间对象上的
-- Visited 缓存：rewind 会把「你刚离开的那个房间」回滚成未进入过的状态（VisitedCount = 0），
-- 此时它在地图上只是一块未探索的深色格子（因为它是当前房间的邻居，被 MinimapAPI 用
-- DisplayFlags |= 5 亮了格子，所以 bit4 也在，图标本来会被画出来），
-- 但它此刻确实没有任何已知的掉落物，不应该贴回任何图标。
local function is_room_explored(room)
  local descriptor = room.Descriptor
  if descriptor then
    return descriptor.VisitedCount > 0
  end
  return room:IsVisited()
end

-- 把快照贴回当前为空的房间，返回 (被填充的房间数, 因未探索而跳过的房间数)。
local function restore_item_icons(icons_by_dimension)
  if not MinimapAPI or not MinimapAPI.Levels then
    return 0, 0
  end
  local restored_rooms = 0
  local skipped_unexplored = 0
  for dimension, rooms in pairs(MinimapAPI.Levels) do
    local dimension_icons = icons_by_dimension[dimension]
    if dimension_icons then
      for _, room in ipairs(rooms) do
        local descriptor = room.Descriptor
        local list_index = descriptor and descriptor.ListIndex
        local icons = list_index and dimension_icons[list_index]
        if icons and (not room.ItemIcons or #room.ItemIcons == 0) then
          if is_room_explored(room) then
            room.ItemIcons = copy_icons(icons)
            restored_rooms = restored_rooms + 1
          else
            skipped_unexplored = skipped_unexplored + 1
          end
        end
      end
    end
  end
  return restored_rooms, skipped_unexplored
end

-- 读取当前帧的地图状态：
--   identity 层身份
--   arrays   各维度的房间数组本身（用来识别 MinimapAPI 是否重建过地图）
--   icons    各维度「有图标的房间」的图标副本，键是 Descriptor.ListIndex
-- 这里做的是真正的深拷贝，所以即使 MinimapAPI 之后原地改动也不会污染快照。
local function read_state()
  local state = {
    identity = level_identity(),
    arrays = {},
    icons = {},
  }
  if MinimapAPI and MinimapAPI.Levels then
    for dimension, rooms in pairs(MinimapAPI.Levels) do
      state.arrays[dimension] = rooms
      local dimension_icons = {}
      for _, room in ipairs(rooms) do
        local descriptor = room.Descriptor
        local icons = room.ItemIcons
        if descriptor and descriptor.ListIndex and icons and #icons > 0 then
          dimension_icons[descriptor.ListIndex] = copy_icons(icons)
        end
      end
      state.icons[dimension] = dimension_icons
    end
  end
  return state
end

-- 统计「上一帧有图标、这一帧变空」的房间数，以及被整个换掉的房间数组数量。
local function diff_states(previous, current)
  local rebuilt_dimensions = 0
  for dimension, rooms in pairs(current.arrays) do
    if previous.arrays[dimension] and previous.arrays[dimension] ~= rooms then
      rebuilt_dimensions = rebuilt_dimensions + 1
    end
  end

  local lost_rooms = 0
  for dimension, dimension_icons in pairs(previous.icons) do
    for list_index in pairs(dimension_icons) do
      local now = current.icons[dimension] and current.icons[dimension][list_index]
      if not now or #now == 0 then
        lost_rooms = lost_rooms + 1
      end
    end
  end

  -- 一次合法拾取最多只能让 1 个房间变空，所以：
  --   >= 2 个房间同时变空            → 一定是整批清空
  --   地图被重建且至少丢了 1 个房间  → 也是整批清空
  local is_wipe = lost_rooms >= 2 or (rebuilt_dimensions > 0 and lost_rooms >= 1)
  return is_wipe, rebuilt_dimensions, lost_rooms
end

gt:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
  local current = read_state()

  if prev_state then
    local is_wipe, rebuilt_dimensions, lost_rooms = diff_states(prev_state, current)
    if is_wipe then
      local same_floor = prev_state.identity ~= nil and prev_state.identity == current.identity
      push_event(string.format("frame=%d wipe: rebuilt=%d lost=%d sameFloor=%s",
        Game():GetFrameCount(), rebuilt_dimensions, lost_rooms, tostring(same_floor)))
      if not same_floor then
        push_event("  prevIdentity=" .. tostring(prev_state.identity))
        push_event("  curIdentity =" .. tostring(current.identity))
      end

      if same_floor then
        local restored_rooms, skipped_unexplored = restore_item_icons(prev_state.icons)
        stats.wipes = stats.wipes + 1
        stats.restored_rooms = stats.restored_rooms + restored_rooms
        stats.last_result = "frame=" .. Game():GetFrameCount() ..
          " 恢复 " .. restored_rooms .. " 个房间，跳过 " .. skipped_unexplored .. " 个未探索房间"
        push_event("RESTORE " .. restored_rooms .. " rooms, skip " ..
          skipped_unexplored .. " unexplored")
        out("rewind fix: 检测到整批图标丢失，已恢复 " .. restored_rooms ..
          " 个房间的图标（跳过 " .. skipped_unexplored .. " 个未探索房间）")
        current = read_state() -- 重新读，避免下一帧拿恢复前的数据做比较
      else
        stats.last_result = "检测到清空，但判定为换层/首次载入，未恢复"
      end
    end
  end

  prev_state = current
end)

-- 以下三个回调只用于诊断，记录「哪个回调按什么顺序触发了」。
gt:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function()
  push_event("frame=" .. Game():GetFrameCount() .. " POST_NEW_LEVEL")
end)

gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
  push_event("frame=" .. Game():GetFrameCount() .. " POST_NEW_ROOM")
end)

gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(_, is_continued)
  push_event("frame=" .. Game():GetFrameCount() ..
    " POST_GAME_STARTED continued=" .. tostring(is_continued))
  if gt.DebugMod then
    out("POST_GAME_STARTED continued=" .. tostring(is_continued))
  end
end)

-- 诊断指令：控制台输入 gtpdiag
-- 注意：MC_EXECUTE_CMD 的回调必须返回字符串（或 nil），返回 boolean 会被游戏警告。
gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
  if not command or command:lower() ~= "gtpdiag" then
    return
  end
  -- 诊断自身出错也不能拖垮控制台命令：整段包一层 pcall
  local diag_ok, diag_err = pcall(function()

  out("REWIND FIX DIAGNOSTICS BEGIN")
  out("identity=" .. tostring(level_identity()))
  out("repentogon=" .. tostring(REPENTOGON) ..
    " stageAPI=" .. tostring(StageAPI ~= nil and StageAPI.Loaded ~= nil and StageAPI.Loaded ~= false) ..
    " postHudRender=" .. tostring(ModCallbacks.MC_POST_HUD_RENDER ~= nil))
  out("renderCallback.cursor=" .. tostring(gt.renderCallback) ..
    " markers=" .. tostring(gt.markerRenderCallback))
  out("wipes=" .. stats.wipes .. " restoredRooms=" .. stats.restored_rooms)
  out("lastResult=" .. tostring(stats.last_result))
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
  else
    out("MinimapAPI Levels unavailable")
  end
  out("RECENT EVENTS (oldest first):")
  for _, event in ipairs(events) do
    out("  " .. event)
  end
  out("REWIND FIX DIAGNOSTICS END")
  end)
  if not diag_ok then
    out("REWIND FIX DIAGNOSTICS ERROR: " .. tostring(diag_err))
  end
end)

return GTP
