-- 来源：gtrep.lua 的 draw_minapi_room_highlight；裁剪与贴图选择对齐
-- MinimapAPI main.lua renderBoundedMinimap 的房间绘制段。
return function(api, room, color, vector)
  if not api or not room or not room.RenderOffset or not room:IsVisible() then return end
  local large = api:IsLarge()
  local sprite = large and api.SpriteMinimapLarge or api.SpriteMinimapSmall
  local frame = api:GetRoomShapeFrame(room.Shape)
  if type(frame) ~= 'number' then return end
  local animation
  if room == api:GetCurrentRoom() then
    animation = 'RoomCurrent'
  elseif room:IsClear() then
    animation = 'RoomVisited'
  elseif api:GetConfig('DisplayExploredRooms') and room:IsVisited() then
    sprite = large and api.SpriteMinimapCustomLarge or api.SpriteMinimapCustomSmall
    animation = 'RoomSemivisited'
  else
    animation = 'RoomUnvisited'
  end
  if not sprite then return end

  local tl, br = vector(0, 0), vector(0, 0)
  local scale = api.GlobalScaleX or 1
  -- 上游在镜像及翻转过渡时回退到无框小地图；按住地图键的大图也无框。
  if not large and api:GetConfig('DisplayMode') == 2 and scale >= 1 then
    local screen = api:GetScreenTopRight()
    local ox = screen.X - api:GetConfig('MapFrameWidth') - api:GetConfig('PositionX')
    local oy = screen.Y + api:GetConfig('PositionY') - 2
    local size = api:GetRoomShapeGridSize(room.Shape)
    local pivot = api.RoomShapeGridPivots[room.Shape]
    local px, py = 8 * pivot.X, 7 * pivot.Y
    local width, height = 9 * size.X + 2, 8 * size.Y + 2
    local dx, dy = room.RenderOffset.X - ox, room.RenderOffset.Y - oy
    local frameBR = api:GetFrameBR()
    local bx, by = dx + width - frameBR.X - px, dy + height - frameBR.Y - py
    local tx, ty = -dx + px, -dy + py
    if bx >= width or by >= height or tx - px >= width or ty - py >= height then return end
    local function clamp(n, upper) return math.max(0, math.min(n, upper)) end
    tl = vector(clamp(tx, width), clamp(ty, height))
    br = vector(clamp(bx, width), clamp(by, height))
  end
  sprite:SetFrame(animation, frame)
  sprite.Scale = vector(scale, 1)
  sprite.Color = color
  sprite:Render(room.RenderOffset, tl, br)
end
