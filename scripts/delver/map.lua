---@module "scripts.delver.map"

local C = require("scripts.delver.const")
local geo = require("scripts.delver.geometry")
local log = require("scripts.delver.log")
local state = require("scripts.delver.state")

---@class LD_Map
local M = {}

-- IsaacDocs RoomDescriptor.Flags: FLAG_RED_ROOM = 1 << 10.
-- Type alone cannot distinguish a Red Key room from the original floor layout.
function M.is_red_room(desc)
  return desc ~= nil and ((desc.Flags or 0) & (1 << 10)) ~= 0
end

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
---@field is_red boolean
---@type table<LD_Lid, LD_Room>
M.rooms = {}


---@param room_desc RoomDescriptor
local function parse_room(room_desc)
  local data = room_desc.Data
  if not data or room_desc.GridIndex < 0 or room_desc.GridIndex >= C.MAP.SIZE then return end

  local lid = room_desc.ListIndex
  local shape_offsets = geo.SHAPE_OFFSETS[data.Shape]
  local category = C.CELL.ROOM_TYPE_TO_CATEGORY[data.Type]
  if not shape_offsets or not category then return end

  local cids = {}
  for i = 1, #shape_offsets do
    cids[i] = shape_offsets[i] + room_desc.GridIndex

    if M.cells[cids[i]] then
      -- 重叠不是镜像身份证据；镜像对应关系在主维度解析完成后显式建立。
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
    is_red = M.is_red_room(room_desc),
  }
end

-- All secret generation is based on the non-red floor layout. Keep red occupancy
-- in M.cells for the live map, but treat opened red intermediaries as empty
-- when reconstructing generation paths; they cannot extend the source layout.
local function generation_layout_cell(cid)
  local cell = M.cells[cid]
  if cell and not M.rooms[cell.lid].is_red then return cell end
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
        local src = generation_layout_cell(src_cid)
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
    local n_cell = generation_layout_cell(n_cid)
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
    local n_cell = generation_layout_cell(n_cid)
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
    if M.rooms[cell.lid].is_red then goto next_cell end
    blocked[cid] = true
    if cell.category ~= C.CELL.CATEGORY.SECRET then
      for _, n_cid in pairs(geo.get_neighbors(cid)) do
        blocked[n_cid] = true
      end
    end
    ::next_cell::
  end

  for cid = 0, C.MAP.SIZE - 1 do
    local cell = generation_layout_cell(cid)
    if cell then
      blocked[cid] = true
      goto continue
    end

    local empty_n_cids = {}
    local non_empties = {}
    local block_empties = false
    for dir, n_cid in pairs(geo.get_neighbors(cid)) do
      local n_cell = generation_layout_cell(n_cid)
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
    if existing and existing.secret_type == C.SECRET_TYPE.ULTRA and existing.lid == nil then
      M.candidates[cid] = nil
    end

    for _, e_cid in ipairs(empty_n_cids) do
      if block_empties then break end

      if not blocked[e_cid] and not M.cells[e_cid] then
        -- At this distance from the original layout, the ultra rule takes precedence.
        if not M.candidates[e_cid] or (M.candidates[e_cid].lid == nil and
          M.candidates[e_cid].secret_type ~= C.SECRET_TYPE.ULTRA) then
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
        if cand and cand.secret_type == C.SECRET_TYPE.ULTRA and cand.lid == nil then
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
  if gt and gt.delver_memory_before_reload then gt:delver_memory_before_reload() end
  local level = Game():GetLevel()
  state.update(level)

  M.cells = {}
  M.candidates = {}
  M.rooms = {}

  local rooms_raw = level:GetRooms()
  local mirrors = {}
  local allow_mirror = level:GetStage() == LevelStage.STAGE1_2
    and (level:GetStageType() == StageType.STAGETYPE_REPENTANCE
      or level:GetStageType() == StageType.STAGETYPE_REPENTANCE_B)
  local included, excluded = 0, 0
  for lid = 0, rooms_raw.Size - 1 do
    local desc = rooms_raw:Get(lid)
    if desc and desc.Data and desc.GridIndex >= 0 and desc.GridIndex < C.MAP.SIZE then
      -- GetRooms 包含其它维度。与 MinimapAPI LoadDefaultMap 一样，显式查询
      -- SafeGridIndex + 维度并核对描述符身份，不能靠占据格重叠猜镜像。
      local main = level:GetRoomByIdx(desc.SafeGridIndex, C.DIMENSION.MAIN)
      if main and main.Data and GetPtrHash(main) == GetPtrHash(desc) then
        parse_room(desc)
        included = included + 1
      elseif allow_mirror then
        local mirror = level:GetRoomByIdx(desc.SafeGridIndex, C.DIMENSION.MIRROR)
        if mirror and mirror.Data and GetPtrHash(mirror) == GetPtrHash(desc) then
          mirrors[#mirrors+1] = desc
        else
          excluded = excluded + 1
        end
      else
        excluded = excluded + 1
      end
    else
      excluded = excluded + 1
    end
  end
  -- 两遍处理，避免镜像描述符排在主维度前面时反客为主。
  for _, desc in ipairs(mirrors) do
    local offsets = geo.SHAPE_OFFSETS[desc.Data.Shape]
    local cell = offsets and M.cells[desc.GridIndex + offsets[1]]
    local main = cell and M.rooms[cell.lid]
    if main and main.tl_cid == desc.GridIndex and main.shape == desc.Data.Shape then
      main.mirror_lid = desc.ListIndex
      M.rooms[desc.ListIndex] = main
    end
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
  M.fake_baseline={}
  for cid,candidate in pairs(M.candidates) do
    if candidate.lid==nil then M.fake_baseline[cid]=true end
  end

  log.info("Map loading complete!\n")
  -- log.info 当前为 no-op；不再构建随后被丢弃的整层文本/ASCII 地图。

  state.done()
  if gt and gt.delver_memory_after_reload then gt:delver_memory_after_reload() end
  -- 自动取证：每次重建一次；诊断异常不得阻断候选渲染。
  pcall(function()
    if gt and gt.is_debug and gt:is_debug() then
      Isaac.DebugString('[GTPdelver] rebuild stage=' .. level:GetStage()
        .. ' stageType=' .. level:GetStageType() .. ' dimension=' .. state.get_dimension()
        .. ' total=' .. rooms_raw.Size .. ' main=' .. included
        .. ' mirror=' .. #mirrors .. ' excluded=' .. excluded)
    end
  end)
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
