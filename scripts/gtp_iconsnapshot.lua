-- rewind 快照的纯状态操作：内容不变时复用不可变副本，不持有可变 ItemIcons。
local M = {}
local function same(a, b)
  if not a or #a ~= #b then return false end
  for i = 1, #b do
    if a[i] ~= b[i] then return false end
  end
  return true
end
function M.read(levels, identity, previous)
  local state = {identity=identity, arrays={}, icons={}}
  local copied = 0
  -- 换层不复用；每帧仍检查所有维度，保留原地清空与重建检测能力。
  previous = previous and previous.identity == identity and previous or nil
  for dimension, rooms in pairs(levels or {}) do
    state.arrays[dimension] = rooms
    local icons_by_room = {}
    local old = previous and previous.icons[dimension]
    for _, room in ipairs(rooms) do
      local desc, icons = room.Descriptor, room.ItemIcons
      if desc and desc.ListIndex and icons and #icons > 0 then
        local saved = old and old[desc.ListIndex]
        if not same(saved, icons) then
          saved = {}
          for i = 1, #icons do saved[i] = icons[i] end
          copied = copied + 1
        end
        icons_by_room[desc.ListIndex] = saved
      end
    end
    state.icons[dimension] = icons_by_room
  end
  return state, copied
end
return M
