-- MinimapAPI 2.58 main.lua:2352-2389：旧距离仅在 STATE_MAP_EFFECT 下清空，
-- 而 calcAdjacentDistances 只能减小距离，因此历任当前房间会积累为 0。
-- main.lua:2312-2319 在读取当前房间后、更新显示标记和计算距离前调用
-- PickupDetectionEnabled（即使拾取检测关闭也会调用）。在这个同步点清理，
-- 沿用上游的邻接/可见性算法，并兼容普通 render、REPENTOGON/StageAPI HUD render。
-- 不能在 GetCurrentRoom 中清理：小地图绘制居中时还会再次调用它，已算距离会被擦掉。
return function(api)
  if not api or api._gtpDistanceFixInstalled
    or type(api.PickupDetectionEnabled) ~= 'function'
    or type(api.GetConfig) ~= 'function' or type(api.GetLevel) ~= 'function' then
    return
  end
  api._gtpDistanceFixInstalled = true
  local original = api.PickupDetectionEnabled
  function api:PickupDetectionEnabled(...)
    if self:GetConfig('ShowGridDistances') or self:GetConfig('HighlightFurthestRoom') then
      local map = self:GetLevel()
      if type(map) == 'table' then
        for _, room in ipairs(map) do
          room.PlayerDistance = nil
        end
      end
    end
    return original(self, ...)
  end
end
