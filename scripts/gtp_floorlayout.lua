local Layout = {}
Layout.__index = Layout
local empty = {}

function Layout.new()
  return setmetatable({revision = 0}, Layout)
end

function Layout:publish(scene, count, cells, reason)
  local rooms, sets = {}, {}
  for _, desc in pairs(cells) do
    local id = desc.SafeGridIndex
    rooms[id], sets[id] = desc, {}
  end
  local function connect(a, other)
    if not other then return end
    local b = other.SafeGridIndex
    if a ~= b then sets[a][b], sets[b][a] = true, true end
  end
  for cell, desc in pairs(cells) do
    local a = desc.SafeGridIndex
    if cell % 13 ~= 12 then connect(a, cells[cell + 1]) end
    connect(a, cells[cell + 13])
  end
  local neighbors = {}
  for id, set in pairs(sets) do
    local list = {}
    for other in pairs(set) do list[#list + 1] = other end
    neighbors[id] = list
  end
  self.revision = self.revision + 1
  self.snapshot = {
    floorId = scene.floorId, dimension = scene.dimension, count = count,
    layoutRev = self.revision, reason = reason, cells = cells, rooms = rooms, neighbors = neighbors,
  }
  return self.snapshot
end

function Layout:invalidate()
  self.snapshot = nil
end

function Layout:cells(view)
  local snapshot = view and view.layout or self.snapshot
  return snapshot and snapshot.cells or empty
end

function Layout:rooms(view)
  local snapshot = view and view.layout or self.snapshot
  return snapshot and snapshot.rooms or empty
end

function Layout:neighbors(id, view)
  local snapshot = view and view.layout or self.snapshot
  return snapshot and snapshot.neighbors[id] or empty
end

return Layout
