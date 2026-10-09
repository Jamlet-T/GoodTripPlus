gt = RegisterMod("GoodTripPlus", 1)
local console_output = require("scripts.gtp_console").write
-- 版本号：与 metadata.xml 保持一致。log.txt 里靠这一行确认「实际加载的是哪一版」，
-- 排查「改了没生效 / 没重启」时是第一手证据。
gt.VERSION = "2.5.10"
-- 部署工具生成的源码指纹；开发源码本身无需维护第二个版本号。
local build_ok, build = pcall(require, "scripts.gtp_build")
gt.BUILD = build_ok and type(build) == "string" and build or "source"
pcall(function()
  console_output("[GoodTripPlus] v" .. gt.VERSION ..
    " loaded (console command: gtpdiag)\n")
  Isaac.DebugString("[GoodTripPlus] v" .. gt.VERSION .. " loaded")
  Isaac.DebugString("[GoodTripPlus] build=" .. gt.BUILD)
end)
-------------------------------------------
local player = Isaac.GetPlayer(0)
local level = Game():GetLevel()
local stage = level:GetStage()
local curse = 0
local room = Game():GetRoom()
local crd = level:GetCurrentRoomDesc()
local last_crd
local crid = crd.SafeGridIndex
---
local sfx = SFXManager()
local cursor = Sprite()
cursor:Load("gfx/ui/cursor.anm2", true)
cursor:SetFrame("Idle", 0)
---
local mouse_pressed = {false, false, false, false, false}
local key = {ButtonAction.ACTION_SHOOTUP,ButtonAction.ACTION_SHOOTLEFT,ButtonAction.ACTION_SHOOTRIGHT,ButtonAction.ACTION_SHOOTDOWN}
local cursor_arrow_keys = {'KEY_UP', 'KEY_LEFT', 'KEY_RIGHT', 'KEY_DOWN'}
local dir = {Vector(0, -1),Vector(-1, 0),Vector(1, 0),Vector(0, 1)}
local scpos = Vector(0, 0)
local grid_room = {}
local ltroom = Vector(6, 6)
local rbroom = Vector(6, 6)
---
local tele_maze = false
local tele_door_slot = -1 --the door a trip means to arrive by
local secret_pre_room_id = {}
local prep_alarm = false
local testnum = 0
local n_room_num = 0
local mmp_ctrl = false
local mmp_ctrl_pos = Vector(0, 0)
local mmp_highlight_gid = nil
-- 光标「出生后还没被玩家挪动过」：这个状态下**每帧**都把它贴回当前房间
-- （跨层 / R 重开 / rewind 后地图重绘都能自愈，和隐藏房标记同一套做法）。
-- 玩家一按方向键就置 true，之后完全照旧 —— 光标放哪儿待在哪儿。
-- 已知代价（2026-10-05 接受）：呼出后还没碰过光标时，走路换房它会跟着你走。
local mmp_ctrl_moved = false
local mouse_cursor = require("scripts.gtp_mouse").new()
local mouse_probe = require("scripts.gtp_mouseprobe").new(function(line)
  Isaac.DebugString(line)
end, function()
  local arrows = '-'
  if Keyboard and Input.IsButtonPressed then
    arrows = ''
    for _, button in ipairs({Keyboard.KEY_UP, Keyboard.KEY_LEFT, Keyboard.KEY_RIGHT, Keyboard.KEY_DOWN}) do
      arrows = arrows .. (Input.IsButtonPressed(button, 0) and '1' or '0')
    end
  end
  return string.format('frame=%s controller=%s arrows=%s mouseControl=%s minimapMouseTeleport=%s',
    tostring(Game():GetFrameCount()), tostring(player.ControllerIndex), arrows,
    tostring(Options and Options.MouseControl),
    tostring(MinimapAPI and MinimapAPI:GetConfig('MouseTeleport') or false))
end)
local mouse_hit = require("scripts.gtp_mousehit")
local draw_room_highlight = require("scripts.gtp_roomhighlight")
-- 光标淡入（2026-10-05 用户要求：与隐藏房候选标记 / 地图边界高亮同一节奏）：
-- 按住地图键后先等几帧、再渐显，免得光标在 MinimapAPI 的大地图还没就位时就先冒出来
-- （2.1.2 修好「重开时光标贴回当前房间」之后尤其明显 —— 那时地图刚重建，光标已经画了）。
-- 计数口径刻意与 delver/render.lua 的 tab_hold_cnt 一致（THRESHOLD=3 / MAX=9：
-- 第 4 帧起可见，alpha 由 1/9 渐到 1，约 0.2 秒）。**那边改了这边要一起改。**
-- 为什么不直接复用 delver 的 get_fade()：它在「被忽略的层」（回溯线 / STAGE8 / 贪婪模式 /
-- 镜像外维度）恒为 0，而传送光标在这些层必须照常工作（那些层只是**标记**没意义）。
local CURSOR_FADE_MIN = -3
local CURSOR_FADE_MAX = 9
local mmp_ctrl_fade = CURSOR_FADE_MIN

-- 隐藏房现场诊断的去重表（按「层 + 目标格」，new_level 清空）
local secret_diag_logged = {}
-- 上一次手动 dump 的帧号（F4 连按限流，避免刷屏）
local last_diag_frame = -1000
-- 注：牌意解读 / 天堂阶梯 的传送禁令早期版本靠「本层是否离开过初始房间」的状态判断，
-- 2026-10-03 起改成直接看房间里有没有它们的入口实体（gt:has_start_room_entrance），
-- 不再需要任何层/房间状态。
-- ===== 门图与邻接基础设施：忠实移植自 GoodTrip [Fixed]（scripts/floor.lua）=====
-- door graph, learned one room at a time: grid adjacency alone cannot tell a
-- doorway from a secret room's unbombed wall. Per dimension: the mirror world
-- reuses the same grid numbers for different rooms.
local DoorGraph = require("scripts.gtp_doorgraph")
local door_state = DoorGraph.new()
--curse-room door spikes seen from outside / inside; Flat File strips only the
--side it was used on, so the two are kept apart
local curse_bare_outside, curse_bare_inside = {}, {}
require("scripts.gtp_doors")(gt, {
  state = door_state,
  get_aux = function()
    return { bare_out = curse_bare_outside, bare_in = curse_bare_inside, pre = secret_pre_room_id }
  end,
  reset_aux = function()
    curse_bare_outside, curse_bare_inside, secret_pre_room_id = {}, {}, {}
  end,
  set_aux = function(state)
    curse_bare_outside, curse_bare_inside, secret_pre_room_id = state.bare_out, state.bare_in, state.pre
  end,
})
--each room shape's cell offsets beyond the anchor's four direct neighbours
--（floor.lua 的 neighlut 原样；下标 = RoomDescriptor.Data.Shape）
local neighlut = {
    {-1, 1, -13, 13},
    {-1, 1},
    {-13, 13},
    {-1, 1, -1+13, 1+13, -13, 13+13},
    {-13, 13+13},
    {-1, 2, -13, 13, -13+1, 13+1},
    {-1, 2},
    {-1, 2, -1+13, 2+13, -13, 13+13, -13+1, 13+13+1},
    {-1, 1, -13, -2+13, 1+13, 13+13-1, 13+13},
    {-13, -1, 1, -1+13, 2+13, 13+13, 13+13+1},
    {-13, -13+1, -1, 2, 13, 13+2, 13+13+1},
    {-13, -13+1, -1, 2, 13-1, 13+1, 13+13},
}
--每个房间的邻居列表（floor.lua get_room_neighbours；get_grid_room 之后重建）
local room_neighbours = {}

gt.DebugMod = false
gt.FastRestartEnable = false
-- 传送过场：1 = 立即出现 / 2 = 淡入淡出 / 3 = 传送白闪（见 gt:get_teleport_transition()）。
-- 取代了原来的两个布尔项 FastTransition + TeleportAnimation（2026-10-05 用户要求做成三选一，
-- 默认 2 = 淡入淡出；上游 GoodTrip [Fixed] 也把这两个效果放在 MCM 里）。
gt.TeleportTransition = 2
-- 注：迷失诅咒下是否禁用传送**已不再由我们的配置项控制**（2026-10-05 用户要求）——
-- 改为跟随 MinimapAPI 的 OverrideLost（其菜单里的 "Display During Curse"），见 gt:curse_map_visible()。
-- 这是对 GoodTrip [Fixed] 的第 3 处语义偏离（Fixed 是独立的 FollowCurseOfLost 开关）。
-- 传送范围（本项目合并原 Fixed 的 AllowNeighborRoom + AllowAnyRoom 两项）：
--   1 = 任意房间（原 AllowAnyRoom 开）
--   2 = 相邻房间（原默认：AllowNeighborRoom 开、AllowAnyRoom 关）
--   3 = 已探索房间（原 AllowNeighborRoom 关、AllowAnyRoom 关）
gt.TravelMode = 2
gt.FairTripPath = true
-- 默认改为开：偏离 Fixed 的默认关（2026-10-04 用户决定）
gt.ArriveAtDoor = true
gt.FairTripTime = false
gt.HighlightCursorRoom = true
gt.CursorGridStep = false
gt.MouseTeleport = true
gt.ShowSecretMarkers = true
local _, err = pcall(require, "gtconfig")
----
-- 调试模式不再是一次性快照：改成 gt:is_debug() 每帧实时读（MCM 开关改了立刻生效，不用重启）。
local fastrestartenable = gt.FastRestartEnable
local tele_cd = 0
-------------------------------
function gt:check_pos_en_box(pos,ltpos,rbpos)
  if pos.X > ltpos.X and pos.X < rbpos.X and pos.Y > ltpos.Y and pos.Y < rbpos.Y then
    return true
  else
    return false
  end
end
--
function gt:IsMouseBtnTriggered(m)
    if Input.IsMouseBtnPressed(m) then
      if not mouse_pressed[m+1] then
        mouse_pressed[m+1] = true
        return true
      end
    else
      mouse_pressed[m+1] = false
    end
    return false
end
--
function gt:check_room_open()
    local door = nil
    for i =0, 7 do
      door = room:GetDoor(i)
      if door then
        if door:IsOpen() then
          return true
        end
      end
    end
    return false
end
--
-- ===== 以下准入与传送判定：忠实移植自 GoodTrip [Fixed]（scripts/rules.lua）=====
--（floor.lua door_graph/sweep_doors/linked：门图，一格一格学出来）
local function door_graph()
  return gt:get_door_graph()
end

-- 门扫描、隐藏房分类和门图读写：scripts/gtp_doors.lua。
--may a trip step between these rooms? A passage seen from either end: yes. A
--swept room saying nothing: no. Neither swept (mod loaded mid-run): grid adjacency stands.
-- **严格版**：只在门图里**真的学到过这条边**时才算连通 —— 不吃下面的几何兜底。
-- 用途：判定的「最后一跳」（相邻豁免）必须走一扇我们**亲眼见过能过**的门。
-- ⚠️ 2026-10-06 实测（真机日志 + 代码共同证明）：继续存档 / rewind 会清空我们的门图，
-- 却保留游戏侧的「已访问」状态 —— 于是「访问过但本次没重扫」的房间既 swept=false 又
-- VisitedCount>0，兜底 `not (swept[a] or swept[b])` 就把它们当成与目标相连，
-- 门锁着的宝藏房 / 街机厅因此能被传进去（links=none 却 ③ 放行，只有兜底这一条路）。
-- 网格步进方向 -> 那一侧的门槽位掩码（DoorSlotFlag：LEFT0=1<<0, UP0=1<<1, RIGHT0=1<<2,
-- DOWN0=1<<3, LEFT1=1<<4 …）。用于判断「这一侧配置上有没有门」。
function gt:side_door_mask(step)
  if step == -1 then return 1 | 16            -- LEFT（slot 0 / 4）
  elseif step == 1 then return 4 | 64         -- RIGHT（slot 2 / 6）
  elseif step == -13 then return 2 | 32       -- UP（slot 1 / 5）
  elseif step == 13 then return 8 | 128       -- DOWN（slot 3 / 7）
  end
  return nil
end

-- (a,b) 之间**配置上**有没有门（不看锁没锁）—— 用来区分「隔墙相邻」与「有门连通」。
-- 读 RoomConfigRoom.Doors（官方文档：位掩码，由 DoorSlotFlag 构成），两面都要有门才算。
-- ⚠️ 字段读不到（本 API 版本没暴露 / 返回非数字）时**一律返回 false** —— 宁可保守拦掉，
-- 也不要凭猜测放行（这就是「隔墙也能传进去」那个洞的来源）。
function gt:has_door_between(a, b)
  local cell, step = gt:touching_cell(a, b)
  if not cell or not step then return false end
  local ra, rb = grid_room[a], grid_room[b]
  local da = ra and ra.Data and ra.Data.Doors
  local db = rb and rb.Data and rb.Data.Doors
  if type(da) ~= "number" or type(db) ~= "number" then return false end
  local m, opp = gt:side_door_mask(step), gt:side_door_mask(-step)
  if not m or not opp then return false end
  return (da & m) ~= 0 and (db & opp) ~= 0
end

function gt:has_known_passage(a, b)
  local link = door_graph()
  return link[a] ~= nil and link[a][b] ~= nil
end

function gt:rooms_linked(a, b)
    local link, swept = door_graph()
    if link[a] and link[a][b] ~= nil then
      return true
    end
    return not (swept[a] or swept[b])
end

--（floor.lua get_room_neighbours：由格子邻接推导房间级邻接，大房间/L 形天然覆盖）
function gt:get_room_neighbours()
    room_neighbours = {}
    local all_room = level:GetRooms()
    for i = 0, all_room.Size do
      local des = all_room:Get(i)
      if des then
        room_neighbours[des.SafeGridIndex] = {
          Descriptor = des,
          Neighbors = {}
        }
      end
    end
    local offsets = {-13, 13, -1, 1}
    for _, r in pairs(room_neighbours) do
      local safeIndex = r.Descriptor.SafeGridIndex
      for gridIndex, cellRoom in pairs(grid_room) do
        if cellRoom.SafeGridIndex == safeIndex then
          for _, offset in ipairs(offsets) do
              --column guard, as in check_neigh_connected
              local wrapped = (offset == -1 and gridIndex % 13 == 0)
                           or (offset == 1 and gridIndex % 13 == 12)
              local other = not wrapped and grid_room[gridIndex + offset] or nil
              if other and other.SafeGridIndex ~= safeIndex then
                  r.Neighbors[other.SafeGridIndex] = true
              end
          end
        end
      end
    end
    for _, r in pairs(room_neighbours) do
      local list = {}
      for id in pairs(r.Neighbors) do
        list[#list + 1] = id
      end
      r.Neighbors = list
    end
end

-- 注：这里原来有一份「已显示但未探索目标的类型白名单」（Fixed 原逻辑：
-- 只放普通房 1 / boss 5 / 小 boss 6 / 献祭 13，另加红钥匙房、隐藏房、镜像世界与
-- 一层的水层商店宝箱房）。它已于 2026-10-06 **整体删除**（用户决定，原计划排在步 2，
-- 因实测报出「门已用钥匙打开、还没进去过的商店/宝藏房/星象房/挑战房传不进去」而提前）：
--
--   删它的理由：恶魔房/天使房/Boss Rush/黑市/贪婪出口本来就不会显示在地图上，
--   「目标必须已显示」这条已经排除它们，白名单对它们是重复劳动；而副作用是把
--   「门已开着、能走进去」的房间也拒了（二层以后的商店、已解锁的图书馆/骰子房/街机厅）。
--   正确的窗口应该是**实际通路**：见 gtp_travel 的 gt:door_is_passage —— 门锁着不算通路，
--   解锁之后才算。安全性不再依赖房间类型，而是「那扇门现在能不能走」。
--
-- 于是「未探索的相邻房能不能传」现在只由 ③ range 段决定：目标已显示 + 旁边有
-- 「已显示 + 已探索 + 已清」的房 + 两者之间有**实际通路**。
--
--may I go there: the predicates a trip is checked against, the reachable set,
--the fair distance, the door a walk would have come in by.
function gt:check_neigh_connected(trd, cond)
    local tid = trd.SafeGridIndex
    if (trd.DisplayFlags & 1) ~= 0 then
      local function check_grid(off)
        local id = tid + off
        if id < 0 or id > 168 then
          return false
        end
        --column guard: a sideways offset must not wrap to the neighbouring row
        local dcol = ((off % 13) + 6) % 13 - 6
        if (tid % 13) + dcol ~= id % 13 then
          return false
        end
        local rd = grid_room[id]
        return rd ~= nil and cond(rd)
      end
      local near_room = {check_grid(-13), check_grid(13), check_grid(-1), check_grid(1)}
      if stage == 12 and trd.Data.Type == 5 and trd.Data.Shape > 3 then
        --void bossrooms--type4=1x2/type6=2x1/type8=2x2=Delirium
        if (near_room[1] and near_room[4])
          or (near_room[2] and near_room[3])
          or (trd.Data.Shape == 6 and (near_room[1] or near_room[4]))
          or (trd.Data.Shape == 4 and (near_room[2] or near_room[3]))
        then
          return true
        end
      else
        if near_room[1] or near_room[4] or near_room[2] or near_room[3] then
          return true
        end
        for _, off in ipairs(neighlut[trd.Data.Shape]) do
            if check_grid(off) then
                return true
            end
        end
      end
    end
    return false
end

-- 门图生命周期与持久化适配：scripts/gtp_doors.lua。
function gt:get_reachable_rooms()
    --flood from the current room through visited+cleared rooms; each step needs
    --a door too, else a secret room counts as a corridor on all four sides
    local start = crd.SafeGridIndex
    gt:sweep_doors() --a wall bombed since entering would still read as solid
    local reach = {[start] = true}
    local queue = {start}
    local head = 1
    while queue[head] do
      local cur = queue[head]
      head = head + 1
      local node = room_neighbours[cur]
      if node then
        for _, adj in ipairs(node.Neighbors) do
          local rd = grid_room[adj]
          if rd and not reach[adj] and rd.VisitedCount > 0 and rd.Clear
              and gt:rooms_linked(cur, adj) then
            reach[adj] = true
            queue[#queue + 1] = adj
          end
        end
      end
    end
    return reach
end

--the game's own landing ignores Direction (measured twice): it takes the wall of
--the cell handed over that faces the room left from, by the axis with the larger
--grid distance (a tie goes to the row), whatever door is there, an unbombed
--secret room's included, and with no door on that wall the lowest slot. Right
--only when the walk was straight; the landing below aims at the walk's door.
--route_parent: the step before the target on the shortest walk through walked rooms
function gt:route_parent(from, to)
    local parent = {[from] = from}
    local queue, head = {from}, 1
    while queue[head] do
      local cur = queue[head]
      head = head + 1
      if cur == to then break end
      local node = room_neighbours[cur]
      if node then
        for _, adj in ipairs(node.Neighbors) do
          local rd = grid_room[adj]
          --the target may be an uncleared neighbour: a landing, not a pass-through
          if rd and not parent[adj] and gt:rooms_linked(cur, adj)
              and (adj == to or (rd.VisitedCount > 0 and rd.Clear)) then
            parent[adj] = cur
            queue[#queue + 1] = adj
          end
        end
      end
    end
    local p = parent[to]
    return p ~= to and p or nil
end

--the target cell a walk from `from` would step into, and the grid step taken
--into it (-13 up, 13 down, -1 left, 1 right). Read off the grid, not the door
--sweep, so a room nobody has been inside yet answers too
function gt:touching_cell(from, to)
    local src, dst = grid_room[from], grid_room[to]
    if not (src and dst) then return nil end
    for cell, d in pairs(grid_room) do
      if d.ListIndex == src.ListIndex then
        local col = cell % 13
        for _, step in ipairs({ -13, 13, -1, 1 }) do
          if not ((step == -1 and col == 0) or (step == 1 and col == 12)) then --column guard
            local nd = grid_room[cell + step]
            if nd and nd.ListIndex == dst.ListIndex then return cell + step, step end
          end
        end
      end
    end
    return nil
end

--the cell to hand the transition, the room to leave from to make it stick, and
--the door slot to land at. The game reads the cell to pick among the doors on
--one wall, and the wall from the room the trip starts in; so next door the
--cell is enough, further off the trip must also start from the room the walk
--would have come from. The slot comes off the grid, never the door sweep, so a
--room nobody has stood in yet has one too: the side stepped in by names the
--wall, and which of a big room's two doors on that wall it is follows from the
--entered cell's row (left and right walls) or column (top and bottom) within
--the room, which is how the game numbers them for every shape, L included.
--No route to trace: no slot, and the game's own landing stands
function gt:landing_route(from, to)
    local cell, step = gt:touching_cell(from, to)
    local walked = nil
    if not cell then
      walked = gt:route_parent(from, to)
      if not walked then return nil, nil, -1 end
      cell, step = gt:touching_cell(walked, to)
      if not cell then return nil, walked, -1 end
    end
    local wall = ({ [1] = 0, [13] = 1, [-1] = 2, [-13] = 3 })[step]
    local top = grid_room[to].GridIndex
    local second = wall % 2 == 0 and (cell - top) // 13 or (cell - top) % 13
    return cell, walked, wall + 4 * second
end

--BFS distance through cleared rooms; any room connected to the target is the last hop
function gt:fair_trip(roomIndex, target)
    local grid_room, room_neighbours = grid_room, room_neighbours
    local startRoom = grid_room[roomIndex]
    local targetRoom = grid_room[target]
    if not startRoom or not targetRoom then
        return 0
    end
    local safeTarget = targetRoom.SafeGridIndex
    local visited = {[startRoom.SafeGridIndex] = true}
    local queue = {{room = startRoom, dist = 0}}
    local head = 1
    while queue[head] do
        local cur = queue[head]
        head = head + 1
        local safeIndex = cur.room.SafeGridIndex
        if safeIndex == safeTarget and cur.room.Clear then
            return cur.dist
        end
        if gt:check_neigh_connected(targetRoom, function(rd)
            return rd.SafeGridIndex == safeIndex
                and (not gt:get_config_bool("FairTripPath", true) or gt:rooms_linked(safeIndex, safeTarget))
        end) then
            return cur.dist + 1
        end
        if cur.room.Clear then
            for _, adj in ipairs(room_neighbours[cur.room.SafeGridIndex].Neighbors) do
                local adj_dsc = grid_room[adj]
                local sid = adj_dsc.SafeGridIndex
                if not visited[sid]
                    and (not gt:get_config_bool("FairTripPath", true) or gt:rooms_linked(safeIndex, sid)) then
                    visited[sid] = true
                    queue[#queue+1] = {room = adj_dsc, dist = cur.dist + 1}
                end
            end
        end
    end
    return 999
end

-- 牌意解读 / 天堂阶梯 生成的「入口」实体（2026-10-03 按用户建议改成直接看实体）：
--   · 牌意解读（Card Reading，660）的彩色传送门：
--       ENTITY_EFFECT + EffectVariant.PORTAL_TELEPORT(161)
--       （subtype 编码目标 —— 1=boss 红、宝箱黄、隐藏蓝、商店绿；这里不细分）
--   · 天堂阶梯（Stairway，586）的高台阶：ENTITY_EFFECT + EffectVariant.TALL_LADDER(156)
-- 这两个实体**只在道具生成了入口的那个房间里存在，玩家一离开房间就随房间一起销毁** ——
-- 所以「房间里有没有这个实体」就是最直接、也最准的判据：不必再去判断哪间算初始房间、
-- 也不必记录本层有没有离开过（离开=实体没了=自动放行），而且天然覆盖回溯线（回溯线里
-- 门生成在「通往下一层的那个起始房间」，不是玩家进门的那间 boss 房）。
local START_ROOM_ENTRANCES = {
  [EffectVariant.PORTAL_TELEPORT] = true,
  [EffectVariant.TALL_LADDER] = true,
}

-- 房间里是否存在「离开就会消失的道具入口」
function gt:has_start_room_entrance()
    local r = Game():GetRoom()
    if not r then
      return false
    end
    local list = r:GetEntities()
    if not list then
      return false
    end
    for i = 0, list.Size - 1 do
      local e = list:Get(i)
      if e and e.Type == EntityType.ENTITY_EFFECT
          and START_ROOM_ENTRANCES[e.Variant] then
        return true
      end
    end
    return false
end

-- 持有「牌意解读 / 天堂阶梯」、且当前房间里真有一枚它们的入口实体时，禁止传送：
-- 这个入口就是这两个道具的核心效果，玩家一离开房间它就会消失，禁传送只是不让误触
-- 把它顶掉。离开房间后实体消失，禁令自动解除，不需要任何层/房间状态。
-- **常开、没有开关**（用户 2026-10-03 明确要求：这类保护不给可选配置）。
function gt:start_room_lock()
    -- 先说持有道具：房间里出现同名特效（例如玩家自己传送时的漩涡）时，
    -- 这一条能挡掉误判，也省下一次实体遍历。想纯按实体判定就把这段删掉。
    local p = player or Isaac.GetPlayer(0)
    -- ⚠️ 光判 nil 不够：开局初始化期间 / 过场里拿到的是「对象在、但还没就绪」的玩家，
    -- 直接 HasCollectible 会在原生层崩溃（2026-10-05 实测：POST_GAME_STARTED 期间调用即闪退两次）。
    -- 用 Exists() 兜底，任何调用时机都不会再把游戏带崩。
    if not p or not p:Exists() then
      return false
    end
    if not (p:HasCollectible(CollectibleType.COLLECTIBLE_CARD_READING)
        or p:HasCollectible(CollectibleType.COLLECTIBLE_STAIRWAY)) then
      return false
    end
    return gt:has_start_room_entrance()
end

-- 注：准入判定已于 2026-10-06 整体搬到 scripts/gtp_travel.lua
--（四段规则表 + 两个入口 gt:can_open_cursor / gt:can_travel_to）。
-- 原来的 gt:check_teleble 已删除 —— 呼出光标、房间高亮、松手传送现在共用同一套规则，
-- 不再有跨文件的函数包装链（规则顺序也不再由 main.lua 的 require 顺序决定）。
-- 判定顺序与理由见 docs/superpowers/specs/2026-10-06-travel-judgment-refactor-design.md
--
--
function gt:tele_failed()
  sfx:Play(187, 0.5, 0, false, 1)
end
--
function gt:check_curse_room(gid)
    -- 来源：原 gtrep.lua:566-583。按门路线统一结算，不能仅检查起点/终点类型。
    gt:sweep_doors()
    gt:apply_travel_door_penalties(crd.SafeGridIndex,gid)
end
--
--everyone a landing carries: players, familiars by type, and anything owned by
--a player (Mom's Knife, a carried tear)
function gt:landed_party()
    local party = {}
    for i = 0, Game():GetNumPlayers() - 1 do
      party[#party + 1] = Isaac.GetPlayer(i)
    end
    for _, e in ipairs(Isaac.GetRoomEntities()) do
      local owner = e.Parent or e.SpawnerEntity
      if e.Type ~= EntityType.ENTITY_PLAYER
          and (e.Type == EntityType.ENTITY_FAMILIAR or (owner and owner:ToPlayer())) then
        party[#party + 1] = e
      end
    end
    return party
end

--put the party one step inside the arrival door by hand. Direction is ignored,
--EnterDoor ignores writes, LeaveDoor changes nothing (all measured)
function gt:land_at_door()
    local slot = tele_door_slot
    tele_door_slot = -1
    if slot < 0 then return end
    local door = room:GetDoor(slot)
    if not door then return end
    local dx, dy = 0, 0
    local side = slot % 4
    if side == 0 then dx = 40 elseif side == 2 then dx = -40
    elseif side == 1 then dy = 40 else dy = -40 end
    local stand = Vector(door.Position.X + dx, door.Position.Y + dy)
    --one shift for all, so a co-op pair keeps its spacing
    local shift = stand - player.Position
    for _, e in ipairs(gt:landed_party()) do
      e.Position = e.Position + shift
    end
end

--floor.* is read at each use, never copied at the top: an antechamber hop
--mid-call changes the room, and with it the descriptor and the grid
-- 落地前不再有准入拦截：原先这里开头的四条（Mother's Shadow 在场、Mom / Ultra Greed 房名、
-- 目标挑战房血量、FairTripTime 找不到路线）已于 2026-10-06 **上移进判定层**
-- （scripts/gtp_travel.lua 的 ① departure / ② target_entry / ④ path）—— 它们本质是
-- 「这个目标不能去」，留在落地层会造成「光标高亮着、松手只响失败音」。
-- 调用方进来之前已经保证 gt:can_travel_to(gid).ok，所以这里只负责「做什么」：
-- 收代价（过路费）、摘迷宫诅咒、算落点、走过场。
function gt:teleport_to_grid_index(gid)
    gt:check_curse_room(gid)
    level.EnterDoor = -1
    level.LeaveDoor = -1
    if level:GetCurses() & LevelCurse.CURSE_OF_MAZE ~= 0 then
      level:RemoveCurses(LevelCurse.CURSE_OF_MAZE)
      tele_maze = true
    end

    local dist = gt:travel_time_distance(crd.SafeGridIndex, gid)

    --an L room's anchor cell is not in grid_room, so the antechamber may be missing
    local from_pre = crd.Data.Type == 7 and secret_pre_room_id[crid] or nil
    local from_prd = from_pre and grid_room[from_pre] or nil
    if from_prd then --from secret room
      if from_prd.ListIndex == grid_room[gid].ListIndex then
        gid = from_pre
      elseif not (grid_room[gid].Data.Type == 10 and secret_pre_room_id[gid] and secret_pre_room_id[gid] == crid) then
        -- 中转仅控制落点，门惩罚已经按原始完整路线结算。
        Game():ChangeRoom(from_pre,-1)
      end
    end
    if grid_room[gid].Data.Type == 7 then --to secret room
      local to_pre = secret_pre_room_id[gid]
      local to_prd = to_pre and grid_room[to_pre] or nil
      if to_prd then
        if to_prd.ListIndex == crd.ListIndex then --crd, since grid_room[crid] is nil in an L room
          if crd.Data.Shape > 3 then
            Game():ChangeRoom(to_pre,-1)
          end
        elseif not (crd.Data.Type == 10 and secret_pre_room_id[crid] and secret_pre_room_id[crid] == gid) then
          Game():ChangeRoom(to_pre,-1)
        end
      end
    end
    --read here, not up top: an antechamber hop may have moved the player
    local trd = grid_room[gid]
    local here = Game():GetLevel():GetCurrentRoomDesc().SafeGridIndex
    local there = trd and trd.SafeGridIndex or gid
    tele_door_slot = -1
    local arrive = gid --the cell handed over; see rules.landing_route
    if gt:get_config_bool("ArriveAtDoor", true) then
      local cell, walked, slot = gt:landing_route(here, there)
      arrive = cell or gid
      tele_door_slot = slot
      --a room bigger than the screen, reached from further than next door, needs
      --the wall chosen too, and the wall comes from the room the trip starts in.
      --The room hopped into is on screen until the fade, which is why this is
      --off by default: the game shows it for a moment before the transition
      if walked and trd and trd.Data.Shape >= RoomShape.ROOMSHAPE_1x2 then
        Game():ChangeRoom(walked, -1)
      end
    end
    local tele_mode = gt:get_teleport_transition()  -- 1 立即出现 / 2 淡入淡出 / 3 传送白闪
    -- 调试模式不再强制「立即出现」也不跳过计时补偿（2026-10-06 用户要求：debug 只出诊断、不改行为）
    if dist ~= 0 then
      local speed = player.MoveSpeed
      local addTime = math.floor((60.0*dist/speed)+0.5)
      Game().TimeCounter = Game().TimeCounter + addTime --boss rush reads TimeCounter; Hush does not
    end
    -- 过场越短，冷却越短（沿用 Fixed 的三档：无过场 1 帧 / 淡入淡出 10 帧 / 传送白闪 45 帧）
    if tele_mode == 1 then tele_cd = 1
    elseif tele_mode == 3 then tele_cd = 45
    else tele_cd = 10 end
    if tele_mode == 1 then
      Game():ChangeRoom(arrive,-1)
      Game():GetRoom():PlayMusic()
      return
    end
    -- RoomTransitionAnim（enums.lua）：1 = FADE（淡入淡出）/ 3 = TELEPORT（白闪）
    local tele_anime = (tele_mode == 3) and 3 or 1
    Game():StartRoomTransition(arrive, Direction.NO_DIRECTION, tele_anime, player, -1) --direction is ignored, measured twice
    tele_cd = (tele_mode == 3) and 45 or 10
end
--
function gt:is_mirror_world()
    local stageType = level:GetStageType()
    local isRepStage = (stageType == 4 or stageType == 5)
    local isDownpour2 = (stage == 2) or (stage == 1 and level:GetCurses() & LevelCurse.CURSE_OF_LABYRINTH ~= 0)
    if not (isRepStage and isDownpour2) then
        return false
    end
    return GetPtrHash(crd) == GetPtrHash(level:GetRoomByIdx(level:GetCurrentRoomIndex(), 1))
end
--
function gt:get_current_dimension()
    -- MinimapAPI tracks all Repentance dimensions, including Death
    -- Certificate's special dimension. The mirror-world check is retained as
    -- a fallback for the API's normal mirror map support.
    if MinimapAPI and MinimapAPI.CurrentDimension ~= nil then
      return MinimapAPI.CurrentDimension
    end
    return gt:is_mirror_world() and 1 or 0
end
--
function gt:get_minapi_offset_vec()
    local ho = Options.HUDOffset * 10
    local screenW = MinimapAPI:GetScreenSize().X
    local posX = MinimapAPI:GetConfig("PositionX")
    local posY = MinimapAPI:GetConfig("PositionY")
    local topRightX = screenW - ho * 2.2
    local topRightY = ho * 1.2
    return Vector(topRightX - posX, topRightY + posY)
end
--
-- MinimapAPI 大地图锚点（maxx, miny）：逐项照抄其 UpdateUnboundedMapOffset
-- （minimapapi/main.lua:1471）——遍历它自己的房间对象，用 DisplayPosition or
-- Position 和可能被改过的 Shape（虚空层 boss 房被显示成 1×1 且 DisplayPosition
-- 可能挪一格）算右缘/顶缘。⚠️ 不能用「扫 grid_room 真实占据格」的 get_corner_room
-- 代替：虚空层 boss 房大概率贴边，其显示格比真实格小一列/一行时两边锚点差一格，
-- 整张大地图与我们的光标/边界叠加层错位（2026-10-04 用户实测，虚空层/XL）。
-- 按帧缓存：一帧内所有叠加格共用同一锚点，不必每格重算。
gt._map_anchor_cache = { frame = -1, maxx = nil, miny = nil }
function gt:get_minapi_map_anchor()
    local frame = Game():GetFrameCount()
    local cache = gt._map_anchor_cache
    if cache.frame == frame then
        return cache.maxx, cache.miny
    end
    cache.frame = frame
    cache.maxx, cache.miny = nil, nil
    local map = MinimapAPI:GetLevel(gt:get_current_dimension())
    if not map then
        return nil, nil
    end
    local gsx = MinimapAPI.GlobalScaleX or 1
    for _, room in ipairs(map) do
        if room:GetDisplayFlags() > 0 then
            local position = room.DisplayPosition or room.Position
            -- 其他 mod 注册的自定义形状理论上 AddRoomShape 会补这两张表；缺表时按 1×1 防御
            local pivot = MinimapAPI.RoomShapeGridPivots[room.Shape] or Vector(0, 0)
            local gridsize = MinimapAPI:GetRoomShapeGridSize(room.Shape) or Vector(1, 1)
            local maxxval = (position.X - pivot.X +
                (gsx >= 0 and gridsize.X or 0)) * gsx
            if not cache.maxx or maxxval > cache.maxx then
                cache.maxx = maxxval
            end
            if not cache.miny or position.Y < cache.miny then
                cache.miny = position.Y
            end
        end
    end
    return cache.maxx, cache.miny
end
--
function gt:get_config_bool(key, default)
    if ModConfigMenu and ModConfigMenu.Config["GoodTripPlus"] then
      local value = ModConfigMenu.Config["GoodTripPlus"][key]
      if value ~= nil then
        return value
      end
    end
    local value = gt[key]
    if value ~= nil then
      return value
    end
    return default
end
--
-- 调试模式（**纯诊断开关**），默认关，两个开关任一为真即开：
--   · MCM 的「调试模式」项（键 DebugMod）—— 玩家侧开关，改了立刻生效（每帧实时读）；
--   · gtconfig.lua 的 `gt.DebugMod = true` —— 开发者文件级开关。**故意让它优先于 MCM**：
--     没装 MCM 时也能开，且不会被 MCM 注册时写入的默认 false 顶掉（MCM 的 Config 在注册瞬间
--     就被填成默认值，普通选项都是 MCM 覆盖文件；调试开关反过来，免得改文件却没反应）。
-- 开启后只做一件事：**输出诊断**——光标停在目标上即自动落盘（`[GTPtrip]`）、
--   解锁「按住地图键 + 键盘 F4」的手动 dump、屏幕上画**红色**的实时理由浮层
--   （黄底的一次性 dump 浮层 2026-10-06 已删）、各模块往控制台 / log.txt 写诊断行。
--   关着时以上全部静默（不画、不写 log）。
-- ⚠️ 它**绝不改变任何传送判定或传送表现**（2026-10-06 用户拍板）。历史遗留的几处
--   「debug 下放行 / 跳过」已全部移除：不再绕过保护性禁传（道具入口 / 奖励房门 / 诅咒房）、
--   不再强制「立即出现」跳过过场、不再豁免诅咒房过路费、呼出光标的闸门也不再为它开绿灯。
--   理由：开它去排查「为什么传不过去」时，若判定被绕过就看不到拦住的规则；要测的是
--   「预期设置下」的行为。排查仍然可用：按住地图键 + F4 的手动 dump 不依赖光标是否呼出。
function gt:is_debug()
    if gt.DebugMod == true then
      return true
    end
    return gt:get_config_bool("DebugMod", false) == true
end
--
-- 传送范围（1=任意房间 2=相邻房间 3=已探索房间）。默认 2，等价于移植初期的
-- AllowNeighborRoom=true / AllowAnyRoom=false。值一律夹到 1..3，防御 MCM 存的旧值 / 脏值。
function gt:get_travel_mode()
    local v = tonumber(gt:get_config_bool("TravelMode", 2)) or 2
    v = math.floor(v + 0.5)
    if v < 1 then return 1 end
    if v > 3 then return 3 end
    return v
end
--
-- 禁止传送进诅咒房（移植基底 MLX's Tweak 的 BlockCurseRoom，默认 true = 禁止）。
-- 消费点：scripts/gtp_curseblock.lua 的准入包装（拦住「传送到诅咒房」这个目标），
-- 以及本文件 check_neigh_connected 的类型白名单 —— 关掉本项后，诅咒房在「相邻房间」
-- 档位也按普通房间参与邻居豁免（见那里的注释）。
function gt:block_curse_room()
    return gt:get_config_bool("BlockCurseRoom", true) == true
end
--
-- 传送过场（落地时的表现）。默认 2，值一律夹到 1..3：
--   1 = 立即出现：直接 Game():ChangeRoom()，没有任何过场（原来的 FastTransition = true）
--   2 = 淡入淡出：StartRoomTransition(..., RoomTransitionAnim.FADE = 1)，短暂淡出淡入（像换房）
--   3 = 传送白闪：StartRoomTransition(..., RoomTransitionAnim.TELEPORT = 3)，等同使用传送道具
-- 顺带决定传送冷却 tele_cd（1 / 10 / 45 帧，沿用 Fixed 的档位）：过场越短，冷却越短。
function gt:get_teleport_transition()
    local v = tonumber(gt:get_config_bool("TeleportTransition", 2)) or 2
    v = math.floor(v + 0.5)
    if v < 1 then return 1 end
    if v > 3 then return 3 end
    return v
end
--
-- 迷失诅咒期间 MinimapAPI 还会不会显示地图 = 它的 OverrideLost（MCM 里叫 "Display During Curse"，
-- 默认 false）。MinimapAPI 自己的读法（main.lua）：`OverrideLost or (curse & CURSE_OF_THE_LOST <= 0)`
-- —— 即 OverrideLost 为真时无视迷失诅咒照常画图。
-- 我们把它作为「迷失诅咒下能否传送」的唯一依据（2026-10-05 用户要求），不再有独立开关：
--   地图显示 → 传送照常；地图不显示 → 停用。没有 MinimapAPI 时按原版语义（诅咒期间不显示）处理。
function gt:curse_map_visible()
    if MinimapAPI and MinimapAPI.GetConfig then
      return MinimapAPI:GetConfig("OverrideLost") == true
    end
    return false
end
--
function gt:get_minapi_room_by_list_index(listIndex)
    if not MinimapAPI then
      return nil
    end
    local map = MinimapAPI:GetLevel(gt:get_current_dimension())
    if map then
      for _, mapRoom in ipairs(map) do
        if mapRoom.Descriptor and mapRoom.Descriptor.ListIndex == listIndex then
          return mapRoom
        end
      end
    end
    return nil
end
--
function gt:dump_map_diagnostics()
    local function out(message)
      console_output("[GoodTripPlus] " .. message .. "\n")
      Isaac.DebugString("[GoodTripPlus] " .. message)
    end
    local dim = gt:get_current_dimension()
    local map = MinimapAPI and MinimapAPI:GetLevel(dim)
    local lt = gt:get_corner_room(1)
    local rt = gt:get_corner_room(2)
    local rb = gt:get_corner_room(4)
    local gsx = MinimapAPI and (MinimapAPI.GlobalScaleX or 1) or 1
    out("MAP DIAGNOSTICS BEGIN")
    out("stage=" .. tostring(level:GetStage()) .. " ascent=" .. tostring(level:IsAscent()) ..
      " dimension=" .. tostring(dim) .. " mirror=" .. tostring(gt:is_mirror_world()) ..
      " scaleX=" .. tostring(gsx))
    out("current safe=" .. tostring(crd.SafeGridIndex) .. " list=" .. tostring(crd.ListIndex) ..
      " start=" .. tostring(level:GetStartingRoomIndex()) .. " grid corners LT=" ..
      tostring(lt.X) .. "," .. tostring(lt.Y) .. " RT=" .. tostring(rt.X) .. "," ..
      tostring(rt.Y) .. " RB=" .. tostring(rb.X) .. "," .. tostring(rb.Y))
    local cursorPos = gt:gid_to_rtmap_pos(crd.SafeGridIndex)
    out("displayMode=" .. tostring(MinimapAPI:GetConfig("DisplayMode")) .. " large=" ..
      tostring(MinimapAPI:IsLarge()) .. " predicted cursor=" .. tostring(cursorPos.X) .. "," ..
      tostring(cursorPos.Y))
    for gid, rd in pairs(grid_room) do
      if gt:is_grid_room_displayed(gid) then
        out("grid gid=" .. tostring(gid) .. " list=" .. tostring(rd.ListIndex) ..
          " safe=" .. tostring(rd.SafeGridIndex) .. " flags=" .. tostring(rd.DisplayFlags))
      end
    end
    if not map then
      out("MinimapAPI has no map for this dimension")
      out("MAP DIAGNOSTICS END")
      return
    end

    -- 锚点直接复用投影同款的 get_minapi_map_anchor（照抄 UpdateUnboundedMapOffset，
    -- 含无 Descriptor 的红钥匙房）；这里额外把每个显示房间逐条列出方便对照
    local maxx, miny = gt:get_minapi_map_anchor()
    local visibleCount = 0
    for _, mapRoom in ipairs(map) do
      if mapRoom:GetDisplayFlags() > 0 then
        visibleCount = visibleCount + 1
        local position = mapRoom.DisplayPosition or mapRoom.Position
        local render = mapRoom.RenderOffset
        local target = mapRoom.TargetRenderOffset
        out("room safe=" .. tostring(mapRoom.Descriptor and mapRoom.Descriptor.SafeGridIndex) ..
          " list=" .. tostring(mapRoom.Descriptor and mapRoom.Descriptor.ListIndex) ..
          " shape=" .. tostring(mapRoom.Shape) ..
          " pos=" .. tostring(position.X) .. "," .. tostring(position.Y) ..
          " disp=" .. tostring(mapRoom.DisplayPosition) .. " flags=" ..
          tostring(mapRoom:GetDisplayFlags()) .. " render=" ..
          (render and (tostring(render.X) .. "," .. tostring(render.Y)) or "nil") ..
          " target=" .. (target and (tostring(target.X) .. "," .. tostring(target.Y)) or "nil"))
      end
    end
    out("visible=" .. tostring(visibleCount) .. " anchor maxX=" ..
      tostring(maxx) .. " minY=" .. tostring(miny) ..
      " (old corner anchor maxX=" .. tostring(rt.X + 1) .. " minY=" .. tostring(lt.Y) .. ")")
    out("MAP DIAGNOSTICS END")
end
--
function gt:get_rtmap_info()
    local rtroom = gt:get_corner_room(2)
    local ho = Options.HUDOffset * 10
    local ltx = scpos.X - (rtroom.X + 1) * 17 - 5 - ho * 2.4
    local lty = - (rtroom.Y) * 15 + 5 + ho * 1.3
    return ltx, lty, rtroom
end
--
function gt:get_pos_grid_index(pos)
    if MinimapAPI then
      local project
      -- 与 gid_to_rtmap_pos 同一套投影（含同一锚点），直接复用
      for gid, rd in pairs(grid_room) do
        if gt:is_grid_room_displayed(gid) then
          project = project or gt:make_rtmap_projector()
          local p = project(gid)
          if math.abs(pos.X - p.X) < 8.5 and math.abs(pos.Y - p.Y) < 7.5 then
            return gid
          end
        end
      end
      return -99
    end
    local ltx, lty = gt:get_rtmap_info()
    if pos.X > ltx and pos.Y > lty and pos.X < ltx + 222 and pos.Y < lty + 196 then
      return math.floor((pos.X - ltx) / 17) + math.floor((pos.Y - lty) / 15) * 13
    else
      return -99
    end
end
--
local make_projection = require("scripts.gtp_projection")
function gt:make_rtmap_projector()
    return make_projection(gt, MinimapAPI, Vector)
end
function gt:gid_to_rtmap_pos(gid)
    return gt:make_rtmap_projector()(gid)
end
--
function gt:get_current_room_cursor_gid()
    -- ⚠️ 读「游戏此刻」的当前房间，而不是文件级 local `crd` / `room`：
    -- 跨层 / R 重开时，光标要定位的那一刻可能**早于** new_room() 刷新这些 local
    -- （回调顺序与帧对齐不定 —— 2026-10-05 用户实测「TAB+R 间隔短就定位错」），
    -- 用缓存值会把光标算到**上一层**的房间格子上。这两个调用都很便宜。
    local lvl = Game():GetLevel()
    local d = (lvl and lvl:GetCurrentRoomDesc()) or crd
    if not d then
      return crd and crd.SafeGridIndex or 0
    end

    local gid = d.SafeGridIndex
    if not d.Data then
      return gid
    end

    local rm = Game():GetRoom() or room
    local tl = rm:GetTopLeftPos()
    local br = rm:GetBottomRightPos()
    local isRight = player.Position.X >= (tl.X + br.X) / 2
    local isBottom = player.Position.Y >= (tl.Y + br.Y) / 2
    local shape = d.Data.Shape

    if shape == RoomShape.ROOMSHAPE_1x2 or shape == RoomShape.ROOMSHAPE_IIV then
      if isBottom then gid = gid + 13 end
    elseif shape == RoomShape.ROOMSHAPE_2x1 or shape == RoomShape.ROOMSHAPE_IIH then
      if isRight then gid = gid + 1 end
    elseif shape == RoomShape.ROOMSHAPE_2x2 then
      gid = gid + (isRight and 1 or 0) + (isBottom and 13 or 0)
    elseif shape == RoomShape.ROOMSHAPE_LBR then
      if isBottom then
        gid = gid + 13
      elseif isRight then
        gid = gid + 1
      end
    elseif shape == RoomShape.ROOMSHAPE_LTL then
      if isBottom then
        gid = gid + (isRight and 13 or 12)
      end
    elseif shape == RoomShape.ROOMSHAPE_LTR then
      if isBottom then
        gid = gid + (isRight and 14 or 13)
      end
    elseif shape == RoomShape.ROOMSHAPE_LBL then
      if isRight then
        gid = gid + (isBottom and 14 or 1)
      end
    end

    -- The corner excluded by an L-shaped room should be inaccessible. Keep a
    -- safe fallback in case a custom room reports an unexpected position.
    if grid_room[gid] then
      return gid
    end
    return d.SafeGridIndex
end
--
function gt:get_grid_room()
    grid_room = {}
    local dim = gt:get_current_dimension()
    local all_room = level:GetRooms()
    for i = 0, all_room.Size do
      local des = all_room:Get(i)
      if des then
        local gid = des.SafeGridIndex
        -- A descriptor's SafeGridIndex is not always the top-left cell of a
        -- large room.  ROOMSHAPE_LTL, for example, occupies (0, 0), (-1, 1)
        -- and (0, 1).  Check the full two-row span around the anchor, then
        -- keep only cells that resolve to this descriptor.
        for jx=-1, 1 do
          for jy=0, 1 do
            local tgid = gid + jx + jy * 13
            local tdes = level:GetRoomByIdx(tgid, dim)
            if tdes and tdes.ListIndex == des.ListIndex then
              grid_room[tgid] = tdes
            end
          end
        end
      end
    end
end
-- ===== 判定层访问器（gtp_travel 专用，2026-10-06）=====
-- gtrep 的文件级 local 会被 get_grid_room() / new_room() / new_level() 整体重新赋值，
-- 外部模块捕获它们的引用会拿到**过时的那一层** → 一律走这些访问器。

-- ⚠️ grid_room 与 GetRoomByIdx **不可互换**：判定读目标用的就是这个表
-- （L 形房的锚点格语义与 GetRoomByIdx 不同），所以两个访问器都留着。
function gt:grid_room_desc(gid)
  return grid_room[gid]
end

function gt:travel_room_neighbors(gid)
  local node=room_neighbours[gid]
  return node and node.Neighbors or {}
end

-- Level:GetRoomByIdx 的薄包装（诅咒房判定沿用 gtp_curseblock 移植时的原口径）
function gt:room_desc_at(gid)
  local lvl = Game():GetLevel()
  if not lvl then return nil end
  return lvl:GetRoomByIdx(gid, gt:get_current_dimension())
end

-- 当前房 / 层 / 房间 / 玩家的一份新鲜拷贝（判定上下文用）
function gt:travel_cur_state()
  local lvl = Game():GetLevel()
  local d = lvl and lvl:GetCurrentRoomDesc() or nil
  return {
    cur = d,
    cur_gid = d and d.SafeGridIndex or nil,
    level = lvl,
    room = Game():GetRoom(),
    player = Isaac.GetPlayer(0),
  }
end
--
function gt:is_grid_room_displayed(gid)
    local rd = grid_room[gid]
    if not rd then
      return false
    end
    if MinimapAPI then
      local map = MinimapAPI:GetLevel(gt:get_current_dimension())
      if map then
        for _, mapRoom in ipairs(map) do
          if mapRoom.Descriptor and mapRoom.Descriptor.ListIndex == rd.ListIndex then
            return mapRoom:GetDisplayFlags() > 0
          end
        end
      end
    end
    return rd.DisplayFlags > 0
end
--
function gt:get_corner_room(num)
    local corner_room = Vector(6, 6)
    local fx = {1, -1, 1, -1}
    local fy = {1, 1, -1, -1}
    local ffx = fx[num]
    local ffy = fy[num]
    local xStart = ffx > 0 and 0 or 12
    local xEnd = ffx > 0 and 12 or 0
    local yStart = ffy > 0 and 0 or 12
    local yEnd = ffy > 0 and 12 or 0
    local foundX = false
    for i = xStart, xEnd, ffx do
      for j = 0, 12 do
        if grid_room[i+j*13] then
          if gt:is_grid_room_displayed(i+j*13) then
            corner_room.X = i
            foundX = true
            break
          end
        end
      end
      if foundX then
        break
      end
    end
    local foundY = false
    for j = yStart, yEnd, ffy do
      for i = 0, 12 do
        if grid_room[i+j*13] then
          if gt:is_grid_room_displayed(i+j*13) then
            corner_room.Y = j
            foundY = true
            break
          end
        end
      end
      if foundY then
        break
      end
    end
    return corner_room
end
--
function gt:pre_secret_room()
  local door = nil
  for i =0, 7 do
    door = room:GetDoor(i)
    if door then
      local id = door.TargetRoomIndex
      if door.Desc.Variant == 8 then
        local targetRoom = grid_room[id]
        if door.TargetRoomType == 10 then
          if not secret_pre_room_id[crid] then
            secret_pre_room_id[crid] = id
          end
        elseif targetRoom and targetRoom.VisitedCount == 0 then
          secret_pre_room_id[crid] = id
        elseif targetRoom then
          secret_pre_room_id[crid] = id
          break
        end
      end
    end
  end
  door_state.dirty = true
end
--
function gt:pre_secret_curse_room()
  local door = nil
  for i =0, 7 do
    door = room:GetDoor(i)
    if door then
      local id = door.TargetRoomIndex
      if door.Desc.Variant == 8 then
        if door.TargetRoomType == 7 then
          if secret_pre_room_id[id] and secret_pre_room_id[id] ~= crid then
            secret_pre_room_id[crid] = id
            break
          else
            secret_pre_room_id[crid] = id
          end
        end
      end
    end
  end
  door_state.dirty = true
end
--
function gt:get_cursor_speed()
    if ModConfigMenu and ModConfigMenu.Config["GoodTripPlus"] then
        return ModConfigMenu.Config["GoodTripPlus"]["CursorSpeed"] or 2
    end
    return 2
end
--
-- 光标的不透明度系数 [0, 1]。0 ＝ 这一刻还不该画（淡入还没开始，前 4 帧）。
-- 节奏与隐藏房候选标记 / 地图边界高亮一致（同口径的帧计数，见文件上方 CURSOR_FADE_*）。
function gt:get_cursor_fade()
    if mmp_ctrl_fade <= 0 then
      return 0
    end
    return mmp_ctrl_fade / CURSOR_FADE_MAX
end
--
function gt:get_cursor_arrow_button(i)
    -- 物理键盘用索引 0；手柄仍按动作映射，不能拿键盘码查手柄按钮。
    if player.ControllerIndex ~= 0 or not Keyboard then return nil end
    return Keyboard[cursor_arrow_keys[i]]
end
function gt:cursor_direction_pressed(i)
    if Input.IsActionPressed(key[i], player.ControllerIndex) then return true end
    local button = gt:get_cursor_arrow_button(i)
    return button ~= nil and Input.IsButtonPressed(button, 0) or false
end
function gt:mmp_ctrl_move()
    local moved = false
    local speed = gt:get_cursor_speed()
    local grid_step = gt:get_config_bool("CursorGridStep", false)
    local xmin, xmax, ymin, ymax
    if MinimapAPI then
      local offsetVec = gt:get_minapi_offset_vec()
      local ltroom = gt:get_corner_room(1)
      local rtroom = gt:get_corner_room(2)
      local rbroom = gt:get_corner_room(4)
      local gsx = MinimapAPI.GlobalScaleX or 1
      if gsx >= 0 then
        xmin = offsetVec.X + (ltroom.X - rtroom.X - 1) * 17 + 9
        xmax = offsetVec.X + (rtroom.X - rtroom.X - 1) * 17 + 9
      else
        xmin = offsetVec.X + (ltroom.X - rtroom.X) * 17 - 17
        xmax = offsetVec.X + (ltroom.X - ltroom.X) * 17 - 17
      end
      ymin = offsetVec.Y + 8
      ymax = offsetVec.Y + (rbroom.Y - ltroom.Y) * 15 + 8
    else
      local ltx, lty, rtroom = gt:get_rtmap_info()
      xmin = ltx
      xmax = ltx + (rtroom.X + 1) * 17
      ymin = lty
      ymax = lty + 13 * 15
    end
    for i = 1, 4 do
      local pressed
      if grid_step then
        pressed = Input.IsActionTriggered(key[i], player.ControllerIndex)
        if not pressed then
          local button = gt:get_cursor_arrow_button(i)
          pressed = button ~= nil and Input.IsButtonTriggered(button, 0) or false
        end
      else
        pressed = gt:cursor_direction_pressed(i)
      end
      if pressed then
        local amount = grid_step and ((i == 1 or i == 4) and 15 or 17) or speed
        local newpos = mmp_ctrl_pos + dir[i] * amount
        if newpos.X >= xmin and newpos.Y >= ymin and newpos.X <= xmax and newpos.Y <= ymax then
          mmp_ctrl_pos = newpos
          -- 玩家自己动过光标了：从此不再自动归位（照旧"你放哪儿就待在哪儿"）
          mmp_ctrl_moved = true
          moved = true
        end
      end
    end
    return moved
end
function gt:cursor_keyboard_pressed()
    for i = 1, 4 do
      if gt:cursor_direction_pressed(i) then return true end
    end
    return false
end
--
function gt:draw_rtmap_cursor()
    cursor:Render(mmp_ctrl_pos, Vector(0, 0), Vector(0, 0))
end
function gt:get_mouse_screen_pos()
    -- Input 的 render-plane 坐标不能直接当 HUD 坐标；使用文档示例的世界到屏幕转换。
    -- 第二个返回值只用于输入意图：不受 WorldToScreen 投影变化影响。
    return Isaac.WorldToScreen(Input.GetMousePosition(true)), Input.GetMousePosition(false)
end
function gt:get_cursor_grid_index(pos)
    if mouse_cursor.mode ~= 'mouse' or not MinimapAPI then
      return gt:get_pos_grid_index(pos)
    end
    local mapRoom = mouse_hit(MinimapAPI, pos)
    if not mapRoom then return -99 end
    local rd = mapRoom.Descriptor
    -- 大房间/L 形房的 descriptor 锚点未必是 grid_room 占据格，匹配同房间格。
    local gid = rd.SafeGridIndex
    if grid_room[gid] and grid_room[gid].ListIndex == rd.ListIndex then return gid end
    for cell, descriptor in pairs(grid_room) do
      if descriptor.ListIndex == rd.ListIndex then return cell end
    end
    return -99
end
--
function gt:update_cursor_room_highlight()
    local gid = gt:get_cursor_grid_index(mmp_ctrl_pos)
    local res = gt:can_travel_to(gid)
    -- 调试模式下免按键取证：光标扫到目标就把判定过程 + 门表写进 log.txt
    -- （被拒要记，挑战房被放行也要记 —— 放行同样可能判错）
    if gt.auto_log_travel then
      gt:auto_log_travel(gid, res)
    end
    if res.ok then
      mmp_highlight_gid = gid
    else
      mmp_highlight_gid = nil
    end
end
--
function gt:draw_minapi_room_highlight(mapRoom, color)
    draw_room_highlight(MinimapAPI, mapRoom, color, Vector)
end
--
-- 初始房间的绿色高亮已移除（2026-10-03）：MinimapAPI 自带
-- "Highlight Start Room"（HighlightStartRoom，其菜单里开），
-- 按项目定位（MinimapAPI 的外置传送插件）不再自己画。
-- 2026-10-05：这一项**已在我们自己的 MCM 里代理出来**（「高亮初始房间」，
-- 见文件末尾 MCM 注册段的 ModConfigMenu.AddSetting：只读写 MinimapAPI.Config，
-- 不另存一份，所以与 MinimapAPI 菜单里那项是同一个值）。这里依旧不自己绘制。
-- 光标所在房间的高亮保留（HighlightCursorRoom，MinimapAPI 无对应功能），
-- 由 render_cursor 直接绘制。
--
-- Renders the cursor on top of MinimapAPI's own minimap. This is
-- deliberately a separate callback from gt:tab_action() (see the bottom of
-- this file for where it's registered): MinimapAPI draws itself on
-- MC_POST_HUD_RENDER when REPENTOGON is present, which fires *after*
-- MC_POST_RENDER. Drawing the cursor unconditionally on MC_POST_RENDER (as
-- this mod originally did) meant the cursor got drawn first and MinimapAPI's
-- minimap art was painted on top of it afterwards, making the cursor appear
-- to be stuck underneath the map with REPENTOGON installed.
function gt:render_cursor()
    -- 调试模式下的实时拒绝理由（由 gtp_travel 提供；模块不在时跳过）。
    -- 这是屏幕上唯一的诊断显示（黄色的一次性 dump 浮层 2026-10-06 已删）。
    if gt.render_travel_reason then
      gt:render_travel_reason(mmp_ctrl_pos, mmp_ctrl)
    end
    if mmp_ctrl then
      -- 淡入：前几帧 fade == 0（不画），之后渐显 —— 与标记 / 地图边界同一节奏
      local fade = gt:get_cursor_fade()
      if fade > 0 then
        if gt:get_config_bool("HighlightCursorRoom", true) and mmp_highlight_gid then
          local desc = grid_room[mmp_highlight_gid]
          if desc then
            gt:draw_minapi_room_highlight(
              gt:get_minapi_room_by_list_index(desc.ListIndex),
              -- RGB multipliers of 1 preserve the original room art.  Zeroing
              -- them and applying a white RGB offset leaves only its silhouette.
              Color(0, 0, 0, 0.45 * fade, 1, 1, 1)
            )
          end
        end
        cursor.Color = Color(1, 1, 1, fade, 0, 0, 0)
        gt:draw_rtmap_cursor()
      end
    end
end
--
function gt:prep()
    player = Isaac.GetPlayer(0)
end
-- 键盘松开地图键与鼠标点击共用准入、冷却、诊断和隐藏/诅咒房前室准备。
-- 来源：原 step() 松键传送分支。
function gt:try_cursor_travel(gid, source)
    if gt:door_penalty_pending() then return false end
    if source == 'mouse' and not gt:get_config_bool('MouseTeleport', true) then return false end
    gt:auto_log_secret_diag(gid)
    local res = gt:can_travel_to(gid)
    if source == 'mouse' then
      -- 单击级取证：放行/拒绝都写，不依赖玩家打开调试或按 F4；日志失败不影响传送。
      pcall(function()
        Isaac.DebugString(string.format('[GTPmouse] click x=%.1f y=%.1f gid=%s ok=%s rule=%s cooldown=%s',
          mmp_ctrl_pos.X, mmp_ctrl_pos.Y, tostring(gid), tostring(res.ok),
          tostring(res.rule), tostring(tele_cd)))
      end)
    end
    if gt.auto_log_travel then gt:auto_log_travel(gid, res) end
    if not res.ok or tele_cd >= 1 then return false end
    if crd.Data.Type == 7 or (crd.Data.Type == 8 and Game():IsGreedMode()) then
      gt:pre_secret_room()
    elseif crd.Data.Type == 10 then
      gt:pre_secret_curse_room()
    end
    gt:teleport_to_grid_index(gid)
    return true
end
--
function gt:tab_action()
    local cp = Isaac.WorldToRenderPosition(Vector(320,280))
    scpos = cp + cp
    --
    -- 免控制台诊断入口：**调试模式打开后**，按住地图键 + 键盘 F4 → 把光标所在格
    -- （光标没启用时用当前房间）的完整判定打到屏幕左上角 + 控制台 + log.txt。
    -- （控制台命令在 REPENTOGON 的 ImGui 控制台里不分发给 mod，所以这条是主力入口；
    -- 20 帧内连按只算一次，避免长按/连点刷屏）
    --
    -- 2026-10-05 用户拍板：本入口归「调试模式」总闸 —— 开关关着时按 F4 什么都不出（连 log 都不写），
    -- 免得正式游玩时误按出一屏诊断。想用就先去 MCM 打开「调试模式」（即时生效，不用重启）。
    --
    -- ⚠️ 第二个参数必须写死 0（= 键盘玩家），绝不能传 player.ControllerIndex：
    --    IsButtonTriggered 的手柄按钮码是「低位编号、超过 31 回绕」（见 enums 的 Controller，
    --    0=D_PAD_LEFT … 5=BUTTON_B …），而 Keyboard.KEY_F4 = 293，293 % 32 = 5 = 手柄 B 键。
    --    传手柄索引时这条判定会退化成「查该手柄的 B 键」，手柄玩家边按地图键边按到 B
    --    就误判成 F4、白跑一次 dump（2026-10-05 玩家实测）。键盘热键一律用索引 0。
    if gt:is_debug()
        and Input.IsButtonTriggered(Keyboard.KEY_F4, 0)
        and Game():GetFrameCount() - last_diag_frame > 20 then
      last_diag_frame = Game():GetFrameCount()
      local cell = mmp_ctrl and gt:get_cursor_grid_index(mmp_ctrl_pos)
        or gt:get_current_room_cursor_gid()
      gt:console_dump_diag(cell, "gtpdiag TAB+F4")
    end
    --
    if Input.IsActionTriggered(ButtonAction.ACTION_RESTART, player.ControllerIndex) and fastrestartenable then
      Isaac.ExecuteCommand("restart")
    end
    --
    if gt:can_open_cursor().ok then
      if not mmp_ctrl then
        mmp_ctrl = true
        mmp_ctrl_moved = false
        mmp_ctrl_fade = CURSOR_FADE_MIN  -- 从「还没开始」重新起算淡入
        mmp_ctrl_pos = gt:gid_to_rtmap_pos(gt:get_current_room_cursor_gid())
      else
        -- 玩家还没自己动过光标 ⇒ 每帧都把它贴回当前房间（与隐藏房标记同一套做法：
        -- 标记也是每帧按当前地图重算投影，所以跨层/重开后过几帧会自己切回正确位置）。
        -- 之前用「呼出后 30 帧内才归位」的窗口，用户实测 TAB+R 间隔短时仍然错位
        -- （地图重建要几帧，窗口可能已经走完），所以改成不设窗口。
        -- 玩家一按方向键就置 mmp_ctrl_moved，从此完全照旧：光标放哪儿待在哪儿。
        if not mmp_ctrl_moved then
          mmp_ctrl_pos = gt:gid_to_rtmap_pos(gt:get_current_room_cursor_gid())
        end
        player:SetShootingCooldown(2)
      end
      local pos, motion = gt:get_mouse_screen_pos()
      -- 先按方向键输入切模式，再检查移动边界；鼠标在地图外也能夺回控制。
      local keyboard_pressed = gt:cursor_keyboard_pressed()
      local follow, clicked, switched_keyboard = mouse_probe:update(mouse_cursor, {x=pos.X, y=pos.Y,
        motion_x=motion.X, motion_y=motion.Y,
        mouse_enabled=gt:get_config_bool('MouseTeleport', true),
        down=Input.IsMouseBtnPressed(0), active=true, keyboard=keyboard_pressed})
      if switched_keyboard then
        mmp_ctrl_pos = gt:gid_to_rtmap_pos(gt:get_current_room_cursor_gid())
        mmp_ctrl_moved = false
      end
      if follow then
        mmp_ctrl_pos = Vector(pos.X, pos.Y)
        mmp_ctrl_moved = true
      elseif keyboard_pressed then
        gt:mmp_ctrl_move()
      end
      gt:update_cursor_room_highlight()
      if clicked then
        gt:try_cursor_travel(gt:get_cursor_grid_index(mmp_ctrl_pos), 'mouse')
      end
      -- 淡入计数：按住期间逐帧 +1（与 delver/render.lua 的 tab_hold_cnt 同口径）
      mmp_ctrl_fade = math.min(mmp_ctrl_fade + 1, CURSOR_FADE_MAX)
    else
      mmp_ctrl = false
      mmp_highlight_gid = nil
      mmp_ctrl_fade = CURSOR_FADE_MIN
      local pos, motion = gt:get_mouse_screen_pos()
      mouse_probe:update(mouse_cursor, {x=pos.X, y=pos.Y, motion_x=motion.X, motion_y=motion.Y,
        down=Input.IsMouseBtnPressed(0), active=false})
    end
end
--
function gt:step()
    --a wall can open under the player's feet (bomb, red key), so sweep every
    --tick; but not mid-transition, when the live room and the cached descriptor disagree
    if level:GetCurrentRoomDesc().SafeGridIndex == crid then
      gt:sweep_doors()
    end
    if Game():IsPaused() then
      mmp_ctrl = false
      mmp_ctrl_fade = CURSOR_FADE_MIN
      mmp_highlight_gid = nil
      local pos, motion = gt:get_mouse_screen_pos()
      mouse_probe:update(mouse_cursor, {x=pos.X, y=pos.Y, motion_x=motion.X, motion_y=motion.Y,
        down=Input.IsMouseBtnPressed(0), active=false})
      return
    end
    if Input.IsActionTriggered(ButtonAction.ACTION_MAP,player.ControllerIndex)
    or Input.IsActionTriggered(ButtonAction.ACTION_ITEM,player.ControllerIndex)
    or Input.IsActionTriggered(ButtonAction.ACTION_PILLCARD,player.ControllerIndex) then
      gt:get_grid_room()
      gt:prep()
    end
    if Input.IsActionPressed(ButtonAction.ACTION_MAP,player.ControllerIndex) then
      gt:tab_action()
    else
      if mmp_ctrl and gt:can_open_cursor().ok then
        mmp_ctrl = false
        mmp_highlight_gid = nil
        mmp_ctrl_fade = CURSOR_FADE_MIN
        if mouse_cursor.mode == 'keyboard' then
          gt:try_cursor_travel(gt:get_pos_grid_index(mmp_ctrl_pos))
        end
      else
        mmp_ctrl = false
        mmp_ctrl_fade = CURSOR_FADE_MIN
        mmp_highlight_gid = nil
      end
      local pos, motion = gt:get_mouse_screen_pos()
      mouse_probe:update(mouse_cursor, {x=pos.X, y=pos.Y, motion_x=motion.X, motion_y=motion.Y,
        down=Input.IsMouseBtnPressed(0), active=false})
    end
    if prep_alarm then
      prep_alarm = false
    end
    if tele_cd > 0 then
      tele_cd = tele_cd - 1
    end
end
--
function gt:new_room()
    last_crd = crd
    gt:get_grid_room()
    gt:get_room_neighbours()
    gt:sweep_doors()
    room = Game():GetRoom()
    crd = level:GetCurrentRoomDesc()
    crid = crd.SafeGridIndex
    stage = level:GetStage()
    gt:land_at_door()
    if tele_maze then
      level:AddCurse(LevelCurse.CURSE_OF_MAZE,false)
      tele_maze = false
    end
    if last_crd.Data then
      if last_crd.Data.Type == 7 or (last_crd.Data.Type == 8 and Game():IsGreedMode()) then
        if not secret_pre_room_id[last_crd.SafeGridIndex] then
          local dim = gt:get_current_dimension()
          if (level:GetRoomByIdx(last_crd.SafeGridIndex + 1,dim)).ListIndex == crd.ListIndex then
            secret_pre_room_id[last_crd.SafeGridIndex] = last_crd.SafeGridIndex + 1
          elseif (level:GetRoomByIdx(last_crd.SafeGridIndex - 1,dim)).ListIndex == crd.ListIndex then
            secret_pre_room_id[last_crd.SafeGridIndex] = last_crd.SafeGridIndex - 1
          elseif (level:GetRoomByIdx(last_crd.SafeGridIndex + 13,dim)).ListIndex == crd.ListIndex then
            secret_pre_room_id[last_crd.SafeGridIndex] = last_crd.SafeGridIndex + 13
          elseif (level:GetRoomByIdx(last_crd.SafeGridIndex - 13,dim)).ListIndex == crd.ListIndex then
            secret_pre_room_id[last_crd.SafeGridIndex] = last_crd.SafeGridIndex - 13
          end
        end
      end
    end
    if crd.Data.Type == 7 or (crd.Data.Type == 8 and Game():IsGreedMode()) then
      gt:pre_secret_room()
    elseif crd.Data.Type == 10 then
      gt:pre_secret_curse_room()
    end
    -- 门图一变就写（dirty 去重，不会每帧写）—— 不依赖退出路径是否触发，见 design §3.5
    gt:save_door_state()
end
--
function gt:new_level()
    level = Game():GetLevel()
    gt:get_grid_room()
    gt:get_room_neighbours()
    n_room_num = (level:GetRooms()).Size
    secret_pre_room_id = {}
    secret_diag_logged = {}
    -- 免按键取证的去重表（gtp_travel 里）：每层清空，免得跨层误判为「已记过」
    if gt.travel_reset_probe_log then
      gt:travel_reset_probe_log()
    end
    --a new floor: everything learned about the old one goes
    gt:reset_door_floor()
    --
    -- 重开（长按 TAB + R）时光标必须重新定位（2026-10-05 用户报的 bug）：
    -- 那张局是「玩家一直按着 TAB」—— 光标在重开前就已经呼出（mmp_ctrl = true），
    -- 于是新局里 tab_action() 走的是「已在呼出中」的移动分支，mmp_ctrl_pos 还是上一局
    -- 留下的屏幕坐标；地图重绘后它落在另一间房上，松手就直接传到那间房去。
    -- （重新按一次 TAB 反而是对的，因为那会走「首次呼出」分支按当前房间定位）。
    -- 所以换层/开新局一律把光标状态清空：下一帧 tab_action 会当成首次呼出，重新定位到当前房间。
    -- ⚠️ 只清一次不够（用户 2026-10-05 实测：TAB+R 间隔短时仍错位）—— 重定位那一刻，
    -- MinimapAPI 的地图（锚点）或我们文件级 local 的房间缓存可能还没刷新完，先后取决于回调与帧。
    -- 所以真正的兜底在 tab_action：玩家没自己动过光标（mmp_ctrl_moved == false）时**每帧**都贴回
    -- 当前房间（不设时间窗口 —— 先试过「30 帧内归位」，实测不够），几帧内自愈；
    -- 另有 get_current_room_cursor_gid 改读实时房间。二者见各自的注释。
    -- 覆盖范围：MC_POST_NEW_LEVEL + MC_POST_GAME_STARTED（开局、R 重开、控制台 rewind）。
    mmp_ctrl = false
    mmp_ctrl_pos = Vector(0, 0)
    mmp_highlight_gid = nil
    mmp_ctrl_moved = false
    mmp_ctrl_fade = CURSOR_FADE_MIN
    mouse_cursor:reset()
    -- 注意：这里**不要**放任何依赖玩家实体的逻辑（例如 gt:can_open_cursor）—— new_level 会在
    -- POST_GAME_STARTED（开局初始化中）被调到，那时玩家实体还没就绪，会原生崩溃（2026-10-05 踩过）。
end
--
-------------------------------
-- 生命周期编排保留在适配层；菜单内容与语言表独立维护。
require("scripts.gtp_menu")(gt)
require("scripts.gtp_doorpenalty_runtime")(gt)
gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
  gt:prep()
  gt:new_room()
  gt:new_level()
  gt:register_menu()
end)
-- 退出游戏时把门图落盘（「门图一变就写」已覆盖大部分情形，这条是多一层保险）。
-- ⚠️ 各退出路径（退出到桌面 / Alt+F4 / 崩溃）是否都触发未实测，所以不把它当唯一保障。
if ModCallbacks.MC_PRE_GAME_EXIT then
  gt:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function()
    pcall(gt.save_door_state, gt)
  end)
end
gt:AddCallback(ModCallbacks.MC_POST_RENDER, gt.step)
gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, gt.new_room)
gt:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, gt.new_level)
-- 传送准入逐关卡诊断：gtpdiag [格子编号]（缺省 = 光标所在格子）。
-- 站在当前房间、把光标移到传不进去的房间上，跑 gtpdiag，
-- 输出会标出目标死在哪一道判定上。
function gt:dump_tele_diag(gid)
  local L = {}
  local function p(s) L[#L + 1] = s end
  if not gid or grid_room[gid] == nil then
    gid = gt:get_cursor_grid_index(mmp_ctrl_pos)
  end
  p("teleDiag: target gid=" .. tostring(gid))
  -- 判定结论与理由：由判定层逐段跑一遍规则表（含短路），不再在这里重抄一份判定。
  -- 下面各段是「现场证据」——它们不决定任何事，只是把状态下打出来供对照。
  if gt.travel_verdict_dump then
    p(gt:travel_verdict_dump(gid, true))
  end
  local trd = grid_room[gid]
  if not trd then
    p("  NOT in grid_room (cursor not on any displayed room cell)")
    return table.concat(L, "\n")
  end
  local dlink, dswept = door_graph()
  p(string.format(
    "  target: type=%d shape=%d visited=%d clear=%s dispFlags=0x%x bit1=%s sgi=%d gi=%d list=%d",
    trd.Data.Type, trd.Data.Shape, trd.VisitedCount, tostring(trd.Clear),
    trd.DisplayFlags, (trd.DisplayFlags & 1) ~= 0 and 1 or 0,
    trd.SafeGridIndex, trd.GridIndex, trd.ListIndex))
  p("  displayed(cursor can hit)=" ..
    tostring(gt:is_grid_room_displayed(gid)) ..
    " minapiFlags=" .. tostring(gt:get_minapi_display_flags(trd.ListIndex)))
  p(string.format(
    "  current room: sgi=%d name=%s clear=%s swept=%s doorsRead=%s",
    crd.SafeGridIndex, tostring(crd.Data and crd.Data.Name), tostring(crd.Clear),
    tostring(dswept[crd.SafeGridIndex]),
    tostring(dlink[crd.SafeGridIndex] ~= nil)))
  -- 道具入口禁令（牌意解读 / 天堂阶梯）：每一项都拆开打，方便看出是哪一步拦下的
  p("  startRoomLock=" .. tostring(gt:start_room_lock()) ..
    " (hasEntrance=" .. tostring(gt:has_start_room_entrance()) ..
    " curType=" .. tostring(crd.Data and crd.Data.Type) ..
    " startGid=" .. tostring(level:GetStartingRoomIndex()) ..
    " ascent=" .. tostring(level:IsAscent()) ..
    " cardReading=" .. tostring(player and player:HasCollectible(
      CollectibleType.COLLECTIBLE_CARD_READING)) ..
    " stairway=" .. tostring(player and player:HasCollectible(
      CollectibleType.COLLECTIBLE_STAIRWAY)) .. ")")
  -- 房间里出现过哪些实体（type/variant，去重，最多 16 项）：既能看清初始房里道具入口
  -- 长什么样（牌意解读的传送门 / 天堂阶梯的台阶），也是以后改「按实体判定」的第一手数据
  do
    local list = room:GetEntities()
    local seen, uniq = {}, {}
    if list then
      for i = 0, list.Size - 1 do
        local e = list:Get(i)
        if e then
          local k = tostring(e.Type) .. "/" .. tostring(e.Variant)
          if not seen[k] then
            seen[k] = true
            uniq[#uniq + 1] = k
            if #uniq >= 16 then break end
          end
        end
      end
    end
    p("  room entity types=" .. (#uniq > 0 and table.concat(uniq, " ") or "none"))
  end
  -- 当前房间的每一扇门：隐藏门炸开后 variant 会从 7 变成 8、busted 变 true，
  -- 这一行既是「洞口开没开」的现场证据，也是判断门图该不该记录它的依据
  for i = 0, 7 do
    local door = room:GetDoor(i)
    if door then
      local busted, canblow, isopen = "-", "-", "-"
      local passage = "-"
      pcall(function()
        busted = tostring(door.IsBusted and door:IsBusted() or door.Busted)
        canblow = tostring(door.CanBlowOpen and door:CanBlowOpen())
        isopen = tostring(door:IsOpen())
        passage = tostring(gt:door_is_passage(door))
      end)
      p("  door slot=" .. i ..
        " variant=" .. tostring(door.Desc and door.Desc.Variant) ..
        " busted=" .. busted .. " canBlowOpen=" .. canblow ..
        " isOpen=" .. isopen ..
        " passage=" .. passage ..
        " targetIdx=" .. tostring(door.TargetRoomIndex) ..
        " targetType=" .. tostring(door.TargetRoomType))
    end
  end
  -- 奖励门（恶魔房 / 天使房 / Boss Rush / 死寂）：命中即禁传，见 gtp_bosswindow.lua
  -- （模块在 gtrep 之后加载，这里运行时取，取不到就跳过）
  if gt.has_reward_door then
    p("  rewardDoor=" .. tostring(gt:has_reward_door()))
  end
  -- 本层全部隐藏房
  for g, rd in pairs(grid_room) do
    if gt:is_secret_room(rd) then
      p("  secret room gid=" .. tostring(g) ..
        " list=" .. tostring(rd.ListIndex) ..
        " sgi=" .. tostring(rd.SafeGridIndex) ..
        " visited=" .. tostring(rd.VisitedCount) ..
        " clear=" .. tostring(rd.Clear) ..
        " flags=" .. tostring(rd.Flags) ..
        " dispFlags=" .. tostring(rd.DisplayFlags))
    end
  end
  -- 可达岛：下面四邻证据要用它的 inReach 字段。
  -- 判定结论本身已由上面的 travel_verdict_dump 给出，这里不再重算一遍结论。
  local reach = gt:get_config_bool("FairTripPath", true) and gt:get_reachable_rooms() or nil
  -- 目标四邻逐个体检（widen 通道 C 的证据链）
  local tid = trd.SafeGridIndex
  local col = tid % 13
  local offs = {tid - 13, tid + 13}
  if col > 0 then offs[#offs + 1] = tid - 1 end
  if col < 12 then offs[#offs + 1] = tid + 1 end
  for _, nid in ipairs(offs) do
    local rd = grid_room[nid]
    if rd then
      p(string.format(
        "  neighbor gid=%d: type=%d visited=%d clear=%s dispBit1=%s inReach=%s linkedToTarget=%s",
        nid, rd.Data.Type, rd.VisitedCount, tostring(rd.Clear),
        (rd.DisplayFlags & 1) ~= 0 and 1 or 0,
        reach and tostring(reach[rd.SafeGridIndex] == true) or "-",
        tostring(gt:rooms_linked(rd.SafeGridIndex, trd.SafeGridIndex))))
    end
  end
  return table.concat(L, "\n")
end

-- 传送现场自动落盘：光标停在隐藏房上（或干脆落不到任何格子上）时，把一次完整的
-- 准入判定写进 log.txt。复现「炸开的隐藏房传不进去」只需按住 TAB 瞄一下、松手，
-- 不必手输控制台命令；按「层 + 目标格」去重，不会刷屏。
-- 本房间紧邻的隐藏房格子（光标落不到格子时用它当目标，报告才有内容）
function gt:adjacent_secret_gid()
  local cells = {}
  for cell, rd in pairs(grid_room) do
    if rd.ListIndex == crd.ListIndex then
      cells[cell] = true
    end
  end
  for cell in pairs(cells) do
    local col = cell % 13
    for _, step in ipairs({ -13, 13, -1, 1 }) do
      if not ((step == -1 and col == 0) or (step == 1 and col == 12)) then
        if gt:is_secret_room(grid_room[cell + step]) then
          return cell + step
        end
      end
    end
  end
  return nil
end

function gt:auto_log_secret_diag(gid)
  -- 只在调试模式下自动落盘（MCM 的 Debug Mode 开关，或 gtconfig.lua 的 gt.DebugMod = true）：
  -- 正式游玩时不往 log.txt 写这些行，免得每次瞄隐藏房都刷十几行；
  -- 「按住地图键 + 键盘 F4」的手动 dump 同样归这个开关管（2026-10-05 起）。
  if not gt:is_debug() then
    return
  end
  if gid == -99 then
    gid = gt:adjacent_secret_gid()
    if not gid then return end
  end
  if not gt:is_secret_room(grid_room[gid]) then
    return
  end
  local key = tostring(level:GetStage()) .. "_" .. tostring(crd.SafeGridIndex) ..
    "_" .. tostring(gid)
  if secret_diag_logged[key] then
    return
  end
  secret_diag_logged[key] = true
  -- DebugMod 下：控制台 + log.txt 一次给全，连按键都不用（不再画屏幕浮层）
  gt:console_dump_diag(gid, "secretDiag")
end

-- MinimapAPI 对某 ListIndex 房间的显示旗标（诊断用；查不到返回 nil）
function gt:get_minapi_display_flags(listIndex)
  if not MinimapAPI then return nil end
  local map = MinimapAPI:GetLevel(gt:get_current_dimension())
  if not map then return nil end
  for _, mapRoom in ipairs(map) do
    if mapRoom.Descriptor and mapRoom.Descriptor.ListIndex == listIndex then
      return mapRoom:GetDisplayFlags()
    end
  end
  return nil
end

-- ===== 诊断字体 =====
-- 控制台命令在部分环境（REPENTOGON 的 ImGui「Repentance+ Console」）里不会
-- 分发给 MC_EXECUTE_CMD —— 实测输入 gtpdiag 触发不了我们的回调（log 里连
-- 「命令触发了」的留痕都没有）。所以诊断一律走**控制台 + log.txt** 两条路。
--
-- 注：曾经还有一条「把 dump 画在屏幕左上角、15 秒后消失」的**黄色浮层**。
-- 2026-10-06 按用户要求**删除** —— 它只是挡视线，而同样的内容 log.txt 里读得到。
-- **屏幕上只剩红色的「传送理由浮层」**（gtp_travel，跟着光标实时变、松手即消失）。
local diag_font = nil

-- 诊断字体（惰性加载一次）。供红色理由浮层用。
-- ⚠️ `font/terminus.fnt` 是**位图 ASCII 字体，画不出中文** —— 屏幕路径上只能放 ASCII，
-- 中文散文留在 log.txt / 控制台。
function gt:get_diag_font()
  if not diag_font then
    local ok, font = pcall(function()
      local f = Font()
      f:Load("font/terminus.fnt")
      return f
    end)
    if not ok or not font then
      return nil
    end
    diag_font = font
  end
  return diag_font
end

-- 逐行把诊断文本写进控制台输出缓冲（Isaac.ConsoleOutput 不认多行字符串，
-- 整段丢进去容易只看到一行，所以自己按 \n 拆）
local function gt_console_out(text)
  for line in tostring(text):gmatch("[^\n]+") do
    console_output(line .. "\n")
  end
end

-- 统一诊断出口：控制台命令、TAB+F4、DebugMod 自动 dump 都走这里。
-- ⚠️ 返回值一律 nil：MC_EXECUTE_CMD 的返回值会被引擎逐行打印到控制台，
-- 而本机（REPENTOGON 的 ImGui 控制台）**返回多行字符串会当场闪退**
-- （2026-10-03 实测：日志里我们的输出打印完立刻 "Lua stack trace:"（空栈）+
-- "Caught exception, writing minidump..."；同一环境里 MinimapAPI 的 mapitel
-- 返回 nil 就能正常工作）。所以只走 ConsoleOutput（逐行直写，安全）+ DebugString，
-- 不碰返回值。**不再画屏幕浮层**（黄色那条 2026-10-06 已删）。
function gt:console_dump_diag(gid, tag)
  local ok, result = pcall(gt.dump_tele_diag, gt, gid)
  if not ok then
    result = "teleDiag ERROR: " .. tostring(result)
  end
  local name = "GoodTripPlus " .. (tag or "gtpdiag")
  result = "===== " .. name .. " BEGIN =====\n" .. tostring(result) ..
    "\n===== " .. name .. " END ====="
  gt_console_out(result)
  Isaac.DebugString(result)
end

-- 控制台诊断命令：gtpdiag [格子编号]（缺省 = 光标所在格子）、gtmapdiag；gtpd 是简写。
-- 输出通道（**不要返回字符串**，见上）：
--   ConsoleOutput  —— 逐行直写控制台输出（MinimapAPI 的 mapitel 也是这么做的，安全）
--   DebugString    —— 落 log.txt（最可靠的一条）
-- 两个坑：①回调签名是 (Mod, command, args)，command 只有命令词，格子编号在 args 里；
-- ②原版控制台要**再按一次回车 / 输入别的**才会把这批行刷出来，看到「没输出」先别急。
gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command, args)
  -- 解析尽量宽容：大小写、前后空格、以及「有的环境把整行塞进 command」
  local cmd, inline = tostring(command or ""):match("^%s*(%S+)%s*(.*)$")
  cmd = cmd and cmd:lower() or ""
  if cmd ~= "gtpdiag" and cmd ~= "gtpd" and cmd ~= "gtmapdiag" then
    return
  end
  local rest = type(args) == "string" and args or inline
  rest = tostring(rest or ""):match("^%s*(.-)%s*$")
  -- 先把「命令确实触发了」写进 log.txt（含版本与原始入参），免得再出现
  -- 「没输出」时无从判断到底是没触发还是没显示
  Isaac.DebugString("[GoodTripPlus] v" .. tostring(gt.VERSION) ..
    " console command: '" .. tostring(command) .. "' args=" .. tostring(args))
  -- 全部 return nil：返回值会被引擎拿去打印，多行串在本机环境会闪退
  if cmd == "gtmapdiag" then
    local ok, result = pcall(gt.dump_map_diagnostics, gt)
    local text = ok and "gtmapdiag: done (details in log.txt)"
      or ("gtmapdiag ERROR: " .. tostring(result))
    gt_console_out(text)
    Isaac.DebugString(text)
    return
  end
  local gid = rest ~= "" and tonumber(rest) or nil
  gt:console_dump_diag(gid, "gtpdiag v" .. tostring(gt.VERSION))
end)
--
-- Draw the cursor on whichever render callback MinimapAPI itself draws its
-- minimap on (see the comment on gt:render_cursor above), using a later
-- priority so the cursor is guaranteed to be drawn after — and therefore on
-- top of — MinimapAPI's own minimap art within that same callback.
do
  local is_repentance = REPENTANCE or REPENTANCE_PLUS
  local late_priority = (CallbackPriority and CallbackPriority.LATE) or 1000

  if REPENTOGON then
    gt:AddPriorityCallback(ModCallbacks.MC_POST_HUD_RENDER, late_priority, gt.render_cursor)
    gt.renderCallback = "MC_POST_HUD_RENDER (REPENTOGON)"
  elseif StageAPI and StageAPI.Loaded then
    StageAPI.AddCallback("GoodTripPlus", "POST_HUD_RENDER", 1, gt.render_cursor)
    gt.renderCallback = "StageAPI POST_HUD_RENDER"
  elseif is_repentance then
    gt:AddPriorityCallback(ModCallbacks.MC_POST_RENDER, late_priority, gt.render_cursor)
    gt.renderCallback = "MC_POST_RENDER (priority)"
  else
    gt:AddCallback(ModCallbacks.MC_POST_RENDER, gt.render_cursor)
    gt.renderCallback = "MC_POST_RENDER (plain)"
  end
end

-- 启动尾声：把「跑在哪个环境、走的哪条渲染回调」写进 log.txt。
-- 排查「REPENTOGON 到底有没有在跑」（用 rgon 启动器 vs 直接启动 exe 是两种环境）、
-- 「画不出来是不是回调选错」时，看这一行就够了。
pcall(function()
  Isaac.DebugString("[GoodTripPlus] ready: repentogon=" .. tostring(REPENTOGON) ..
    " postHudRender=" .. tostring(ModCallbacks.MC_POST_HUD_RENDER ~= nil) ..
    " render=" .. tostring(gt.renderCallback))
end)
