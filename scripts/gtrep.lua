gt = RegisterMod("GoodTripPlus", 1)
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
local secret_pre_room_id = {}
local prep_alarm = false
local testnum = 0
local n_room_num = 0
local mmp_ctrl = false
local mmp_ctrl_pos = Vector(0, 0)
local mmp_highlight_gid = nil

gt.DebugMod = false
gt.FastRestartEnable = false
gt.TeleportAnimation = true
gt.BlockCurseRoom = true
gt.RequireExploredPath = true
gt.HighlightStartingRoom = true
gt.HighlightCursorRoom = true
gt.ShowSecretMarkers = true
gt.AllowUnexploredNeighbor = false
local _, err = pcall(require, "gtconfig")
----
local debug = gt.DebugMod
local fastrestartenable = gt.FastRestartEnable
local tele_anime = 3
local tele_cd0 = 45
local tele_cd = 0
if not gt.TeleportAnimation then
  tele_anime = 1
  tele_cd0 = 10
end
if debug then tele_cd0 = 1 end
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
function gt:check_teleble(gid)
    if gid == -99 or level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST ~= 0 then
      return false
    elseif debug and grid_room[gid] then
      return true
    end
    local cid = crd.SafeGridIndex
    if grid_room[cid] == nil or not crd.Clear then
      return false
    elseif (crd.Data.Type == 6 or crd.Data.Type == 11) then
      if not gt:check_room_open() then
        return false
      end
    end
    if gid == false then return true end
    if grid_room[gid] == nil then
      return false
    else
      local trd = grid_room[gid]
      if trd.ListIndex == crd.ListIndex then
        return false
      end
      local requireExploredPath = gt.RequireExploredPath
      if ModConfigMenu and ModConfigMenu.Config["GoodTripPlus"] then
        local v = ModConfigMenu.Config["GoodTripPlus"]["RequireExploredPath"]
        if v ~= nil then requireExploredPath = v end
      end

      if trd.VisitedCount == 0 then
        -- 未探索的房间：默认不允许。开启 AllowUnexploredNeighbor 后，
        -- 只要它紧挨着某个「已探索 + 从当前房间可达」的房间就放行。
        if not gt:get_config_bool("AllowUnexploredNeighbor", false)
        or not gt:has_reachable_explored_neighbor(gid, requireExploredPath) then
          return false
        end
      else
        if not trd.Clear then
          return false
        end
        if requireExploredPath and not gt:has_explored_path_to(gid) then
          return false
        end
      end

      if trd.Data.Type == 10 then
        local blockCurse = gt.BlockCurseRoom
        if ModConfigMenu and ModConfigMenu.Config["GoodTripPlus"] then
          local v = ModConfigMenu.Config["GoodTripPlus"]["BlockCurseRoom"]
          if v ~= nil then blockCurse = v end
        end
        if blockCurse then return false end
      end
    end
    return true
end
--
-- 「传送到未探索的相邻房间」用的判定。
-- 目标房间还没进去过时，看它上下左右四个格子里有没有「已探索」的房间，
-- 并且（在开启 RequireExploredPath 时）那个房间能从当前房间沿已探索路径抵达。
-- 注意 ±1 会跨行，必须按列号把左右两侧的越界排除掉。
--
function gt:has_reachable_explored_neighbor(gid, requireExploredPath)
    local column = gid % 13
    local neighbors = {gid - 13, gid + 13}
    if column > 0 then
      neighbors[#neighbors + 1] = gid - 1
    end
    if column < 12 then
      neighbors[#neighbors + 1] = gid + 1
    end

    for _, neighborGid in ipairs(neighbors) do
      local neighbor = grid_room[neighborGid]
      if neighbor and neighbor.VisitedCount > 0 then
        if not requireExploredPath or gt:has_explored_path_to(neighborGid) then
          return true
        end
      end
    end
    return false
end
--
function gt:has_explored_path_to(targetGid)
    if not MinimapAPI then
      return false
    end

    local targetDesc = grid_room[targetGid]
    local map = MinimapAPI:GetLevel(gt:get_current_dimension())
    if not targetDesc or not map then
      return false
    end

    local roomsByListIndex = {}
    for _, mapRoom in ipairs(map) do
      if mapRoom.Descriptor then
        roomsByListIndex[mapRoom.Descriptor.ListIndex] = mapRoom
      end
    end

    local start = roomsByListIndex[crd.ListIndex]
    local target = roomsByListIndex[targetDesc.ListIndex]
    if not start or not target then
      return false
    end

    local queue = {start}
    local head = 1
    local seen = {[start.Descriptor.ListIndex] = true}
    while queue[head] do
      local current = queue[head]
      head = head + 1
      if current == target then
        return true
      end
      for _, adjacent in ipairs(current:GetAdjacentRooms()) do
        local adjacentDesc = adjacent.Descriptor
        if adjacentDesc and adjacentDesc.VisitedCount > 0
        and not seen[adjacentDesc.ListIndex] then
          seen[adjacentDesc.ListIndex] = true
          queue[#queue + 1] = adjacent
        end
      end
    end
    return false
end
--
function gt:is_curse_room_bypass_room(mapRoom)
    local desc = mapRoom and mapRoom.Descriptor
    if not desc or not desc.Data then
      return false
    end
    return desc.Data.Type == RoomType.ROOM_SECRET
end
--
function gt:has_explored_curse_bypass(targetGid)
    local targetDesc = grid_room[targetGid]
    if not MinimapAPI or not targetDesc or
      (crd.Data.Type ~= RoomType.ROOM_CURSE and targetDesc.Data.Type ~= RoomType.ROOM_CURSE) then
      return false
    end

    local map = MinimapAPI:GetLevel(gt:get_current_dimension())
    if not map then
      return false
    end
    local roomsByListIndex = {}
    for _, mapRoom in ipairs(map) do
      if mapRoom.Descriptor then
        roomsByListIndex[mapRoom.Descriptor.ListIndex] = mapRoom
      end
    end
    local start = roomsByListIndex[crd.ListIndex]
    local target = roomsByListIndex[targetDesc.ListIndex]
    if not start or not target then
      return false
    end

    local queue = {start}
    local head = 1
    local seen = {[start.Descriptor.ListIndex] = true}
    while queue[head] do
      local current = queue[head]
      head = head + 1
      if current == target then
        return true
      end
      for _, adjacent in ipairs(current:GetAdjacentRooms()) do
        local currentDesc = current.Descriptor
        local adjacentDesc = adjacent.Descriptor
        local crossesCurseDoor = currentDesc and adjacentDesc and
          (currentDesc.Data.Type == RoomType.ROOM_CURSE or adjacentDesc.Data.Type == RoomType.ROOM_CURSE) and
          not gt:is_curse_room_bypass_room(currentDesc.Data.Type == RoomType.ROOM_CURSE and adjacent or current)
        if adjacentDesc and adjacentDesc.VisitedCount > 0 and not crossesCurseDoor
        and not seen[adjacentDesc.ListIndex] then
          seen[adjacentDesc.ListIndex] = true
          queue[#queue + 1] = adjacent
        end
      end
    end
    return false
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
    local trd = grid_room[gid]
    if gt:has_explored_curse_bypass(gid) then
      return
    end
    if crd.Data.Type == 10 then
      if secret_pre_room_id[crid] and (secret_pre_room_id[crid] == gid or (secret_pre_room_id[secret_pre_room_id[crid]] and secret_pre_room_id[secret_pre_room_id[crid]] ~= crid)) then
        return
      end
      gt:hurt(1)
    elseif trd.Data.Type == 10 and not player:IsFlying() then
      if secret_pre_room_id[gid] and (secret_pre_room_id[gid] == crid or (secret_pre_room_id[secret_pre_room_id[gid]] and secret_pre_room_id[secret_pre_room_id[gid]] ~= gid)) then
        return
      end
      gt:hurt(1)
    end
end
--
function gt:teleport_to_grid_index(gid)
    local dim = gt:get_current_dimension()
    for _,en in pairs(Isaac.GetRoomEntities()) do
      if en.Type == 867 then
        gt:tele_failed()
        return
      end
    end
    if crd.Data.Name == "Mom" then
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
    local flat = player:HasTrinket(151) or player:HasCollectible(276) or player:HasCollectible(663)
    if not flat then
      gt:check_curse_room(gid)
    end
    level.EnterDoor = -1
    level.LeaveDoor = -1
    if level:GetCurses() & LevelCurse.CURSE_OF_MAZE ~= 0 then
      level:RemoveCurses(LevelCurse.CURSE_OF_MAZE)
      tele_maze = true
    end
    if crd.Data.Type == 7 then
      local secretPreId = secret_pre_room_id[crid]
      local secretPreRoom = secretPreId and grid_room[secretPreId]
      if secretPreRoom then
        if secretPreRoom.ListIndex == grid_room[gid].ListIndex then
          gid = secretPreId
        else
        if grid_room[gid].Data.Type == 10 and secret_pre_room_id[gid] and secret_pre_room_id[gid] == crid then
        else
          if secretPreRoom.Data.Type == 10 and not flat then
            gt:hurt(1)
          end
          Game():ChangeRoom(secretPreId, dim)
        end
        end
      end
    end
    if grid_room[gid].Data.Type == 7 then
      local targetSecretPreId = secret_pre_room_id[gid]
      local targetSecretPreRoom = targetSecretPreId and grid_room[targetSecretPreId]
      if targetSecretPreRoom then
        if targetSecretPreRoom.ListIndex == grid_room[crid].ListIndex then
          if grid_room[crid].Data.Shape > 3 then
            Game():ChangeRoom(targetSecretPreId, dim)
          end
        else
          if crd.Data.Type == 10 and secret_pre_room_id[crid] and secret_pre_room_id[crid] == gid then
          else
            if targetSecretPreRoom.Data.Type == 10 and not player:IsFlying() and not flat then
              gt:hurt(1)
            end
            Game():ChangeRoom(targetSecretPreId, dim)
          end
        end
      end
    end
    if debug then
      Game():ChangeRoom(gid, dim)
    else
      Game():StartRoomTransition(gid, Direction.NO_DIRECTION, tele_anime,player,dim)
      tele_cd = tele_cd0
    end
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

    local maxx, miny = nil, nil
    local visibleCount = 0
    for _, mapRoom in ipairs(map) do
      if mapRoom.Descriptor and mapRoom:GetDisplayFlags() > 0 then
        visibleCount = visibleCount + 1
        local position = mapRoom.DisplayPosition or mapRoom.Position
        local pivot = MinimapAPI.RoomShapeGridPivots[mapRoom.Shape]
        local size = MinimapAPI:GetRoomShapeGridSize(mapRoom.Shape)
        local maxxval = (position.X - pivot.X + (gsx >= 0 and size.X or 0)) * gsx
        maxx = not maxx and maxxval or math.max(maxx, maxxval)
        miny = not miny and position.Y or math.min(miny, position.Y)
        local render = mapRoom.RenderOffset
        local target = mapRoom.TargetRenderOffset
        out("room safe=" .. tostring(mapRoom.Descriptor.SafeGridIndex) .. " list=" ..
          tostring(mapRoom.Descriptor.ListIndex) .. " shape=" .. tostring(mapRoom.Shape) ..
          " pos=" .. tostring(position.X) .. "," .. tostring(position.Y) .. " flags=" ..
          tostring(mapRoom:GetDisplayFlags()) .. " render=" ..
          (render and (tostring(render.X) .. "," .. tostring(render.Y)) or "nil") ..
          " target=" .. (target and (tostring(target.X) .. "," .. tostring(target.Y)) or "nil"))
      end
    end
    out("visible=" .. tostring(visibleCount) .. " MinimapAPI unbounded maxX=" ..
      tostring(maxx) .. " minY=" .. tostring(miny))
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
      local offsetVec = gt:get_minapi_offset_vec()
      local ltroom = gt:get_corner_room(1)
      local rtroom = gt:get_corner_room(2)
      local gsx = MinimapAPI.GlobalScaleX or 1
      for gid, rd in pairs(grid_room) do
        if gt:is_grid_room_displayed(gid) then
          local col = gid % 13
          local row = math.floor(gid / 13)
          local rx, ry
          if gsx >= 0 then
            rx = offsetVec.X + (col - rtroom.X - 1) * 17 + 9
          else
            rx = offsetVec.X + (ltroom.X - col) * 17 - 17
          end
          ry = offsetVec.Y + (row - ltroom.Y) * 15 + 8
          if math.abs(pos.X - rx) < 8.5 and math.abs(pos.Y - ry) < 7.5 then
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
      local ltroom = gt:get_corner_room(1)
      local rtroom = gt:get_corner_room(2)
      local gsx = MinimapAPI.GlobalScaleX or 1
      local col = gid % 13
      local row = math.floor(gid / 13)
      local rx, ry
      if gsx >= 0 then
        rx = offsetVec.X + (col - rtroom.X - 1) * 17 + 9
      else
        rx = offsetVec.X + (ltroom.X - col) * 17 - 17
      end
      ry = offsetVec.Y + (row - ltroom.Y) * 15 + 8
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
function gt:render_map_highlights()
    if not MinimapAPI then
      return
    end
    if gt:get_config_bool("HighlightStartingRoom", true)
    and not level:IsAscent()
    and gt:get_current_dimension() == 0
    and not gt:is_mirror_world() then
      local startDesc = level:GetRoomByIdx(level:GetStartingRoomIndex(), 0)
      if startDesc then
        gt:draw_minapi_room_highlight(
          gt:get_minapi_room_by_list_index(startDesc.ListIndex),
          Color(0.35, 1, 0.35, 0.45, 0, 0, 0)
        )
      end
    end
end
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
    gt:render_map_highlights()
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
    room = Game():GetRoom()
    crd = level:GetCurrentRoomDesc()
    crid = crd.SafeGridIndex
    stage = level:GetStage()
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
    n_room_num = (level:GetRooms()).Size
    secret_pre_room_id = {}
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
    block_curse_name = "Block Curse Room Teleport",
    block_curse_desc = "When enabled, you cannot teleport into Curse Rooms (the ones that damage you on entry/exit). Default: enabled",
    require_path_name = "Disable Unconnected Teleport",
    require_path_desc = "When enabled, teleporting requires an explored route between the current and target rooms. Default: enabled",
    highlight_start_name = "Highlight Starting Room",
    highlight_start_desc = "Highlights the floor's starting room on the minimap. Default: enabled",
    highlight_cursor_name = "Highlight Cursor Room",
    highlight_cursor_desc = "Highlights a teleportable room under the cursor. Default: enabled",
    secret_markers_name = "Secret Room Candidate Markers",
    secret_markers_desc = "Marks where Secret / Super Secret / Ultra Secret rooms could be while holding the map key. Merged from Lazy Delver (MIT). Disable Lazy Delver itself to avoid drawing two sets of markers. Default: enabled",
    unexplored_name = "Teleport Into Unexplored Rooms",
    unexplored_desc = "Allow teleporting into a room you have never entered, as long as it sits next to an explored room that is reachable from your current room (only when 'Disable Unconnected Teleport' is on does that reachability matter). Default: disabled",
  },
  zh_hans = {
    title = "GoodTripPlus",
    cursor_speed_name = "光标速度",
    cursor_speed_desc = "按住射击方向键时光标每帧移动的像素数。默认值：2",
    block_curse_name = "禁止传送进诅咒房",
    block_curse_desc = "开启后不能传送进会在进出时扣血的诅咒房。默认开启。",
    require_path_name = "禁用未连通房间传送",
    require_path_desc = "开启后，只有当前房间与目标房间之间存在已探索路径时才能传送。默认开启。",
    highlight_start_name = "高亮显示初始房间",
    highlight_start_desc = "在小地图上高亮显示本层的初始房间。默认开启。",
    highlight_cursor_name = "高亮光标下房间",
    highlight_cursor_desc = "高亮显示光标下可传送的房间。默认开启。",
    secret_markers_name = "显示隐藏房候选标记",
    secret_markers_desc = "按住地图键时标出隐藏房 / 超级隐藏房 / 究极隐藏房的可能位置（合并自 Lazy Delver，MIT）。请同时禁用 Lazy Delver 本体，否则会画出两套标记。默认开启。",
    unexplored_name = "允许传送到未探索的相邻房间",
    unexplored_desc = "开启后可以传送到还没进去过、但紧邻某个已探索房间的位置；若同时开着「禁用未连通房间传送」，那个相邻的已探索房间还需要能从当前房间沿已探索路径抵达。默认关闭。",
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
      "BlockCurseRoom",
      true,
      L.block_curse_name,
      L.block_curse_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "RequireExploredPath",
      true,
      L.require_path_name,
      L.require_path_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "HighlightStartingRoom",
      true,
      L.highlight_start_name,
      L.highlight_start_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "HighlightCursorRoom",
      true,
      L.highlight_cursor_name,
      L.highlight_cursor_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "ShowSecretMarkers",
      true,
      L.secret_markers_name,
      L.secret_markers_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "AllowUnexploredNeighbor",
      false,
      L.unexplored_name,
      L.unexplored_desc
    )
  end
end)
gt:AddCallback(ModCallbacks.MC_POST_RENDER, gt.step)
gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, gt.new_room)
gt:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, gt.new_level)
gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
  if command:lower() == "gtmapdiag" then
    gt:dump_map_diagnostics()
  end
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
  elseif StageAPI and StageAPI.Loaded then
    StageAPI.AddCallback("GoodTripPlus", "POST_HUD_RENDER", 1, gt.render_cursor)
  elseif is_repentance then
    gt:AddPriorityCallback(ModCallbacks.MC_POST_RENDER, late_priority, gt.render_cursor)
  else
    gt:AddCallback(ModCallbacks.MC_POST_RENDER, gt.render_cursor)
  end
end
