-- 门扫描与门图生命周期的游戏 API 适配。
-- 来源：gtrep.lua 的门图、扫门、层身份和落盘函数（2026-10-07）。
-- context 显式传入共享状态和辅助状态访问器，不捕获 gtrep 的可重赋值 local。
return function(gt, context)
local door_state = context.state
local Penalty = require('scripts.gtp_doorpenalty')
local function door_graph()
    local d = Game():GetRoom():IsMirrorWorld() and 1 or 0
    local link, swept = door_state:dimension(d)
    return link, swept, d
end
function gt:get_door_graph()
  return door_graph()
end

function gt:door_evidence_from(here)
  local _,_,dim=door_graph()
  return (door_state.evidence[dim] or {})[here] or {}
end

function gt:reset_door_floor()
  door_state:reset(gt:level_identity())
  context.reset_aux()
  gt:load_door_state()
end

function gt:ensure_door_floor()
  if door_state.identity ~= gt:level_identity() then gt:reset_door_floor() end
end
function gt:is_secret_room(rd)
    if not rd or not rd.Data then
      return false
    end
    local t = rd.Data.Type
    return t == 7 or t == 8 or t == 29
end

function gt:door_links_of(sgi)
  local link, swept = door_graph()
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

function gt:sweep_doors()
    gt:ensure_door_floor()
    local aux = context.get_aux()
    local live = Game():GetRoom()
    local lvl = Game():GetLevel()
    local here = lvl:GetCurrentRoomDesc().SafeGridIndex
    local _, _, dim = door_graph()
    door_state:mark_swept(dim, here)
    door_state.evidence[dim]=door_state.evidence[dim] or {}
    local previous=door_state.evidence[dim][here] or {}
    local observed={}
    for i = 0, 7 do
      local door = live:GetDoor(i)
      --DOOR_HIDDEN is an unbombed wall, so no passage; a door that is closed right now
      --is no passage either (see gt:door_is_passage in gtp_travel).
      --All read live so nothing is from different moments.
      --（实测：炸开之后 variant 会变成 8，所以这条判据本身就够用，别再加「已炸开」判据）
      if door then
        local tdes = lvl:GetRoomByIdx(door.TargetRoomIndex, -1)
        if tdes then
          local there = tdes.SafeGridIndex
          local evidence=Penalty.describe(door,live:GetType(),tdes.Data and tdes.Data.Type,i)
          evidence.from,evidence.to=here,there
          observed[i]=evidence
          local old=previous[i]
          if not old or old.to~=there or old.variant~=evidence.variant
              or old.var_data~=evidence.var_data or old.spikes~=evidence.spikes
              or old.current_type~=evidence.current_type or old.target_type~=evidence.target_type
              or old.open~=evidence.open or old.locked~=evidence.locked then
            door_state.dirty=true
            pcall(function()
              Isaac.DebugString(string.format('[GTPdoor] dim=%s from=%s to=%s slot=%s variant=%s varData=%s spikes=%s types=%s/%s sprite=%s',
                dim,here,there,i,evidence.variant,evidence.var_data,tostring(evidence.spikes),
                evidence.current_type,evidence.target_type,evidence.sprite))
            end)
          end
          --curse-room spikes are read off the door itself: Flat File strips them
          --once and for good, so the trinket in hand says nothing about this door
          if door.TargetRoomType == RoomType.ROOM_CURSE then
            local value=door.VarData ~= 0
            if aux.bare_out[there]~=value then aux.bare_out[there]=value; door_state.dirty=true end
          elseif live:GetType() == RoomType.ROOM_CURSE then
            local value=door.VarData ~= 0
            if aux.bare_in[here]~=value then aux.bare_in[here]=value; door_state.dirty=true end
          end
          door_state:observe(dim, here, there, i, gt:door_is_passage(door))
        end
      end
    end
    for slot in pairs(previous) do if not observed[slot] then door_state.dirty=true end end
    door_state.evidence[dim][here]=observed
end

function gt:level_identity()
  local lvl = Game():GetLevel()
  if not lvl then return nil end
  local seeds = Game():GetSeeds()
  return 'F3:' .. table.concat({
    lvl:GetStage(),
    lvl:GetStageType(),
    lvl:GetAbsoluteStage(),
    Game():GetSeeds():GetStartSeed(),
    seeds.GetStageSeed and seeds:GetStageSeed(lvl:GetStage()) or 0,
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
    door_state.dirty = false
  else
    Isaac.DebugString("[GoodTripPlus][persist] 门图落盘失败（不影响传送）：" .. tostring(err))
  end
end

function gt:load_door_state()
  if not gt.persist_parse then return false end
  local ok, state = pcall(function()
    if gt.persist_read_record then return gt:persist_read_record() end
    if not gt:HasData() then return nil end
    return gt.persist_parse(gt:LoadData())
  end)
  if not ok then
    Isaac.DebugString("[GoodTripPlus][persist] 读档失败（不影响传送）：" .. tostring(state))
    return false
  end
  if not state or state.identity ~= gt:level_identity() then return false end
  door_state.link = state.link
  door_state.swept = state.swept
  door_state.evidence = state.evidence or {}
  context.set_aux(state)
  door_state.dirty = false
  return true
end
end
