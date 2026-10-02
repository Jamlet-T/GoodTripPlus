---@module "scripts.delver.map"

local C = require("scripts.delver.const")
local geo = require("scripts.delver.geometry")
local log = require("scripts.delver.log")
local state = require("scripts.delver.state")

---@class LD_Map
local M = {}

---@alias LD_Cid integer  -- cid: `cell` index in [`cells` / grid]
---@alias LD_Lid integer  -- lid: [`room` / list] index in `rooms`

---@class LD_Cell
---@field cid LD_Cid
---@field lid LD_Lid
---@field category LD_CellCategory
---@type table<LD_Cid, LD_Cell>
M.cells = {}

---@class LD_Entry
---@field dir LD_Dir  -- source room -> neighbor direction
---@field source_lid LD_Lid
---@field doorslot DoorSlot
---@field checked boolean

---@class LD_Candidate
---@field cid LD_Cid
---@field secret_type LD_SecretType
---@field lid LD_Lid?  -- real SECRET ListIndex; nil for fake candidates
---@field marker_status LD_MarkerStatus
---@field entries LD_Entry[]

---@type table<LD_Cid, LD_Candidate>
M.candidates = {}

---@class LD_Room
---@field lid integer
---@field mirror_lid integer?
---@field tl_cid integer  -- top-left cid
---@field cids integer[]
---@field shape RoomShape
---@field type RoomType
---@type table<LD_Lid, LD_Room>
M.rooms = {}


---@param room_desc RoomDescriptor
local function parse_room(room_desc)
  local data = room_desc.Data
  if not data then return end

  local lid = room_desc.ListIndex
  local shape_offsets = geo.SHAPE_OFFSETS[data.Shape]
  local category = C.CELL.ROOM_TYPE_TO_CATEGORY[data.Type]

  local cids = {}
  for i = 1, #shape_offsets do
    cids[i] = shape_offsets[i] + room_desc.GridIndex

    if M.cells[cids[i]] then
      M.rooms[lid] = M.rooms[M.cells[cids[i]].lid]
      M.rooms[lid].mirror_lid = lid
      return
    end

    M.cells[cids[i]] = {
      cid = cids[i],
      lid = lid,
      category = category,
    }
  end

  M.rooms[lid] = {
    lid = lid,
    tl_cid = room_desc.GridIndex,
    cids = cids,
    shape = data.Shape,
    type = data.Type,
  }
end

---@param cid LD_Cid
local function build_entries(cid)
  local result = {}
  local cell = M.cells[cid]
  local neighbors = geo.get_neighbors(cid)

  if cell and cell.category == C.CELL.CATEGORY.SECRET and
     M.rooms[cell.lid].type == C.SECRET_TYPE.ULTRA then
    for _, mid_cid in pairs(geo.get_neighbors(cid)) do
      for dir, src_cid in pairs(geo.get_neighbors(mid_cid)) do
        local src = M.cells[src_cid]
        if src and src.category ~= C.CELL.CATEGORY.SECRET then
          local room = M.rooms[src.lid]
          local door_dir = (dir + 2) % 4
          local slot = geo.get_doorslot(door_dir, mid_cid - room.tl_cid, room.shape)
          if not slot then
            log.error("get doorslot failed, dir: " .. door_dir .. " room: " .. room.lid)
          end
          result[#result + 1] = {
            dir = door_dir,
            source_lid = src.lid,
            doorslot = slot,
            checked = false,
          }
        end
      end
    end
    return result
  end

  for dir, n_cid in pairs(neighbors) do
    local n_cell = M.cells[n_cid]
    if n_cell and n_cell.category ~= C.CELL.CATEGORY.SECRET then
      local room = M.rooms[n_cell.lid]
      local door_dir = (dir + 2) % 4
      local slot = geo.get_doorslot(door_dir, cid - room.tl_cid, room.shape)
      if not slot then
        log.error("get doorslot failed, dir: " .. door_dir .. " room: " .. room.lid)
      end
      result[#result + 1] = {
        dir = door_dir,
        source_lid = n_cell.lid,
        doorslot = slot,
        checked = false,
      }
    end
  end
  return result
end

---@param cid LD_Cid
---@return LD_SecretType?
local function fake_type(cid)
  local normal_count = 0
  local special_count = 0

  local neighbors = geo.get_neighbors(cid)
  for dir, n_cid in pairs(neighbors) do
    local n_cell = M.cells[n_cid]
    if n_cell then
      if n_cell.category == C.CELL.CATEGORY.BOSS then
        return nil
      elseif n_cell.category == C.CELL.CATEGORY.NORMAL or
             n_cell.category == C.CELL.CATEGORY.SPECIAL then
        local shape = M.rooms[n_cell.lid].shape
        if (dir == C.DIR.UP or dir == C.DIR.DOWN) and
           (shape == RoomShape.ROOMSHAPE_IH or
            shape == RoomShape.ROOMSHAPE_IIH) then
          return nil
        end
        if (dir == C.DIR.LEFT or dir == C.DIR.RIGHT) and
           (shape == RoomShape.ROOMSHAPE_IV or
            shape == RoomShape.ROOMSHAPE_IIV) then
          return nil
        end

        if n_cell.category == C.CELL.CATEGORY.NORMAL then
          normal_count = normal_count + 1
        elseif n_cell.category == C.CELL.CATEGORY.SPECIAL then
          special_count = special_count + 1
        end
      end
    end
  end

  local total_count = normal_count + special_count
  if total_count == 1 and normal_count == 1 then
    return C.SECRET_TYPE.SUPER
  elseif total_count > 1 then
    return C.SECRET_TYPE.REGULAR
  end

  return nil
end

local function find_fakes()
  for cid = 0, C.MAP.SIZE - 1 do
    if M.cells[cid] then
      goto continue
    end

    local secret_type = fake_type(cid)
    if secret_type == nil then
      goto continue
    end

    M.candidates[cid] = {
      cid = cid,
      secret_type = secret_type,
      lid = nil,
      marker_status = C.MARKER.STATUS.HIDDEN,
      entries = build_entries(cid),
    }

    ::continue::
  end
end

local function find_ultra_fakes()
  local blocked = {}

  for cid, cell in pairs(M.cells) do
    blocked[cid] = true
    if cell.category ~= C.CELL.CATEGORY.SECRET then
      for _, n_cid in pairs(geo.get_neighbors(cid)) do
        blocked[n_cid] = true
      end
    end
  end

  for cid = 0, C.MAP.SIZE - 1 do
    local cell = M.cells[cid]
    if cell then
      blocked[cid] = true
      goto continue
    end

    local empty_n_cids = {}
    local non_empties = {}
    local block_empties = false
    for dir, n_cid in pairs(geo.get_neighbors(cid)) do
      local n_cell = M.cells[n_cid]
      if not n_cell or n_cell.category == C.CELL.CATEGORY.SECRET then
        empty_n_cids[#empty_n_cids + 1] = n_cid
      elseif n_cell.category == C.CELL.CATEGORY.BOSS or
             M.rooms[n_cell.lid].type == RoomType.ROOM_CURSE then
        block_empties = true
      else
        non_empties[#non_empties + 1] = {
          dir = dir, cid = n_cid
        }
      end
    end

    if #non_empties == 0 then
      goto continue
    end

    blocked[cid] = true
    local existing = M.candidates[cid]
    if existing and existing.secret_type == C.SECRET_TYPE.ULTRA then
      M.candidates[cid] = nil
    end

    for _, e_cid in ipairs(empty_n_cids) do
      if block_empties then break end

      if not blocked[e_cid] then
        if not M.candidates[e_cid] then
          M.candidates[e_cid] = {
            cid = e_cid,
            secret_type = C.SECRET_TYPE.ULTRA,
            marker_status = C.MARKER.STATUS.HIDDEN,
            lid = nil,
            entries = {},
          }
        end

        local cand = M.candidates[e_cid]
        for _, ne in ipairs(non_empties) do
          local ne_room = M.rooms[M.cells[ne.cid].lid]
          local dir = (ne.dir + 2) % 4
          local slot = geo.get_doorslot(dir, cid - ne_room.tl_cid, ne_room.shape)
          if not slot then block_empties = true break end
          cand.entries[#cand.entries + 1] = {
            dir = dir,
            source_lid = ne_room.lid,
            doorslot = slot,
            checked = false,
          }
        end
      end
    end

    if block_empties then
      for _, e_cid in ipairs(empty_n_cids) do
        blocked[e_cid] = true
        local cand = M.candidates[e_cid]
        if cand and cand.secret_type == C.SECRET_TYPE.ULTRA then
          M.candidates[e_cid] = nil
        end
      end
    end
    ::continue::
  end

  for cid, cand in pairs(M.candidates) do
    if cand.secret_type == C.SECRET_TYPE.ULTRA and
       not cand.lid and #cand.entries < 2 then
      M.candidates[cid] = nil
    end
  end
end


function M.reload()
  local level = Game():GetLevel()
  state.update(level)

  M.cells = {}
  M.candidates = {}
  M.rooms = {}

  local rooms_raw = level:GetRooms()
  for lid = 0, rooms_raw.Size - 1 do
    parse_room(rooms_raw:Get(lid))
  end
  for cid, cell in pairs(M.cells) do
    if cell.category == C.CELL.CATEGORY.SECRET then
      local secret_type = M.rooms[cell.lid].type
      M.candidates[cid] = {
        cid = cid,
        secret_type = secret_type,
        lid = cell.lid,
        marker_status = C.MARKER.STATUS.HIDDEN,
        entries = build_entries(cid),
      }
    end
  end

  find_fakes()
  find_ultra_fakes()

  log.info("Map loading complete!\n")
  log.print_map(M):info()
  log.draw_map(M):info()

  state.done()
end


---@param lid LD_Lid
function M.clear_fake_neighbors(lid)
  local room = M.rooms[lid]
  if not room then return end

  for _, cid in ipairs(room.cids) do
    local neighbors = geo.get_neighbors(cid)

    for _, n_cid in pairs(neighbors) do
      local cand = M.candidates[n_cid]
      if cand and cand.lid == nil then
        M.candidates[n_cid] = nil
      end
    end
  end
end

return M
