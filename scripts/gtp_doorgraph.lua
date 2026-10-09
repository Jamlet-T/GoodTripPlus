-- 门图状态操作：纯 Lua，不读取游戏 API。
-- 来源：gtrep.lua 的 door_graph / sweep_doors / new_level（2026-10-07）。
-- 引擎门实体与持久化仍由 gtrep 适配；此处只管理身份、边和变更标记。
local Graph = {}
Graph.__index = Graph

function Graph.new()
  return setmetatable({ link = {}, swept = {}, evidence = {}, dirty = false }, Graph)
end

function Graph:reset(identity)
  self.identity = identity
  self.link, self.swept, self.evidence, self.dirty = {}, {}, {}, false
end

function Graph:dimension(dim)
  self.link[dim] = self.link[dim] or {}
  self.swept[dim] = self.swept[dim] or {}
  return self.link[dim], self.swept[dim]
end

function Graph:mark_swept(dim, here)
  local link, swept = self:dimension(dim)
  link[here] = link[here] or {}
  if not swept[here] then self.dirty = true end
  swept[here] = true
end

-- 通路双向记录；另一端尚未扫门时只记 true，保留已知门槽（包括 0）。
function Graph:observe(dim, here, there, slot, passage)
  if here == there then return end
  local link = self:dimension(dim)
  link[here] = link[here] or {}
  if passage then
    link[there] = link[there] or {}
    if link[here][there] ~= slot then
      link[here][there] = slot
      self.dirty = true
    end
    if link[there][here] == nil then
      link[there][here] = true
      self.dirty = true
    end
  else
    if link[here][there] ~= nil then
      link[here][there] = nil
      self.dirty = true
    end
    if link[there] and link[there][here] ~= nil then
      link[there][here] = nil
      self.dirty = true
    end
  end
end

return Graph
