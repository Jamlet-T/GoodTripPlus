--[[
  GoodTripPlus - 地图边界房间高亮（MCM: Show Map Bounds，默认开启）
  ============================================================

  需求（2026-10-03）
  -----------------
  以撒的地图上限是 13×13（初始房为中心，上下左右各 6 格）。把「贴着地图边界的
  房间、靠边界的那条边」高亮出来，玩家一眼就能看出「这一侧外面已经没有房间了」——
  找隐藏房、判断该往哪探索都用得上。不是画一整圈边框，只画已有房间贴着边的那条边。

  实现要点
  --------
  * **边界判定**：网格 13×13，格号 gid → col = gid % 13、row = floor(gid / 13)；
    col == 0 / 12 或 row == 0 / 12 即贴边，角房两条边都画。
  * **大房间占多格**：用本文件的 SAFE_SHAPE_OFFSETS（形状 → 各占据格相对
    SafeGridIndex 的偏移）逐格画。⚠️ 锚点坑：SafeGridIndex 并不总是包围盒
    左上角——ROOMSHAPE_LTL（缺左上角）的 SafeGridIndex 是「最靠左上那个
    真实格」（= 包围盒左上 + 1），所以**不能**直接用 delver/geometry.lua 的
    SHAPE_OFFSETS（那张表锚点是 GridIndex=包围盒左上，正确用法见 delver/map.lua）；
    否则 LTL 三格整体右移一列、跨行回绕画到别的格（2026-10-04 用户实测：
    L 形房贴边只显示一格的边界线）。本表 LTL={0,12,13} 与 MinimapAPI 的
    RoomShapePositions（data.lua，锚点同为 SafeGridIndex）逐项核对过。
    性能：房间形状整层不变，**不要**每帧 GetRoomByIdx 逐格回验（曾这么写过，
    每帧约 360 次引擎调用，用户实测掉帧）；draw_cell 里也只对贴边格算投影。
  * **只画已探索的房间**：`RoomDescriptor.DisplayFlags & 1`（游戏自己的「这个房间
    已在地图上显示」标志），所以不会剧透还没探索的区域。
  * **坐标**：直接用 `gt:gid_to_rtmap_pos()` —— 传送光标与隐藏房标记用的同一套投影
    （逐项复刻 MinimapAPI 的布局数学，含镜像世界的负缩放），因此天然对齐。
  * **画线**：Isaac 的 Lua 没有画矩形的 API（本机所有 mod 都靠 Sprite），所以用一张
    8×8 纯白贴图 `resources/gfx/goodtripplus/bounds.png`（配 `bounds.anm2`）按需要的
    宽高缩放后绘制，颜色/透明度由 sprite.Color 控制。
  * **显示时机与隐藏房候选标记完全一致**（2026-10-03 用户要求）：
      - 淡入用 delver/render.lua 的**同一份**帧计数（`get_fade()`），节奏与标记一模一样；
        **松开地图键立即消失**、不做淡出（2026-10-03 用户要求）；
      - 逐条对齐它的显示条件：层被忽略（回溯线 / STAGE8 / 贪婪 / 镜像外维度）、
        **迷失诅咒**、房间不在网格上、没按住地图键、MinimapAPI 战斗隐藏 —— 任一命中都不画。

  开关：MCM → GoodTripPlus → 「显示地图边界」，或 gtconfig.lua 里
  gt.ShowMapBounds = false（默认开）。注意这个开关只管边界高亮自己，
  上面的「显示条件」与标记是共用的。
]]--

local state = require("scripts.delver.state")
local delver_render = require("scripts.delver.render")

local M = {}

-- 网格尺寸：以撒地图 13×13
local COLS, ROWS = 13, 13

-- 格子尺寸，与 gt:gid_to_rtmap_pos() 的间距保持一致（横 17px、纵 15px）
local CELL_W, CELL_H = 17, 15

-- 边线：粗细 2px；长度比格子略短一点，留出空隙看着更利落
local LINE_T = 2
local LINE_W = CELL_W - 2
local LINE_H = CELL_H - 2

-- 淡入与显示条件全部交给 delver/render.lua 的同一份计数（见文件头的说明），
-- 这里只保留基础透明度。
local BASE_ALPHA = 0.85

local line_sprite = Sprite()
local sprite_ok = pcall(function()
  line_sprite:Load("gfx/goodtripplus/bounds.anm2", true)
  line_sprite:SetFrame(line_sprite:GetDefaultAnimation(), 0)
end)
if not sprite_ok then
  Isaac.DebugString("[GoodTripPlus][mapBounds] bounds.anm2 加载失败，边界高亮不可用")
end

-- 画一条线：中心点 (cx, cy)、尺寸 w×h
local function draw_line(cx, cy, w, h)
  line_sprite.Scale = Vector(w / 8, h / 8)
  line_sprite:Render(Vector(cx - w / 2, cy - h / 2))
end

-- 房间形状 → 各占据格相对 SafeGridIndex 的格号偏移。
-- ⚠️ 锚点是 SafeGridIndex，**不要**直接用 delver/geometry.lua 的 SHAPE_OFFSETS
-- （那张表锚点是 GridIndex=包围盒左上角）。对除 LTL 外的所有形状两者相等；
-- 唯独 ROOMSHAPE_LTL（缺左上角）的 SafeGridIndex = 包围盒左上 + 1，
-- 本表 LTL = {0, 12, 13} 是按 MinimapAPI 的 RoomShapePositions
-- （data.lua：LTL = {(0,0),(-1,1),(0,1)}，锚点同为 SafeGridIndex）换算来的。
-- 用表而不用 GetRoomByIdx 逐格回验：房间形状整层不变，每帧 360 次引擎调用
-- 是纯浪费（2026-10-04 用户实测掉帧）。
local SAFE_SHAPE_OFFSETS = {
  [RoomShape.ROOMSHAPE_1x1] = { 0 },
  [RoomShape.ROOMSHAPE_IH]  = { 0 },
  [RoomShape.ROOMSHAPE_IV]  = { 0 },
  [RoomShape.ROOMSHAPE_1x2] = { 0, COLS },
  [RoomShape.ROOMSHAPE_IIV] = { 0, COLS },
  [RoomShape.ROOMSHAPE_2x1] = { 0, 1 },
  [RoomShape.ROOMSHAPE_IIH] = { 0, 1 },
  [RoomShape.ROOMSHAPE_2x2] = { 0, 1, COLS, COLS + 1 },
  [RoomShape.ROOMSHAPE_LTL] = { 0, COLS - 1, COLS },
  [RoomShape.ROOMSHAPE_LTR] = { 0, COLS, COLS + 1 },
  [RoomShape.ROOMSHAPE_LBL] = { 0, 1, COLS + 1 },
  [RoomShape.ROOMSHAPE_LBR] = { 0, 1, COLS },
}

-- 单个格子：贴哪条边就画哪条（角房两条）
local function draw_cell(gid)
  local col = gid % COLS
  local row = math.floor(gid / COLS)
  if row < 0 or row >= ROWS then
    return
  end
  local left, right = col == 0, col == COLS - 1
  local top, bottom = row == 0, row == ROWS - 1
  if not (left or right or top or bottom) then
    return -- 内部格：不算投影（gid_to_rtmap_pos 里有全图角房扫描，不便宜）
  end
  local pos = gt:gid_to_rtmap_pos(gid)
  if left then
    draw_line(pos.X - CELL_W / 2, pos.Y, LINE_T, LINE_H)
  elseif right then
    draw_line(pos.X + CELL_W / 2, pos.Y, LINE_T, LINE_H)
  end
  if top then
    draw_line(pos.X, pos.Y - CELL_H / 2, LINE_W, LINE_T)
  elseif bottom then
    draw_line(pos.X, pos.Y + CELL_H / 2, LINE_W, LINE_T)
  end
end

function M.render()
  if not sprite_ok or not gt:get_config_bool("ShowMapBounds", true) then
    return
  end
  -- 下面这组判据与隐藏房候选标记（delver/render.lua 的 M.render）逐条对齐：
  -- 层被忽略（回溯线 / STAGE8 / 贪婪模式 / 镜像外维度）、迷失诅咒、房间不在网格上
  if state.is_ignored() then
    return
  end
  if state.is_lost_cursed() or state.is_off_grid() then
    return
  end
  -- 淡入系数：与标记共用同一份计数（按住地图键才 > 0）
  local fade = delver_render.get_fade and delver_render.get_fade() or 0
  if fade <= 0 then
    return
  end
  if not MinimapAPI then
    return
  end
  -- MinimapAPI 战斗隐藏（HideInCombat / Mega Satan / Beast / boss 开场过场等）生效时，
  -- 地图整块不画，我们也不能画，否则线会浮在空屏上
  if delver_render.minimapapi_hides_map and delver_render.minimapapi_hides_map() then
    return
  end

  line_sprite.Color = Color(1, 1, 1, BASE_ALPHA * fade, 0, 0, 0)

  local level = Game():GetLevel()
  if not level then
    return
  end
  local rooms = level:GetRooms()
  if not rooms then
    return
  end
  for i = 0, rooms.Size - 1 do
    local rd = rooms:Get(i)
    if rd and rd.Data and (rd.DisplayFlags & 1) ~= 0 then
      for _, off in ipairs(SAFE_SHAPE_OFFSETS[rd.Data.Shape] or { 0 }) do
        draw_cell(rd.SafeGridIndex + off)
      end
    end
  end
end

-- MCM 开关（默认开；显示类功能，与隐藏房标记一样给开关）
--
-- ⚠️ 必须只注册一次：MCM 的 `AddSetting` 是**无脑 append**、不按键去重
-- （`ModConfigMenu.MenuData` 整局只在 MCM 加载时建一次、中途不清空），
-- 而 `MC_POST_GAME_STARTED` **每次 rewind 都会再触发一次**
-- （rewind 触发 LoadSaveTable 重建地图，gtp_rewindfix 就是靠这个钩子做的）。
-- 所以不加上面这个 once 标记的话，用几次 rewind 配置菜单里就多几份重复项。
-- 与 gtrep.lua 注册核心传送选项时用的 `mcm_registered` 是同一个套路。
local mcm_registered = false
gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
  if mcm_registered or not ModConfigMenu then
    return -- 还没注册过、且 MCM 已在则继续；MCM 若加载晚了下局再试
  end
  mcm_registered = true
  local zh = type(Options.Language) == "string"
    and Options.Language:lower():sub(1, 2) == "zh"
  ModConfigMenu.AddBooleanSetting(
    "GoodTripPlus", nil,
    "ShowMapBounds",
    true,
    zh and "显示地图边界" or "Show Map Bounds",
    zh and "按住地图键时，把贴着地图边界（13×13 最外圈）的房间、靠边的那条边高亮出来，方便判断哪一侧外面已经没有房间了。只画已经探索到的房间。默认开启。"
       or "While holding the map key, highlight the outer edge of rooms that sit on the 13x13 map border, so you can tell which side has no more rooms left. Only explored rooms are drawn. Default: enabled"
  )
end)

-- 绘制层：与隐藏房标记同一个回调，但优先级再早 1，让标记与光标压在线之上
do
  local is_repentance = REPENTANCE or REPENTANCE_PLUS
  local bounds_priority = ((CallbackPriority and CallbackPriority.LATE) or 1000) - 2

  if REPENTOGON then
    gt:AddPriorityCallback(ModCallbacks.MC_POST_HUD_RENDER, bounds_priority, M.render)
    gt.boundsRenderCallback = "MC_POST_HUD_RENDER (REPENTOGON)"
  elseif StageAPI and StageAPI.Loaded then
    StageAPI.AddCallback("GoodTripPlus", "POST_HUD_RENDER", 0.4, M.render)
    gt.boundsRenderCallback = "StageAPI POST_HUD_RENDER"
  elseif is_repentance then
    gt:AddPriorityCallback(ModCallbacks.MC_POST_RENDER, bounds_priority, M.render)
    gt.boundsRenderCallback = "MC_POST_RENDER (priority)"
  else
    gt:AddCallback(ModCallbacks.MC_POST_RENDER, M.render)
    gt.boundsRenderCallback = "MC_POST_RENDER (plain)"
  end
end

return M
