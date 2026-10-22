---@module "scripts.delver.map"

local C = require("scripts.delver.const")
local geo = require("scripts.delver.geometry")
local log = require("scripts.delver.log")
local state = require("scripts.delver.state")
local visibility = require("scripts.gtp_delvervisibility")

---@class LD_Map
-- Legacy exclusions mixed hidden template permissions with observed evidence.
-- New policy invalidates that old candidate memory once, without game edits.
local M = { exclusion_policy = "player-wall-v1" }

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
---@field ambiguous boolean?
---@field adjacent_sides integer?  -- known touching walls, including unentered map footprints
---@field known_normal_neighbor boolean?

---@type table<LD_Cid, LD_Candidate>
M.candidates = {}

---@class LD_Room
---@field lid integer
---@field mirror_lid integer?
---@field tl_cid integer  -- top-left cid
---@field safe_cid integer
---@field mirror_safe_cid integer?
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
    safe_cid = room_desc.SafeGridIndex,
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
local classification_cells, classification_visible_lids
local function touches_narrow_long_side(dir, shape)
  return ((dir == C.DIR.UP or dir == C.DIR.DOWN)
      and (shape == RoomShape.ROOMSHAPE_IH
        or shape == RoomShape.ROOMSHAPE_IIH))
    or ((dir == C.DIR.LEFT or dir == C.DIR.RIGHT)
      and (shape == RoomShape.ROOMSHAPE_IV
        or shape == RoomShape.ROOMSHAPE_IIV))
end

local function fake_type(cid)
  local known_normal_sides = 0
  local touches_special_room = false
  -- Count walls touching this grid cell, not distinct room IDs. At the
  -- missing corner of an L-shaped room, two walls belong to one room but
  -- still rule out a super-secret room.
  local adjacent_sides = 0

  local neighbors = geo.get_neighbors(cid)
  for dir, n_cid in pairs(neighbors) do
    local n_cell = generation_layout_cell(n_cid)
    if n_cell then
      if n_cell.category == C.CELL.CATEGORY.BOSS then
        return nil
      elseif n_cell.category == C.CELL.CATEGORY.NORMAL or
             n_cell.category == C.CELL.CATEGORY.SPECIAL then
        local neighbor_room = M.rooms[n_cell.lid]
        local shape = neighbor_room.shape
        if touches_narrow_long_side(dir, shape) then return nil end

        adjacent_sides = adjacent_sides + 1
        if n_cell.category == C.CELL.CATEGORY.NORMAL then
          known_normal_sides = known_normal_sides + 1
        else
          touches_special_room = true
        end
      elseif n_cell.category == C.CELL.CATEGORY.UNKNOWN then
        if touches_narrow_long_side(dir, M.rooms[n_cell.lid].shape) then
          return nil
        end
        adjacent_sides = adjacent_sides + 1
      end
    else
      -- The minimap exposes a visible room's position and narrow shape even
      -- before entry. Its hidden type and door layout stay unknown.
      local visible_cell = classification_cells and classification_cells[n_cid]
      if visible_cell and classification_visible_lids[visible_cell.lid]
        and not M.rooms[visible_cell.lid].is_red then
        if touches_narrow_long_side(dir, M.rooms[visible_cell.lid].shape) then
          return nil
        end
        adjacent_sides = adjacent_sides + 1
      end
    end
  end

  if adjacent_sides >= 2 then
    -- A super-secret room must be a dead end. Known room footprints fix this
    -- as regular, even when an adjacent room's type is still hidden.
    return C.SECRET_TYPE.REGULAR, false, adjacent_sides, known_normal_sides > 0
  end
  if adjacent_sides == 1 then
    -- Single-connection REGULAR rooms are rare but valid, including behind
    -- special rooms. Full map visibility does not make them SUPER-only.
    -- Only SUPER is ruled out when the sole neighbor is known to be special.
    return C.SECRET_TYPE.REGULAR, not touches_special_room,
      adjacent_sides, known_normal_sides > 0
  end

  return nil
end

local function find_fakes()
  for cid = 0, C.MAP.SIZE - 1 do
    if M.cells[cid] then
      goto continue
    end

    local secret_type, ambiguous, adjacent_sides, known_normal_neighbor = fake_type(cid)
    if secret_type == nil then
      goto continue
    end

    M.candidates[cid] = {
      cid = cid,
      secret_type = secret_type,
      ambiguous = ambiguous,
      adjacent_sides = adjacent_sides,
      known_normal_neighbor = known_normal_neighbor,
      lid = nil,
      marker_status = C.MARKER.STATUS.HIDDEN,
      entries = build_entries(cid),
    }

    ::continue::
  end
end

-- The game exposes the full floor layout at floor creation. Keep that data
-- only for protecting real walls from a false negative and for explicit clue
-- items; the candidate table shown to the player uses explored rooms only.
M.truth_real = {}
M.known_lids = {}
M.excluded_cids = {}
M.floor_revision = 0
M.world_card_used = false
M.full_layout_revealed = false
local knowledge_signature
local find_ultra_fakes

function M.note_world_card()
  M.world_card_used = true
  knowledge_signature = nil
end

function M.is_real(cid)
  return M.truth_real[cid] ~= nil
end

function M.truth_type(cid)
  local real = M.truth_real[cid]
  return real and real.secret_type
end

function M.truth_next_to(lid)
  for _, real in pairs(M.truth_real) do
    if real.secret_type ~= C.SECRET_TYPE.ULTRA then
      for _, entry in ipairs(real.entries) do
        if entry.source_lid == lid then return true end
      end
    end
  end
  return false
end

function M.is_known_room_at(cid)
  local cell = M.cells[cid]
  return cell ~= nil and M.known_lids[cell.lid] == true
end

function M.has_visible_unexplored_room_at(cid)
  local cell = M.cells[cid]
  if not cell or M.known_lids[cell.lid] then return false end
  local room = M.rooms[cell.lid]
  local lid = state.get_dimension() == C.DIMENSION.MIRROR
    and (room.mirror_lid or room.lid) or room.lid
  local desc = Game():GetLevel():GetRooms():Get(lid)
  -- A hidden real secret room also has a descriptor, but no visible map tile.
  -- Hiding its star would expose the true location by omission.
  return desc ~= nil and visibility.flags(desc, state.get_dimension()) ~= 0
end

function M.exclude_candidate(cid)
  if M.is_real(cid) then return false end
  local was_visible = M.candidates[cid] ~= nil
  M.excluded_cids[cid] = true
  M.candidates[cid] = nil
  return was_visible
end

function M.update_knowledge(force)
  local level = Game():GetLevel()
  local descriptors = level:GetRooms()
  local current = level:GetCurrentRoomDesc()
  local current_lid = current and current.ListIndex
  local known_cells, known_lids, known_ids = {}, {}, {}
  local visible_lids, visible_ids = {}, {}
  local public_typed_lids, public_typed_ids = {}, {}
  -- Count generated rooms, not currently held items: Fragmented Card can add
  -- another REGULAR room at floor entry, then be dropped before discovery.
  -- Only use full descriptors for completion; candidate geometry stays based
  -- on explored/public map information below.
  local secret_counts, discovered_counts = {}, {}
  local all_original_rooms_visible = true
  for lid, room in pairs(M.rooms) do
    if lid == room.lid then
      local effective_lid = state.get_dimension() == C.DIMENSION.MIRROR
        and (room.mirror_lid or lid) or lid
      local desc = descriptors:Get(effective_lid)
      local visited = desc and (desc.VisitedCount or 0) > 0
      local entered = visited or (current_lid ~= nil
        and (current_lid == lid or current_lid == room.mirror_lid))
      local flags = desc and visibility.flags(desc, state.get_dimension()) or 0
      local is_secret = room.type == C.SECRET_TYPE.REGULAR
        or room.type == C.SECRET_TYPE.SUPER
        or room.type == C.SECRET_TYPE.ULTRA
      local revealed = is_secret and flags ~= 0
      if is_secret and not room.is_red and desc
        and (state.get_dimension() ~= C.DIMENSION.MIRROR or room.mirror_lid) then
        secret_counts[room.type] = (secret_counts[room.type] or 0) + 1
        if entered or revealed then
          discovered_counts[room.type] = (discovered_counts[room.type] or 0) + 1
        end
      end
      -- A visible room icon identifies a boss or special room before entry.
      -- A plain map box reveals only its footprint, not its actual type.
      local category = C.CELL.ROOM_TYPE_TO_CATEGORY[room.type]
      local public_type = not room.is_red
        and (state.get_dimension() ~= C.DIMENSION.MIRROR or room.mirror_lid)
        and (category == C.CELL.CATEGORY.BOSS
          or category == C.CELL.CATEGORY.SPECIAL)
        and (flags & 4) ~= 0 -- RoomDescriptor.DISPLAY_ICON
      if not room.is_red and not is_secret and flags == 0 then
        all_original_rooms_visible = false
      end
      if flags ~= 0 then
        visible_lids[lid] = true
        visible_ids[#visible_ids + 1] = lid
      end
      if entered or revealed then
        known_lids[lid] = true
        known_ids[#known_ids + 1] = lid
        for _, cid in ipairs(room.cids) do known_cells[cid] = M.cells[cid] end
      elseif public_type then
        public_typed_lids[lid] = true
        public_typed_ids[#public_typed_ids + 1] = lid
        for _, cid in ipairs(room.cids) do known_cells[cid] = M.cells[cid] end
      end
    end
  end
  local function all_found(kind)
    return (secret_counts[kind] or 0) > 0
      and discovered_counts[kind] == secret_counts[kind]
  end
  local regular_found = all_found(C.SECRET_TYPE.REGULAR)
  local super_found = all_found(C.SECRET_TYPE.SUPER)
  local ultra_found = all_found(C.SECRET_TYPE.ULTRA)
  local treasure_map_owned = false
  local game = Game()
  for player_index = 0, game:GetNumPlayers() - 1 do
    local player = Isaac.GetPlayer(player_index)
    if player and player:Exists()
      and player:HasCollectible(CollectibleType.COLLECTIBLE_TREASURE_MAP) then
      treasure_map_owned = true
      break
    end
  end
  local full_layout_revealed = treasure_map_owned
    or M.world_card_used or all_original_rooms_visible
  if full_layout_revealed then
    -- The map reveals an unentered room's location and shape, but its actual
    -- special type and door layout remain private until entry.
    for lid in pairs(visible_lids) do
      if not known_lids[lid] and not public_typed_lids[lid]
        and not M.rooms[lid].is_red then
        for _, cid in ipairs(M.rooms[lid].cids) do
          local cell = M.cells[cid]
          if cell and cell.category ~= C.CELL.CATEGORY.SECRET then
            known_cells[cid] = {
              cid = cid, lid = lid, category = C.CELL.CATEGORY.UNKNOWN,
            }
          end
        end
      end
    end
  end
  table.sort(known_ids)
  table.sort(visible_ids)
  table.sort(public_typed_ids)
  local signature = tostring(state.get_dimension()) .. ":" .. table.concat(known_ids, ",")
    .. "|" .. table.concat(visible_ids, ",") .. "|" .. tostring(regular_found)
    .. "|" .. tostring(super_found)
    .. "|" .. tostring(ultra_found)
    .. "|" .. tostring(full_layout_revealed)
    .. "|room-icon:" .. table.concat(public_typed_ids, ",")
  if not force and signature == knowledge_signature then return false end

  local full_cells, previous = M.cells, M.candidates
  M.cells, M.candidates = known_cells, {}
  classification_cells, classification_visible_lids = full_cells, visible_lids
  for cid, cell in pairs(known_cells) do
    if cell.category == C.CELL.CATEGORY.SECRET then
      M.candidates[cid] = {
        cid = cid, secret_type = M.rooms[cell.lid].type, lid = cell.lid,
        marker_status = C.MARKER.STATUS.HIDDEN, entries = build_entries(cid),
      }
    end
  end
  find_fakes()
  classification_cells, classification_visible_lids = nil, nil
  find_ultra_fakes()
  for cid, candidate in pairs(M.candidates) do
    if candidate.lid == nil then
      if candidate.ambiguous then
        if regular_found then
          candidate.secret_type = C.SECRET_TYPE.SUPER
          candidate.ambiguous = false
        elseif super_found then
          candidate.secret_type = C.SECRET_TYPE.REGULAR
          candidate.ambiguous = false
        end
      end
      if M.candidates[cid] and ((regular_found and candidate.secret_type == C.SECRET_TYPE.REGULAR)
        or (super_found and candidate.secret_type == C.SECRET_TYPE.SUPER)
        or (ultra_found and candidate.secret_type == C.SECRET_TYPE.ULTRA)) then
        M.candidates[cid] = nil
      end
    end
  end
  M.cells = full_cells
  M.known_lids = known_lids
  M.full_layout_revealed = full_layout_revealed
  knowledge_signature = signature
  for cid, candidate in pairs(M.candidates) do
    local occupied = M.cells[cid]
    local visible_red = occupied and M.rooms[occupied.lid].is_red
      and (known_lids[occupied.lid] or visible_lids[occupied.lid])
    if candidate.lid == nil and visible_red then
      -- Red rooms cannot extend generation, but an already visible occupied
      -- tile cannot itself remain a fake single-connection candidate.
      M.candidates[cid] = nil
    elseif M.excluded_cids[cid] and not M.is_real(cid) then
      M.candidates[cid] = nil
    else
      local old = previous[cid]
      if old then
        for _, entry in ipairs(candidate.entries) do
          for _, prior in ipairs(old.entries) do
            if entry.source_lid == prior.source_lid
              and entry.doorslot == prior.doorslot then
              entry.checked = prior.checked
              break
            end
          end
        end
      end
    end
  end
  M.fake_baseline = {}
  for cid, candidate in pairs(M.candidates) do
    if candidate.lid == nil then M.fake_baseline[cid] = true end
  end
  return true
end

find_ultra_fakes = function()
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
             (n_cell.category ~= C.CELL.CATEGORY.UNKNOWN
               and M.rooms[n_cell.lid].type == RoomType.ROOM_CURSE) then
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

      if not blocked[e_cid] and not M.cells[e_cid]
        and (not M.candidates[e_cid]
          or M.candidates[e_cid].secret_type == C.SECRET_TYPE.ULTRA) then
        -- Partial knowledge must not replace a regular/super possibility
        -- with an ultra-secret guess.
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
        if cand and cand.secret_type == C.SECRET_TYPE.ULTRA and cand.lid == nil then
          M.candidates[e_cid] = nil
        end
      end
    end
    ::continue::
  end

  for cid, cand in pairs(M.candidates) do
    if cand.secret_type == C.SECRET_TYPE.ULTRA and
       not cand.lid and #cand.entries == 0 then
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
  M.truth_real = {}
  M.known_lids = {}
  M.excluded_cids = {}
  M.floor_revision = M.floor_revision + 1
  M.world_card_used = false
  M.full_layout_revealed = false
  knowledge_signature = nil

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
      main.mirror_safe_cid = desc.SafeGridIndex
      M.rooms[desc.ListIndex] = main
    end
  end
  for cid, cell in pairs(M.cells) do
    if cell.category == C.CELL.CATEGORY.SECRET then
      local secret_type = M.rooms[cell.lid].type
      M.truth_real[cid] = {
        lid = cell.lid, secret_type = secret_type, entries = build_entries(cid),
      }
    end
  end
  M.update_knowledge(true)

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
        M.exclude_candidate(n_cid)
      end
    end
  end
end

return M
