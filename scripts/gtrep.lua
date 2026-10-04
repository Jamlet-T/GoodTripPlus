gt = RegisterMod("GoodTripPlus", 1)
-- 版本号：与 metadata.xml 保持一致。log.txt 里靠这一行确认「实际加载的是哪一版」，
-- 排查「改了没生效 / 没重启」时是第一手证据。
gt.VERSION = "2.0.0"
pcall(function()
  Isaac.ConsoleOutput("[GoodTripPlus] v" .. gt.VERSION ..
    " loaded (console command: gtpdiag)\n")
  Isaac.DebugString("[GoodTripPlus] v" .. gt.VERSION .. " loaded")
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
local door_link = {}  --door_link[dim][a][b]: a passage, seen from either end
local door_swept = {} --door_swept[dim][a]: a's own walls were read
--curse-room door spikes seen from outside / inside; Flat File strips only the
--side it was used on, so the two are kept apart
local curse_bare_outside, curse_bare_inside = {}, {}
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
gt.TeleportAnimation = true
gt.FollowCurseOfLost = true
-- 传送范围（本项目合并原 Fixed 的 AllowNeighborRoom + AllowAnyRoom 两项）：
--   1 = 任意房间（原 AllowAnyRoom 开）
--   2 = 相邻房间（原默认：AllowNeighborRoom 开、AllowAnyRoom 关）
--   3 = 已探索房间（原 AllowNeighborRoom 关、AllowAnyRoom 关）
gt.TravelMode = 2
gt.FairTripPath = true
gt.ArriveAtDoor = false
gt.FairTripTime = false
gt.FastTransition = true
gt.HighlightCursorRoom = true
gt.ShowSecretMarkers = true
local _, err = pcall(require, "gtconfig")
----
local debug = gt.DebugMod
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
    local d = Game():GetRoom():IsMirrorWorld() and 1 or 0
    door_link[d] = door_link[d] or {}
    door_swept[d] = door_swept[d] or {}
    return door_link[d], door_swept[d]
end

-- 必须炸开（或用钥匙打开）墙才能进的三种隐藏房：
-- 7 = ROOM_SECRET、8 = ROOM_SUPERSECRET、29 = ROOM_ULTRASECRET（红钥匙房）
--
-- 实测（2026-10-03，gtpdiag 门表，用户现场复现）：
--   墙还在   → variant=7(DOOR_HIDDEN) busted=false canBlowOpen=true  isOpen=false
--   已炸开   → variant=8(DOOR_UNLOCKED) busted=true  canBlowOpen=false isOpen=true
-- 也就是说炸开之后**变体确实会变**，Fixed 门图里那句
-- `door.Desc.Variant ~= DoorVariant.DOOR_HIDDEN` 是对的（已炸开的洞口本来就会被记进门图），
-- 所以这里不需要、也不该再加别的「已炸开」判据（曾经加过 hidden_door_open，已删）。
-- 真正卡住传送的是 check_neigh_connected 里那份「已显示但未探索目标」的类型白名单：
-- 隐藏房不在名单里 → 还没进去过的隐藏房一律拦，哪怕洞口已经炸开。
function gt:is_secret_room(rd)
    if not rd or not rd.Data then
      return false
    end
    local t = rd.Data.Type
    return t == 7 or t == 8 or t == 29
end

--read the current room's doors (the only room the game answers for) into the
--graph both ways. DOOR_HIDDEN is an unbombed wall, so no passage; everything
--else, locked included, is walkable. All read live so nothing is from different moments.
function gt:sweep_doors()
    local live = Game():GetRoom()
    local lvl = Game():GetLevel()
    local here = lvl:GetCurrentRoomDesc().SafeGridIndex
    local link, swept = door_graph()
    link[here] = link[here] or {}
    swept[here] = true
    for i = 0, 7 do
      local door = live:GetDoor(i)
      --DOOR_HIDDEN is an unbombed wall, so no passage; everything
      --else, locked included, is walkable. All read live so nothing is from different moments.
      --（实测：炸开之后 variant 会变成 8，所以这行判据本身就够用，别再加「已炸开」判据）
      if door and door.Desc.Variant ~= DoorVariant.DOOR_HIDDEN then
        local tdes = lvl:GetRoomByIdx(door.TargetRoomIndex, -1)
        if tdes then
          local there = tdes.SafeGridIndex
          --curse-room spikes are read off the door itself: Flat File strips them
          --once and for good, so the trinket in hand says nothing about this door
          if door.TargetRoomType == RoomType.ROOM_CURSE then
            curse_bare_outside[there] = door.VarData ~= 0
          elseif live:GetType() == RoomType.ROOM_CURSE then
            curse_bare_inside[here] = door.VarData ~= 0
          end
          if there ~= here then
            --this end knows its slot; the far end gets a bare mark until its own turn
            link[here][there] = i
            link[there] = link[there] or {}
            if link[there][here] == nil then link[there][here] = true end
          end
        end
      end
    end
end

--may a trip step between these rooms? A passage seen from either end: yes. A
--swept room saying nothing: no. Neither swept (mod loaded mid-run): grid adjacency stands.
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

--may I go there: the predicates a trip is checked against, the reachable set,
--the fair distance, the door a walk would have come in by.
function gt:check_neigh_connected(trd, cond)
    local tid = trd.SafeGridIndex
    if (trd.DisplayFlags & 1) ~= 0 then
      --a red-key room stands open already, whatever it turned out to hold
      -- 本 mod 对 Fixed 的一处偏离（2026-10-03，理由 + 实测）：
      -- Fixed 这份「已显示但未探索目标」的类型白名单只放普通房(1)/boss(5)/小 boss(6)/
      -- 献祭(13)，隐藏房(7/8/29)不在里面 —— 于是**洞口已经炸开**的隐藏房照样被拦
      -- （用户报的「炸开隐藏房传不进去」就是这个）。放行后安全性由调用方保证：
      -- 最后一步还要求 rooms_linked(邻居, 目标)，而实测炸开洞口在门图里有真门
      -- （variant 7 -> 8），没炸开的墙没有 → 「已炸开的能进、还封着的进不去」。
      if (trd.VisitedCount == 0 or not trd.Clear) and
        trd.Flags & RoomDescriptor.FLAG_RED_ROOM == 0 and
        not gt:is_secret_room(trd) and
        trd.Data.Type ~= 1 and trd.Data.Type ~= 5 and
        trd.Data.Type ~= 6 and trd.Data.Type ~= 13 and
        not (((stage == 1 and level:GetStageType() < StageType.STAGETYPE_REPENTANCE) or room:IsMirrorWorld())
                and ((not Game():IsGreedMode() and trd.Data.Type == 4) or trd.Data.Type == 2)) then --free: stage-1 normal floor, or Downpour/Dross mirror world
        return false
      end
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

--is this curse-room door free? Isaac's Heart / Tooth and Nail take the hit.
--Flat File acts on the door as the room is laid down, so the trinket in hand
--only answers for a door about to be laid down again, not the one stood beside
function gt:curse_toll_free(gid, by_inner_door, room_reloads)
    local p = player
    if p:HasCollectible(276) or p:HasCollectible(663) then
      return true
    end
    if room_reloads and p:HasTrinket(151) then
      return true
    end
    local bare = curse_bare_outside[gid]
    if by_inner_door then bare = curse_bare_inside[gid] end
    return bare == true
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
    if not p then
      return false
    end
    if not (p:HasCollectible(CollectibleType.COLLECTIBLE_CARD_READING)
        or p:HasCollectible(CollectibleType.COLLECTIBLE_STAIRWAY)) then
      return false
    end
    return gt:has_start_room_entrance()
end

function gt:check_teleble(gid)
    if gid == -99
    or (gt:get_config_bool("FollowCurseOfLost", true)
        and level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST ~= 0) then
      return false
    elseif debug and grid_room[gid] then
      return true
    elseif gt:start_room_lock() then
      -- 牌意解读 / 天堂阶梯：刚进层、还没离开初始房间 → 禁止传送（别顶掉道具效果）
      return false
    end
    local cid = crd.SafeGridIndex
    if grid_room[cid] == nil or not crd.Clear then
      return false
    elseif (crd.Data.Type == 6 or crd.Data.Type == 11) then --miniboss/challengeroom
      if not gt:check_room_open() then
        return false
      end
    end
    if gid == false then return true end --current room only
    if grid_room[gid] == nil then
      return false
    else
      local trd = grid_room[gid]
      if trd.ListIndex == crd.ListIndex then
        return false
      end
      local travel_mode = gt:get_travel_mode()
      if travel_mode == 1 then
        -- 任意房间：地图上任何已显示房间都放行（等价旧的 AllowAnyRoom=开）
        return true
      end
      --the room stepped off from must be on the player's own island, else an
      --Emperor'd boss room is a free lift back across unexplored rooms
      local reach = gt:get_config_bool("FairTripPath", true) and gt:get_reachable_rooms() or nil
      if trd.VisitedCount > 0 and trd.Clear
          and (not reach or reach[trd.SafeGridIndex] == true) then
        --travel_mode=2 only widens this: an Emperor'd start room has no cleared neighbour
        return true
      elseif travel_mode == 3 then
        -- 已探索房间：只认自己已清怪的房，不做邻居豁免（等价旧的 AllowNeighborRoom=关）
        return false
      end
      --the last hop needs a door too; `reach` is nil exactly when path rules are off
      return gt:check_neigh_connected(trd, function(rd)
          return (rd.DisplayFlags & 1 ~= 0) and rd.VisitedCount > 0 and rd.Clear
            and (not reach or (reach[rd.SafeGridIndex]
              and gt:rooms_linked(rd.SafeGridIndex, trd.SafeGridIndex)))
      end)
    end
end
--
function gt:hurt(n)
  player:TakeDamage(n, DamageFlag.DAMAGE_CURSED_DOOR | DamageFlag.DAMAGE_NO_PENALTIES, EntityRef(player), 0)
end
--
function gt:tele_failed()
  sfx:Play(187, 0.5, 0, false, 1)
end
--
function gt:check_curse_room(gid)
    if debug then return end
    --a bombed secret-room wall has no spikes, so secret<->guard room is free
    --both ways, even when the guard is the curse room
    if secret_pre_room_id[crid] == gid or secret_pre_room_id[gid] == crid then
      return
    end
    local trd = grid_room[gid]
    if crd.Data.Type == 10 then
      if not gt:curse_toll_free(crd.SafeGridIndex, true, false) then
        gt:hurt(1)
      end
    elseif trd.Data.Type == 10 and not player:IsFlying() then
      if not gt:curse_toll_free(trd.SafeGridIndex, false, true) then
        gt:hurt(1)
      end
    end
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
function gt:teleport_to_grid_index(gid)
    for _,en in pairs(Isaac.GetRoomEntities()) do
			if en.Type == 867 then
        gt:tele_failed()
        return
			end
		end
    -- Mom / Ultra Greed 房：Fixed 里一律禁传（连清完怪之后也禁），防的是它们清怪后的
    -- 后续流程被传送打断（Mom 房的门、Ultra Greed 房的奖杯）。但**回溯线（The Ascent）里
    -- 的 Mom 房只是路过** —— boss 早在正着走时就打完了（Clear=true），房间里没有任何后续
    -- 流程，拦它反而把正常传送拦掉（用户 2026-10-03 实测：回溯线 Depths II 的 boss 房能
    -- 呼出光标、能移到格子，松手却只响失败音；dump 显示 startRoomLock=false / clear=true /
    -- type=5 / 房间里没有 867，唯一命中的就是这一条）。所以回溯线上放行这一条。
    if not level:IsAscent()
        and (crd.Data.Name == "Mom" or crd.Data.Name == "Ultra Greed") then
      gt:tele_failed()
      return
    elseif grid_room[gid].Data.Type == 11 and not grid_room[gid].ChallengeDone then
      if stage%2 == 0 and stage ~= 10 then
        if player:GetHearts()+player:GetSoulHearts()+ player:GetBlackHearts() > 2 then
          gt:tele_failed()
          return
        end
      else
        if player:GetHearts() + player:GetSoulHearts() + player:GetBlackHearts() < player:GetMaxHearts() then
          gt:tele_failed()
          return
        end
      end
    end
    gt:check_curse_room(gid)
    level.EnterDoor = -1
    level.LeaveDoor = -1
    if level:GetCurses() & LevelCurse.CURSE_OF_MAZE ~= 0 then
      level:RemoveCurses(LevelCurse.CURSE_OF_MAZE)
      tele_maze = true
    end

    local dist = 0
    if gt:get_config_bool("FairTripTime", false) then
      dist = gt:fair_trip(crd.SafeGridIndex, gid)
      if dist == 999 then
        gt:tele_failed()
        return
      end
    end

    --an L room's anchor cell is not in grid_room, so the antechamber may be missing
    local from_pre = crd.Data.Type == 7 and secret_pre_room_id[crid] or nil
    local from_prd = from_pre and grid_room[from_pre] or nil
    if from_prd then --from secret room
      if from_prd.ListIndex == grid_room[gid].ListIndex then
        gid = from_pre
      elseif not (grid_room[gid].Data.Type == 10 and secret_pre_room_id[gid] and secret_pre_room_id[gid] == crid) then
        --the toll is for the curse room's own door on the far side, not the bombed hole
        if from_prd.Data.Type == 10 and not gt:curse_toll_free(from_prd.SafeGridIndex, true, true) then
          gt:hurt(1)
        end
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
          if to_prd.Data.Type == 10 and not player:IsFlying()
              and not gt:curse_toll_free(to_prd.SafeGridIndex, false, true) then
            gt:hurt(1)
          end
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
    if gt:get_config_bool("ArriveAtDoor", false) then
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
    if debug then
      Game():ChangeRoom(arrive,-1)
    else
        if dist ~= 0 then
          local speed = player.MoveSpeed
          local addTime = math.floor((60.0*dist/speed)+0.5)
          Game().TimeCounter = Game().TimeCounter + addTime --boss rush reads TimeCounter; Hush does not
        end
      tele_cd = 45
      if not gt:get_config_bool("TeleportAnimation", true) then tele_cd = 10 end
      if debug or gt:get_config_bool("FastTransition", true) then tele_cd = 1 end
    end
    if gt:get_config_bool("FastTransition", true) or debug then
      Game():ChangeRoom(arrive,-1)
      Game():GetRoom():PlayMusic()
      return
    end
    local tele_anime = gt:get_config_bool("TeleportAnimation", true) and 3 or 1
    Game():StartRoomTransition(arrive, Direction.NO_DIRECTION, tele_anime, player, -1) --direction is ignored, measured twice
    tele_cd = tele_anime == 3 and 45 or 10
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
      Isaac.ConsoleOutput("[GoodTripPlus] " .. message .. "\n")
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
      -- 与 gid_to_rtmap_pos 同一套投影（含同一锚点），直接复用
      for gid, rd in pairs(grid_room) do
        if gt:is_grid_room_displayed(gid) then
          local p = gt:gid_to_rtmap_pos(gid)
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
function gt:gid_to_rtmap_pos(gid)
    if MinimapAPI then
      local offsetVec = gt:get_minapi_offset_vec()
      local gsx = MinimapAPI.GlobalScaleX or 1
      local col = gid % 13
      local row = math.floor(gid / 13)
      local maxx, miny = gt:get_minapi_map_anchor()
      local rx, ry
      if maxx and miny then
        -- 与 renderUnboundedMinimap 同锚点：roomOffset = (gsx*pos - maxx) * 房宽
        if gsx >= 0 then
          rx = offsetVec.X + (col * gsx - maxx) * 17 + 9
        else
          rx = offsetVec.X + (col * gsx - maxx) * 17 - 17
        end
        ry = offsetVec.Y + (row - miny) * 15 + 8
      else
        -- 还没有任何显示房间（大地图本就什么都不画）时的旧回退
        local ltroom = gt:get_corner_room(1)
        local rtroom = gt:get_corner_room(2)
        if gsx >= 0 then
          rx = offsetVec.X + (col - rtroom.X - 1) * 17 + 9
        else
          rx = offsetVec.X + (ltroom.X - col) * 17 - 17
        end
        ry = offsetVec.Y + (row - ltroom.Y) * 15 + 8
      end
      return Vector(rx, ry)
    end
    local ltx, lty = gt:get_rtmap_info()
    local col = gid % 13
    local row = (gid - col) / 13
    return Vector(ltx + col * 17 + 8, lty + row * 15 + 7)
end
--
function gt:get_current_room_cursor_gid()
    local gid = crd.SafeGridIndex
    if not crd.Data then
      return gid
    end

    local tl = room:GetTopLeftPos()
    local br = room:GetBottomRightPos()
    local isRight = player.Position.X >= (tl.X + br.X) / 2
    local isBottom = player.Position.Y >= (tl.Y + br.Y) / 2
    local shape = crd.Data.Shape

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
    return crd.SafeGridIndex
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
end
--
function gt:get_cursor_speed()
    if ModConfigMenu and ModConfigMenu.Config["GoodTripPlus"] then
        return ModConfigMenu.Config["GoodTripPlus"]["CursorSpeed"] or 2
    end
    return 2
end
--
function gt:mmp_ctrl_move()
    local speed = gt:get_cursor_speed()
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
      if Input.IsActionPressed(key[i], player.ControllerIndex) then
        local newpos = mmp_ctrl_pos + dir[i] * speed
        if newpos.X >= xmin and newpos.Y >= ymin and newpos.X <= xmax and newpos.Y <= ymax then
          mmp_ctrl_pos = newpos
        end
      end
    end
end
--
function gt:draw_rtmap_cursor()
    cursor:Render(mmp_ctrl_pos, Vector(0, 0), Vector(0, 0))
end
--
function gt:update_cursor_room_highlight()
    local gid = gt:get_pos_grid_index(mmp_ctrl_pos)
    if gt:check_teleble(gid) then
      mmp_highlight_gid = gid
    else
      mmp_highlight_gid = nil
    end
end
--
function gt:draw_minapi_room_highlight(mapRoom, color)
    if not mapRoom or not mapRoom.RenderOffset or not mapRoom:IsVisible() then
      return
    end
    local sprite = MinimapAPI:IsLarge() and MinimapAPI.SpriteMinimapLarge or MinimapAPI.SpriteMinimapSmall
    local frame = MinimapAPI:GetRoomShapeFrame(mapRoom.Shape)
    if type(frame) ~= "number" then
      return
    end
    local animation
    if mapRoom == MinimapAPI:GetCurrentRoom() then
      animation = "RoomCurrent"
    elseif mapRoom:IsClear() then
      animation = "RoomVisited"
    elseif MinimapAPI:GetConfig("DisplayExploredRooms") and mapRoom:IsVisited() then
      animation = "RoomSemivisited"
    else
      animation = "RoomUnvisited"
    end
    sprite:SetFrame(animation, frame)
    sprite.Scale = Vector(MinimapAPI.GlobalScaleX or 1, 1)
    sprite.Color = color
    sprite:Render(mapRoom.RenderOffset, Vector(0, 0), Vector(0, 0))
end
--
-- 初始房间的绿色高亮已移除（2026-10-03）：MinimapAPI 自带
-- "Highlight Start Room"（HighlightStartRoom，其菜单里开），
-- 按项目定位（MinimapAPI 的外置传送插件）不再自己画。
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
    gt:render_diag_overlay() -- 诊断浮层（画在 HUD 之上，与地图是否按住无关）
    if mmp_ctrl then
      if gt:get_config_bool("HighlightCursorRoom", true) and mmp_highlight_gid then
        local desc = grid_room[mmp_highlight_gid]
        if desc then
          gt:draw_minapi_room_highlight(
            gt:get_minapi_room_by_list_index(desc.ListIndex),
            -- RGB multipliers of 1 preserve the original room art.  Zeroing
            -- them and applying a white RGB offset leaves only its silhouette.
            Color(0, 0, 0, 0.45, 1, 1, 1)
          )
        end
      end
      gt:draw_rtmap_cursor()
    end
end
--
function gt:prep()
    player = Isaac.GetPlayer(0)
end
--
function gt:tab_action()
    local cp = Isaac.WorldToRenderPosition(Vector(320,280))
    scpos = cp + cp
    --
    -- 免控制台诊断入口：按住地图键 + F4 → 把光标所在格（光标没启用时用当前房间）
    -- 的完整判定打到屏幕左上角 + 控制台 + log.txt。
    -- （控制台命令在 REPENTOGON 的 ImGui 控制台里不分发给 mod，所以这条是主力入口；
    -- 20 帧内连按只算一次，避免长按/连点刷屏）
    if Input.IsButtonTriggered(Keyboard.KEY_F4, player.ControllerIndex)
        and Game():GetFrameCount() - last_diag_frame > 20 then
      last_diag_frame = Game():GetFrameCount()
      local cell = mmp_ctrl and gt:get_pos_grid_index(mmp_ctrl_pos)
        or gt:get_current_room_cursor_gid()
      gt:console_dump_diag(cell, "gtpdiag TAB+F4")
    end
    --
    if Input.IsActionTriggered(ButtonAction.ACTION_RESTART, player.ControllerIndex) and fastrestartenable then
      Isaac.ExecuteCommand("restart")
    end
    --
    if gt:check_teleble(false) or debug then
      if not mmp_ctrl then
        mmp_ctrl = true
        mmp_ctrl_pos = gt:gid_to_rtmap_pos(gt:get_current_room_cursor_gid())
        gt:update_cursor_room_highlight()
      else
        gt:mmp_ctrl_move()
        gt:update_cursor_room_highlight()
        player:SetShootingCooldown(2)
      end
    end
end
--
function gt:step()
    -- 控制台命令请求的浮层延到这一帧（渲染阶段）才弹：命令处理阶段不碰 Font/资源
    if gt.diag_pending_overlay then
      gt:show_diag_overlay(gt.diag_pending_overlay)
      gt.diag_pending_overlay = nil
    end
    --a wall can open under the player's feet (bomb, red key), so sweep every
    --tick; but not mid-transition, when the live room and the cached descriptor disagree
    if level:GetCurrentRoomDesc().SafeGridIndex == crid then
      gt:sweep_doors()
    end
    if Game():IsPaused() then
      mmp_ctrl = false
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
      if mmp_ctrl and gt:check_teleble(false) then
        mmp_ctrl = false
        mmp_highlight_gid = nil
        local mgid = gt:get_pos_grid_index(mmp_ctrl_pos)
        gt:auto_log_secret_diag(mgid)
        if (gt:check_teleble(mgid) and tele_cd < 1) then
          if crd.Data.Type == 7 or (crd.Data.Type == 8 and Game():IsGreedMode()) then
            gt:pre_secret_room()
          elseif crd.Data.Type == 10 then
            gt:pre_secret_curse_room()
          end
          gt:teleport_to_grid_index(mgid)
        end
      else
        mmp_ctrl = false
      end
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
end
--
function gt:new_level()
    level = Game():GetLevel()
    gt:get_grid_room()
    gt:get_room_neighbours()
    n_room_num = (level:GetRooms()).Size
    secret_pre_room_id = {}
    secret_diag_logged = {}
    --a new floor: everything learned about the old one goes
    door_link = {}
    door_swept = {}
    curse_bare_outside, curse_bare_inside = {}, {}
end
--
-------------------------------
-- Mod Config Menu text, localized based on the game's language setting
-- (Options.Language). Anything not explicitly recognized falls back to
-- English.
local GT_STRINGS = {
  en = {
    title = "GoodTripPlus",
    cursor_speed_name = "Cursor Speed",
    cursor_speed_desc = "Pixels the cursor moves per frame while holding a direction key. Default: 2",
    follow_curse_name = "Disable On Curse Of Lost",
    follow_curse_desc = "Disable GoodTrip teleport while the floor has the Curse of the Lost. Default: enabled",
    travel_mode_name = "Can Teleport To",
    travel_mode_values = {[1] = "Any Room", [2] = "Neighbor Room", [3] = "Explored Rooms"},
    travel_mode_desc = "How far a trip may reach. Any Room: every room shown on the map. Neighbor Room: cleared rooms, plus a shown but not-yet-cleared room next to a cleared one. Explored Rooms: only rooms you have visited and cleared. Default: Neighbor Room",
    fairpath_name = "Fair Trip Path",
    fairpath_desc = "Only allow teleport to rooms reachable through cleared rooms, door by door. Default: enabled",
    arrivedoor_name = "Arrive At Door",
    arrivedoor_desc = "Arrive standing at the exact door a walk would have come in by. A far trip into a room bigger than the screen passes through the room before it, which shows for a moment. Default: disabled",
    fairtime_name = "Fair Trip Time",
    fairtime_desc = "Fairly increase game time according to player move speed and distance. Default: disabled",
    secret_markers_name = "Secret Room Candidate Markers",
    secret_markers_desc = "Marks where Secret / Super Secret / Ultra Secret rooms could be while holding the map key. Merged from Lazy Delver (MIT). Disable Lazy Delver itself to avoid drawing two sets of markers. Default: enabled",
    fools_skull_name = "Mark The Fool Skull Room",
    fools_skull_desc = "In Depths II a special skull always drops The Fool card when destroyed. This puts a skull icon on the room that contains it, so you can find it again. Only shown for rooms you have already visited, so it never spoils the layout. Default: enabled",
  },
  zh_hans = {
    title = "GoodTripPlus",
    cursor_speed_name = "光标速度",
    cursor_speed_desc = "按住射击方向键时光标每帧移动的像素数。默认值：2",
    follow_curse_name = "迷失诅咒下禁用传送",
    follow_curse_desc = "层里带有迷失诅咒时禁用传送。默认开启。",
    travel_mode_name = "可以传送到",
    travel_mode_values = {[1] = "任意房间", [2] = "相邻房间", [3] = "已探索房间"},
    travel_mode_desc = "决定传送能跳多远。任意房间：地图上显示的房间都能传。相邻房间：已清怪的房间，以及已清房旁那间已显示但未清的房间。已探索房间：只有你进过并且已清怪的房间。默认：相邻房间。",
    fairpath_name = "只能传送到已清房连通的房间",
    fairpath_desc = "传送目标必须能从当前房间沿已清怪的房间逐门抵达。默认开启。",
    arrivedoor_name = "传送后站在门口",
    arrivedoor_desc = "传送到走路会走进来的那扇门门口；跨屏大房间的远途传送会先经过房间前部，会短暂看到一瞬。默认关闭。",
    fairtime_name = "按距离增加游戏时间",
    fairtime_desc = "按传送距离和玩家移速公平地补回游戏时间（Boss Rush 计时用它）。默认关闭。",
    secret_markers_name = "显示隐藏房候选标记",
    secret_markers_desc = "按住地图键时标出隐藏房 / 超级隐藏房 / 究极隐藏房的可能位置（合并自 Lazy Delver，MIT）。请同时禁用 Lazy Delver 本体，否则会画出两套标记。默认开启。",
    fools_skull_name = "标记深牢 II 的愚者骷髅房",
    fools_skull_desc = "深牢 II 里有一个特殊骷髅，炸掉后固定掉落愚者卡牌。开启后会在地图上给它所在的房间加一个骷髅图标，方便回头再找。只在你已经进过该房间后才显示，不会剧透本层布局。默认开启。",
  },
}
-- A few plausible spellings/casings for each supported language, since the
-- exact string Options.Language returns can vary by game version/branch.
local GT_LANG_ALIASES = {
  zh_hans = { "zh", "zh_hans", "zh-hans", "zh_cn", "zh-cn", "zh_chs", "chinese_s", "chi_s" },
}
local function gt_get_lang_strings()
  local raw = Options.Language
  if type(raw) == "string" then
    local lang = raw:lower()
    for code, aliases in pairs(GT_LANG_ALIASES) do
      for _, alias in ipairs(aliases) do
        if lang == alias then
          return GT_STRINGS[code]
        end
      end
    end
  end
  return GT_STRINGS.en
end
local mcm_registered = false
gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
  gt:prep()
  gt:new_room()
  gt:new_level()
  if not mcm_registered and ModConfigMenu then
    mcm_registered = true
    local L = gt_get_lang_strings()
    ModConfigMenu.AddTitle("GoodTripPlus", nil, L.title)
    ModConfigMenu.AddNumberSetting(
      "GoodTripPlus", nil,
      "CursorSpeed",
      1, 5, 0.25, 2,
      L.cursor_speed_name,
      L.cursor_speed_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "FollowCurseOfLost",
      true,
      L.follow_curse_name,
      L.follow_curse_desc
    )
    ModConfigMenu.AddNumberSetting(
      "GoodTripPlus", nil,
      "TravelMode",
      1, 3, 1, 2,
      L.travel_mode_name,
      L.travel_mode_values,
      L.travel_mode_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "FairTripPath",
      true,
      L.fairpath_name,
      L.fairpath_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "ArriveAtDoor",
      false,
      L.arrivedoor_name,
      L.arrivedoor_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "FairTripTime",
      false,
      L.fairtime_name,
      L.fairtime_desc
    )
    -- FastTransition / HighlightCursorRoom 不注册 MCM 菜单项（2026-10-04 用户决定）：
    -- 两者默认常开，仅可在 gtconfig.lua 里用文件覆盖。
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "ShowSecretMarkers",
      true,
      L.secret_markers_name,
      L.secret_markers_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "FoolsSkullRoom",
      true,
      L.fools_skull_name,
      L.fools_skull_desc
    )
  end
end)
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
    gid = gt:get_pos_grid_index(mmp_ctrl_pos)
  end
  p("teleDiag: target gid=" .. tostring(gid))
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
  -- 「准入判定过了、松手却响失败音」的预检：把 gt:teleport_to_grid_index() 开头那两条
  -- 静态失败规则在这里点名（Mom/Ultra Greed 房名规则、Mother's Shadow 在场规则），
  -- 免得只看到 verdict=可传送 却传不动（用户 2026-10-03 就是被 Mom 房名规则拦的）。
  -- 只覆盖这两条；挑战房血量、FairTripTime 距离那两条不在内。
  do
    local why = nil
    if not level:IsAscent()
        and (crd.Data.Name == "Mom" or crd.Data.Name == "Ultra Greed") then
      why = "Mom/Ultra Greed room rule"
    end
    for _, en in pairs(Isaac.GetRoomEntities()) do
      if en.Type == EntityType.ENTITY_MOTHERS_SHADOW then
        why = (why and (why .. " + ") or "") .. "Mother's Shadow (867) is in this room"
        break
      end
    end
    p("  tripPrecheck: " ..
      (why and ("BLOCKED at landing by " .. why) or "no landing-block rule matched"))
  end
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
      pcall(function()
        busted = tostring(door.IsBusted and door:IsBusted() or door.Busted)
        canblow = tostring(door.CanBlowOpen and door:CanBlowOpen())
        isopen = tostring(door:IsOpen())
      end)
      p("  door slot=" .. i ..
        " variant=" .. tostring(door.Desc and door.Desc.Variant) ..
        " busted=" .. busted .. " canBlowOpen=" .. canblow ..
        " isOpen=" .. isopen ..
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
  -- 可达岛
  local reach = gt:get_config_bool("FairTripPath", true) and gt:get_reachable_rooms() or nil
  if reach then
    local n = 0
    for _ in pairs(reach) do n = n + 1 end
    p("  reach island: size=" .. n ..
      " startInReach=" .. tostring(reach[crd.SafeGridIndex] == true) ..
      " targetInReach=" .. tostring(reach[trd.SafeGridIndex] == true) ..
      " (target needs VisitedCount>0+Clear+door-path to be an island member)")
  else
    p("  reach island: OFF (FairTripPath=false)")
  end
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
  p("  travelMode=" .. gt:get_travel_mode() .. " (1=任意房间 2=相邻房间 3=已探索房间)")
  -- 按当前配置给出结论
  if gt:get_travel_mode() == 1 then
    p("  verdict: TravelMode=AnyRoom(1) -> should be teleportable")
  elseif trd.VisitedCount > 0 and trd.Clear
      and (not reach or reach[trd.SafeGridIndex] == true) then
    p("  verdict: visited+clear+inReach -> should be teleportable (channel B)")
  elseif gt:get_travel_mode() == 3 then
    p("  verdict: TravelMode=ExploredRooms(3) -> NOT teleportable (neighbor exemption off)")
  else
    local ok = gt:check_neigh_connected(trd, function(rd)
      return (rd.DisplayFlags & 1 ~= 0) and rd.VisitedCount > 0 and rd.Clear
        and (not reach or (reach[rd.SafeGridIndex]
          and gt:rooms_linked(rd.SafeGridIndex, trd.SafeGridIndex)))
    end)
    p("  verdict: check_neigh_connected=" .. tostring(ok) ..
      (ok and " -> should be teleportable (channel C)" or " -> NOT teleportable (channel C failed; see neighbor evidence above)"))
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
  -- 只在开发模式（gtconfig.lua 的 gt.DebugMod = true）下自动弹诊断：
  -- 正式游玩时不往 log.txt 写这些行，免得每次瞄隐藏房都刷十几行；
  -- 想临时看诊断按「按住地图键 + F4」，那条不依赖本开关。
  if not debug then
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
  -- DebugMod 下：屏幕浮层 + 控制台 + log.txt 一次给全，连按键都不用
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

-- ===== 屏幕诊断浮层 =====
-- 控制台命令在部分环境（REPENTOGON 的 ImGui「Repentance+ Console」）里不会
-- 分发给 MC_EXECUTE_CMD —— 实测输入 gtpdiag 触发不了我们的回调（log 里连
-- 「命令触发了」的留痕都没有），所以再给一条**一定看得见**的输出路：
-- 把最近一次 dump 直接画在屏幕左上角（15 秒后自动消失），同时照旧写 log.txt。
local diag_font = nil
local diag_overlay_lines = nil
local diag_overlay_until = 0

function gt:show_diag_overlay(text, frames)
  if not diag_font then
    local ok, font = pcall(function()
      local f = Font()
      f:Load("font/terminus.fnt")
      return f
    end)
    if not ok or not font then
      return
    end
    diag_font = font
  end
  local lines = {}
  for line in tostring(text):gmatch("[^\n]+") do
    lines[#lines + 1] = line
  end
  diag_overlay_lines = lines
  diag_overlay_until = Game():GetFrameCount() + (frames or 900)
end

function gt:render_diag_overlay()
  if not diag_overlay_lines or not diag_font then
    return
  end
  if Game():GetFrameCount() > diag_overlay_until then
    diag_overlay_lines = nil
    return
  end
  local y = 34
  for i = 1, #diag_overlay_lines do
    diag_font:DrawString(diag_overlay_lines[i], 16, y, KColor(1, 1, 0.35, 1), 0, false)
    y = y + 11
  end
end

-- 逐行把诊断文本写进控制台输出缓冲（Isaac.ConsoleOutput 不认多行字符串，
-- 整段丢进去容易只看到一行，所以自己按 \n 拆）
local function gt_console_out(text)
  for line in tostring(text):gmatch("[^\n]+") do
    Isaac.ConsoleOutput(line .. "\n")
  end
end

-- 免控制台诊断入口：按住地图键 + F4（tab_action 里调用），把光标所在格的完整判定
-- 打到控制台与 log.txt。控制台看不见输出时的另一条路。
-- （定义在 gt_console_out 之后，tab_action 里是运行时按名字取，不受定义顺序影响。）
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
  -- 屏幕浮层：控制台不可见时的保底输出，用户当场就能看到
  gt:show_diag_overlay(result)
  return result
end

-- 统一诊断出口：控制台命令、TAB+F4、DebugMod 自动 dump 都走这里。
-- ⚠️ 返回值一律 nil：MC_EXECUTE_CMD 的返回值会被引擎逐行打印到控制台，
-- 而本机（REPENTOGON 的 ImGui 控制台）**返回多行字符串会当场闪退**
-- （2026-10-03 实测：日志里我们的输出打印完立刻 "Lua stack trace:"（空栈）+
-- "Caught exception, writing minidump..."；同一环境里 MinimapAPI 的 mapitel
-- 返回 nil 就能正常工作）。所以只走 ConsoleOutput（逐行直写，安全）+ DebugString，
-- 不碰返回值。defer_overlay：控制台回调里不立刻建 Font（免得在命令处理阶段
-- 碰资源），改成下一帧走渲染阶段再弹浮层。
function gt:console_dump_diag(gid, tag, defer_overlay)
  local ok, result = pcall(gt.dump_tele_diag, gt, gid)
  if not ok then
    result = "teleDiag ERROR: " .. tostring(result)
  end
  local name = "GoodTripPlus " .. (tag or "gtpdiag")
  result = "===== " .. name .. " BEGIN =====\n" .. tostring(result) ..
    "\n===== " .. name .. " END ====="
  gt_console_out(result)
  Isaac.DebugString(result)
  if defer_overlay then
    gt.diag_pending_overlay = result
  else
    gt:show_diag_overlay(result)
  end
end

-- 控制台诊断命令：gtpdiag [格子编号]（缺省 = 光标所在格子）、gtmapdiag；gtpd 是简写。
-- 输出通道（**不要返回字符串**，见上）：
--   ConsoleOutput  —— 逐行直写控制台输出（MinimapAPI 的 mapitel 也是这么做的，安全）
--   DebugString    —— 落 log.txt（最可靠的一条）
--   （浮层延到下一帧渲染阶段弹，见 defer_overlay）
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
  gt:console_dump_diag(gid, "gtpdiag v" .. tostring(gt.VERSION), true)
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
