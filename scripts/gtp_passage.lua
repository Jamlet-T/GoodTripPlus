-- 门通路判据；来源 gtp_travel.lua:98-108（2026-10-07），无游戏全局依赖。
local LOCKED_DOOR_VARIANTS = {
  [1] = true, [2] = true, [3] = true, [4] = true, [5] = true, [6] = true, [7] = true,
}

local function is_passage(door)
  if not LOCKED_DOOR_VARIANTS[door.Desc.Variant] then
    return true
  end
  return door:IsOpen() == true
end

return is_passage
