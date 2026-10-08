-- 命中已经绘制的 MinimapAPI 房间，不从格号重建地图布局。
-- 几何依据：MinimapAPI main.lua renderUnboundedMinimap/renderBoundedMinimap
-- 使用 RenderOffset；minimapapi_minimap1/2.anm2 的图块起点为 (2,2)/(4,4)，
-- 格距分别为 (8,7)/(17,15)，sprite.Scale.X 同时缩放图块起点和格距。
return function(api, pos)
  if not api then return nil end
  local scale = api.GlobalScaleX or 1
  -- 镜像翻转过渡时图块重叠，不选择歧义目标。
  if scale ~= 1 and scale ~= -1 then return nil end
  local map = api:GetLevel()
  if not map then return nil end
  local large = api:IsLarge()
  local width, height, inset = large and 17 or 8, large and 15 or 7, large and 4 or 2
  for _, room in ipairs(map) do
    local origin = room.RenderOffset
    if origin and room.Descriptor and room:IsVisible() then
      for _, cell in ipairs(api:GetRoomShapePositions(room.Shape)) do
        local left = origin.X + (inset + cell.X * width) * scale
        local right = left + width * scale
        local top = origin.Y + inset + cell.Y * height
        if pos.X >= math.min(left, right) and pos.X < math.max(left, right)
          and pos.Y >= top and pos.Y < top + height then
          return room
        end
      end
    end
  end
end
