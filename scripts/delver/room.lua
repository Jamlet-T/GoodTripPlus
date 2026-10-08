---@module "scripts.delver.room"

local C = require("scripts.delver.const")
local geo = require("scripts.delver.geometry")
local state = require("scripts.delver.state")
local log = require("scripts.delver.log")
local map = require("scripts.delver.map")

local M = {}

local BOMB_RADIUS = 80


---@param room_obj Room
---@return { w: integer, h: integer, [integer]: { [integer]: boolean } }
local function make_grid(room_obj)
  local w, h = room_obj:GetGridWidth(), room_obj:GetGridHeight()
  local size = room_obj:GetGridSize()
  local grid = { w = w, h = h }
  for r = 0, h - 1 do grid[r] = {} end

  for gid = 0, size - 1 do
    local ge = room_obj:GetGridEntity(gid)
    if ge and not C.GRID_ENTITY.NOT_BLOCKED[ge:GetType()] then
      grid[gid // w][gid % w] = true
    end
  end

  for _, re in ipairs(Isaac.GetRoomEntities()) do
    if C.ROOM_ENTITY.IS_BLOCKED[re.Type] then
      local gid = re.SpawnGridIndex
      if gid >= 0 and gid < size then
        grid[gid // w][gid % w] = true
      end
    end
  end

  return grid
end

---@param visited { [integer]: { [integer]: boolean } }
---@param grid { w: integer, h: integer, [integer]: { [integer]: boolean } }
---@param r integer
---@param c integer
local function dfs(visited, grid, r, c)
  if r < 0 or r >= grid.h or c < 0 or c >= grid.w then return end
  if visited[r][c] then return end
  if grid[r][c] then return end
  visited[r][c] = true
  dfs(visited, grid, r - 1, c)
  dfs(visited, grid, r + 1, c)
  dfs(visited, grid, r, c - 1)
  dfs(visited, grid, r, c + 1)
end

---@param room_obj Room
---@return boolean[][]
local function visit(room_obj)
  local visited = {}
  local w, h = room_obj:GetGridWidth(), room_obj:GetGridHeight()
  local size = room_obj:GetGridSize()
  local grid = make_grid(room_obj)

  for r = 0, h - 1 do visited[r] = {} end
  for gid = 0, size - 1 do
    local ge = room_obj:GetGridEntity(gid)
    if ge and ge:GetType() == GridEntityType.GRID_DOOR then
      local r, c = gid // w, gid % w
      if r == 0      then dfs(visited, grid, 1,     c) end
      if r == h - 1  then dfs(visited, grid, h - 2, c) end
      if c == 0      then dfs(visited, grid, r,     1) end
      if c == w - 1  then dfs(visited, grid, r, w - 2) end
    end
  end

  return visited
end

function M.door_check()
  if state.has_changed() then map.reload() end
  if state.is_ignored() then return end

  local lid = Game():GetLevel():GetCurrentRoomDesc().ListIndex
  log.info("=== Entered New Room ===")
  local room = map.rooms[lid]
  if not room then
    log.info("list id: " .. lid) log.info("")
    return
  end
  lid = room.lid

  local room_obj = Game():GetRoom()
  local w = room_obj:GetGridWidth()
  local visited = visit(room_obj)

  for cid, cand in pairs(map.candidates) do
    for _, entry in ipairs(cand.entries) do
      if entry.source_lid ~= lid or entry.checked then
        goto next_entry
      end

      local valid = false
      if cand.secret_type == C.SECRET_TYPE.ULTRA then
        valid = room_obj:IsDoorSlotAllowed(entry.doorslot)
      else
        local door = room_obj:GetDoor(entry.doorslot)
        local has_door = door
                     and door.TargetRoomType ~= RoomType.ROOM_SECRET
                     and door.TargetRoomType ~= RoomType.ROOM_SUPERSECRET

        local door_pos = room_obj:GetDoorSlotPosition(entry.doorslot)
        local door_gid = room_obj:GetGridIndex(door_pos)
        if door_gid < 0 then goto next_entry end

        local delta = geo.DIR_DELTA[entry.dir]
        local ir = door_gid // w - delta.R
        local ic = door_gid % w - delta.C

        valid = visited[ir][ic] and not has_door
      end

      if valid then
        entry.checked = true
      elseif cand.lid == nil then
        map.candidates[cid] = nil
        break
      else
        log.error("Try to remove a real secret room: ")
        log.print_room(cand.lid, map):error()
      end

      ::next_entry::
    end
  end

  -- log.info 为 no-op；错误分支的 print_room(...):error() 仍保留。
end

---@param position Vector
---@param radius number
function M.wall_hit_check(position, radius)
  if state.is_ignored() then return false end

  local lid = Game():GetLevel():GetCurrentRoomDesc().ListIndex
  local room = map.rooms[lid]
  if not room then return false end
  lid = room.lid

  local room_obj = Game():GetRoom()
  local hit_gid = room_obj:GetGridIndex(position)
  if hit_gid < 0 then return false end
  local changed = false

  for cid, cand in pairs(map.candidates) do
    if cand.secret_type == C.SECRET_TYPE.ULTRA then goto next_cand end

    for _, entry in ipairs(cand.entries) do
      if entry.source_lid ~= lid then
        goto next_entry
      end

      local door_pos = room_obj:GetDoorSlotPosition(entry.doorslot)
      local dist = (position - door_pos):Length()
      if dist < radius then
        if not cand.lid then
          map.candidates[cid] = nil
          changed = true
          break
        end
      end

      ::next_entry::
    end

    ::next_cand::
  end
  return changed
end

function M.bomb_check(effect)
  return M.wall_hit_check(effect.Position, BOMB_RADIUS)
end

return M
