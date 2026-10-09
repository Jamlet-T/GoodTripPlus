-- MiniMapAPI 2.61 main.lua:2050/2214：bounded 本体原点为 (screen-width-x, screenY+y-2)，
-- 轮廓裁剪却仍使用旧原点 (+16,-8)，导致框外的黑底随地图滚动。
-- 只替换 bounded 的轮廓 pass；复用上游 sprite/房间/配置，不改它的文件或存档。
-- outline 小图动画是 16x16、pivot (0,0)，格距 (8,7)。以框内矩形相交计算 Render 裁剪。
return function(api)
  if not api or api._gtpBoundedShadowInstalled
    or type(api.renderRoomShadows)~='function' or type(api.GetScreenTopRight)~='function'
    or type(api.GetFrameBR)~='function' or not api.SpriteMinimapSmall then return end
  api._gtpBoundedShadowInstalled=true
  local original=api.renderRoomShadows
  local logged=false
  function api:renderRoomShadows(cutoff,...)
    local scale=self.GlobalScaleX or 1
    if not cutoff or self:IsLarge() or self:GetConfig('DisplayMode')~=2 or scale<1 then
      return original(self,cutoff,...)
    end
    if not self:GetConfig('ShowShadows') or self:GetTransparency()~=1 then return end
    local screen=self:GetScreenTopRight()
    local x=screen.X-self:GetConfig('MapFrameWidth')-self:GetConfig('PositionX')
    local y=screen.Y+self:GetConfig('PositionY')-2
    local frame=self:GetFrameBR()
    local left,top,right,bottom=x+2,y+2,x+frame.X,y+frame.Y
    if not logged then
      logged=true
      pcall(function()
        Isaac.DebugString(string.format('[GTPbounded] shadow clip active rect=%.1f,%.1f,%.1f,%.1f',
          left,top,right,bottom))
      end)
    end
    local sprite=self.SpriteMinimapSmall
    local colorScale=self.isRepentance and 1 or 255
    sprite.Color=Color(1,1,1,self:GetTransparency(),
      self:GetConfig('DefaultOutlineColorR')*colorScale,
      self:GetConfig('DefaultOutlineColorG')*colorScale,
      self:GetConfig('DefaultOutlineColorB')*colorScale)
    sprite.Scale=Vector(scale,1)
    sprite:SetFrame('RoomOutline',1)
    for _,room in ipairs(self:GetLevel() or {}) do
      if room.RenderOffset and (room:IsShadow() or room:IsVisible()) then
        for _,cell in ipairs(self:GetRoomShapePositions(room.Shape)) do
          local px=room.RenderOffset.X+cell.X*8*scale
          local py=room.RenderOffset.Y+cell.Y*7
          local width=16*scale
          if px<right and px+width>left and py<bottom and py+16>top then
            sprite:Render(Vector(px,py),
              Vector(math.max(0,left-px),math.max(0,top-py)),
              Vector(math.max(0,px+width-right),math.max(0,py+16-bottom)))
          end
        end
      end
    end
  end
end
