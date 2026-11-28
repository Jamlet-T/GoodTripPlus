-- 门扫描与门图生命周期的游戏 API 适配。
-- 来源：gtrep.lua 的门图、扫门、层身份和落盘函数（2026-10-07）。
-- context 显式传入共享状态和辅助状态访问器，不捕获 gtp 的可重赋值 local。
return function(gt, context)
local door_state = context.state
local Penalty = require('scripts.gtp_doorpenalty')
local EMPTY = {}

local function valid_dimension(dim)
  return type(dim) == 'number' and dim >= 0
end

local function current_dimension(live)
  local dim = gt.get_current_dimension and gt:get_current_dimension()
  if valid_dimension(dim) then return dim end
  live = live or Game():GetRoom()
  return live and live.IsMirrorWorld and live:IsMirrorWorld() and 1 or 0
end

local function read_dimension(observationContext)
  -- 显式现场只读同层、同维度；不重复读 F3。旧无参调用沿用由调用方
  -- 在读图前 ensure/sweep 的约定（例如一次准入或路线事务内的查询）。
  if observationContext then
    local dim = observationContext.dimension
    if door_state.identity ~= nil and door_state.identity == observationContext.floorId
        and valid_dimension(dim) then return dim end
    return nil
  end
  return current_dimension()
end

function gt:get_door_graph(observationContext)
  local dim = read_dimension(observationContext)
  return door_state.link[dim] or EMPTY, door_state.swept[dim] or EMPTY, dim
end

function gt:door_evidence_from(here, observationContext)
  local dim = read_dimension(observationContext)
  local rooms = door_state.evidence[dim]
  return rooms and rooms[here] or EMPTY
end

function gt:door_graph_revision()
  return door_state.doorRev
end

function gt:mark_door_aux_dirty()
  door_state:mark_aux_dirty()
end

function gt:reset_door_floor(floorId, force)
  floorId = floorId or gt:level_identity()
  if not door_state:reset(floorId, force) then return false end
  context.reset_aux()
  if floorId ~= nil then gt:load_door_state(floorId) end
  return true
end

function gt:ensure_door_floor(floorId)
  floorId = floorId or gt:level_identity()
  if floorId ~= nil and door_state.identity ~= floorId then gt:reset_door_floor(floorId) end
  return floorId
end

function gt:is_secret_room(rd)
    if not rd or not rd.Data then
      return false
    end
    local t = rd.Data.Type
    return t == 7 or t == 8 or t == 29
end

function gt:door_links_of(sgi, observationContext)
  local link, swept = gt:get_door_graph(observationContext)
  local out = {}
  local row = link[sgi]
  if row then
    for other, slot in pairs(row) do
      out[#out + 1] = { other = other, slot = slot }
    end
    table.sort(out, function(a, b) return tostring(a.other) < tostring(b.other) end)
  end
  return out, swept[sgi] == true
end

function gt:door_to(gid)
  local room = Game():GetRoom()
  if not room then return nil end
  for i = 0, 7 do
    local door = room:GetDoor(i)
    if door and door.TargetRoomIndex == gid then
      return door
    end
  end
  return nil
end

-- 显式现场由调用方保证指向同一次稳定观测，不持有跨帧游戏对象。
-- 返回 (doorRev, liveEvidence, changed)；现场无效时不提交，也没有 liveEvidence。
function gt:sweep_doors(observationContext)
    local lvl, live, desc, floorId, dim
    if observationContext then
      lvl, live, desc = observationContext.level, observationContext.room, observationContext.desc
      floorId, dim = observationContext.floorId, observationContext.dimension
    else
      local game = Game()
      lvl, live = game:GetLevel(), game:GetRoom()
      desc = lvl and lvl:GetCurrentRoomDesc()
      if live and desc and desc.Data then
        floorId, dim = gt:level_identity(), current_dimension(live)
      end
    end
    local here = desc and desc.Data and desc.SafeGridIndex
    if not lvl or not live or type(here) ~= 'number' or floorId == nil or not valid_dimension(dim) then
      return door_state.doorRev, nil, false
    end
    gt:ensure_door_floor(floorId)
    local aux = context.get_aux()
    local current_type = live:GetType()
    local slots = {}
    for i = 0, 7 do
      local door = live:GetDoor(i)
      if door == nil then
        slots[i] = false -- 确认空槽，不等同于目标描述符暂时无法解析。
      elseif type(door.TargetRoomIndex) == 'number' then
        local tdes = lvl:GetRoomByIdx(door.TargetRoomIndex, dim)
        if tdes and tdes.Data and type(tdes.SafeGridIndex) == 'number' then
          local there = tdes.SafeGridIndex
          local evidence = Penalty.describe(door, current_type, tdes.Data.Type, i)
          evidence.from, evidence.to, evidence.passage = here, there, gt:door_is_passage(door)
          evidence.target_cell = door.TargetRoomIndex
          slots[i] = evidence
          -- Flat File 永久去掉这扇门的刺；旧辅助字段仍照原口径落盘。
          if door.TargetRoomType == RoomType.ROOM_CURSE then
            local value = door.VarData ~= 0
            if aux.bare_out[there] ~= value then aux.bare_out[there] = value; door_state:mark_aux_dirty() end
          elseif current_type == RoomType.ROOM_CURSE then
            local value = door.VarData ~= 0
            if aux.bare_in[here] ~= value then aux.bare_in[here] = value; door_state:mark_aux_dirty() end
          end
        end
      end
    end
    local changed, observed, changed_slots = door_state:applyRoomObservation(dim, here, slots)
    if changed_slots and gt.is_debug and gt:is_debug() then
      for _, i in ipairs(changed_slots) do
        local evidence = observed[i]
        pcall(function()
          Isaac.DebugString(string.format('[GTPdoor] dim=%s from=%s to=%s slot=%s variant=%s open=%s passage=%s varData=%s spikes=%s types=%s/%s sprite=%s',
            dim,here,evidence.to,i,evidence.variant,tostring(evidence.open),tostring(evidence.passage),
            evidence.var_data,tostring(evidence.spikes),evidence.current_type,evidence.target_type,evidence.sprite))
        end)
      end
    end
    return door_state.doorRev, observed, changed
end

function gt:level_identity()
  local game = Game()
  local lvl = game:GetLevel()
  if not lvl then return nil end
  local seeds = game:GetSeeds()
  local stage = lvl:GetStage()
  return 'F3:' .. table.concat({
    stage,
    lvl:GetStageType(),
    lvl:GetAbsoluteStage(),
    seeds:GetStartSeed(),
    seeds.GetStageSeed and seeds:GetStageSeed(stage) or 0,
    lvl.GetDungeonPlacementSeed and lvl:GetDungeonPlacementSeed() or 0,
    lvl:IsAscent() and 1 or 0,
  }, ":")
end
-- 仅用于迁移旧 GTPDG2，仍要求旧房间数完全相同，不放宽旧图的楼层校验。
function gt:legacy_level_identity()
  local lvl=Game():GetLevel()
  return table.concat({lvl:GetStage(),lvl:GetStageType(),lvl:GetAbsoluteStage(),
    Game():GetSeeds():GetStartSeed(),lvl:GetRooms().Size,lvl:IsAscent() and 1 or 0},':')
end

function gt:save_door_state()
  local aux = context.get_aux()
  if not door_state.dirty then return end
  if door_state.identity ~= gt:level_identity() then return end
  if not gt.persist_serialize then return end
  local ok, err = pcall(function()
    local state = {
      identity = door_state.identity,
      link = door_state.link, swept = door_state.swept,
      evidence = door_state.evidence,
      bare_out = aux.bare_out, bare_in = aux.bare_in,
      pre = aux.pre,
    }
    if gt.persist_write_record then gt:persist_write_record(state)
    else gt:SaveData(gt.persist_serialize(state)) end
  end)
  if ok then
    door_state:mark_saved()
  else
    Isaac.DebugString("[GoodTripPlus][persist] 门图落盘失败（不影响传送）：" .. tostring(err))
  end
end

function gt:load_door_state(floorId)
  floorId = floorId or gt:level_identity()
  if not gt.persist_parse or floorId == nil or floorId ~= door_state.identity then return false end
  local ok, state = pcall(function()
    if gt.persist_read_record then return gt:persist_read_record() end
    if not gt:HasData() then return nil end
    return gt.persist_parse(gt:LoadData())
  end)
  if not ok then
    Isaac.DebugString("[GoodTripPlus][persist] 读档失败（不影响传送）：" .. tostring(state))
    return false
  end
  if not state or not door_state:restore(state) then return false end
  context.set_aux(state)
  return true
end
end
