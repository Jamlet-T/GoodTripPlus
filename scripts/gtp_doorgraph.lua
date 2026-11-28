-- 门图状态操作：纯 Lua，不读取游戏 API。
-- 来源：gtrep.lua 的 door_graph / sweep_doors / new_level（2026-10-07）。
local Graph = {}
Graph.__index = Graph

function Graph.new()
  return setmetatable({ link = {}, swept = {}, evidence = {}, dirty = false, doorRev = 0 }, Graph)
end

function Graph:reset(identity, force)
  if not force and self.identity == identity then return false end
  self.identity = identity
  self.link, self.swept, self.evidence, self.dirty = {}, {}, {}, false
  self.doorRev = self.doorRev + 1
  return true
end

function Graph:restore(record)
  if self.identity == nil or record.identity ~= self.identity then return false end
  self.link, self.swept, self.evidence = record.link, record.swept, record.evidence or {}
  self.dirty = false
  self.doorRev = self.doorRev + 1
  return true
end

function Graph:mark_saved()
  self.dirty = false
end

-- 旧存档辅助数据只影响落盘，不使通路或逐槽费用失效。
function Graph:mark_aux_dirty()
  self.dirty = true
end

local function same_evidence(old, new)
  return old and old.to == new.to and old.variant == new.variant and old.var_data == new.var_data
    and old.spikes == new.spikes and old.current_type == new.current_type and old.target_type == new.target_type
    and old.open == new.open and old.locked == new.locked and old.passage == new.passage
end

-- 一次提交当前房 0..7 槽：false 确认无门，nil 未解析，表为已解析的逐槽证据。
-- 返回 (changed, liveEvidence, changedSlots)；历史证据不充作本次现场证据。
function Graph:applyRoomObservation(dim, here, slots)
  local link, swept, evidence = self.link[dim] or {}, self.swept[dim] or {}, self.evidence[dim] or {}
  self.link[dim], self.swept[dim], self.evidence[dim] = link, swept, evidence
  local row, previous = link[here] or {}, evidence[here] or {}
  local changed = swept[here] ~= true
  link[here], swept[here] = row, true

  local passages, observed, retained, changed_slots = {}, {}, nil, nil
  local complete = true
  for slot = 0, 7 do
    local e, old = slots[slot], previous[slot]
    if e == nil then
      complete = false
      if old then
        retained = retained or {}
        retained[slot] = old
      end
    elseif e == false then
      if old then changed = true end
    else
      observed[slot] = e
      if not same_evidence(old, e) then
        changed, changed_slots = true, changed_slots or {}
        changed_slots[#changed_slots + 1] = slot
      end
      if e.to ~= here and e.passage and passages[e.to] == nil then
        passages[e.to] = slot -- 首个可通槽（包括 0）；另一扇隐藏墙不能覆盖它。
      end
    end
  end
  if retained then
    for slot, e in pairs(observed) do retained[slot] = e end
  end
  evidence[here] = retained or observed

  for there, slot in pairs(passages) do
    if row[there] ~= slot then row[there], changed = slot, true end
    local reverse = link[there] or {}
    link[there] = reverse
    if reverse[here] == nil then reverse[here], changed = true, true end
  end
  -- 只有所有槽均查清且没有其它可通槽，才能撤销该房间对。旧 D 行
  -- 只保存代表槽（0 与未知槽同编码），不能证明一对房间只有那扇门。
  if complete then
    local function unlink(there)
      local reverse = link[there]
      if row[there] ~= nil then row[there], changed = nil, true end
      if reverse and reverse[here] ~= nil then reverse[here], changed = nil, true end
    end
    for there in pairs(row) do
      if passages[there] == nil then unlink(there) end
    end
    -- 保留原先对已观测的锁门/隐藏墙双向撤边的行为，包括旧档单边记录。
    for _, e in pairs(observed) do
      if e.to ~= here and passages[e.to] == nil then unlink(e.to) end
    end
  end
  if changed then
    self.dirty = true
    self.doorRev = self.doorRev + 1
  end
  return changed, observed, changed_slots
end

return Graph
