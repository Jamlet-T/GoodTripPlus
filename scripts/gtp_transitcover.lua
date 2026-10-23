-- ChangeRoom 同步中转完成后，原生异步过场的出发画面仍是中转房。
-- 仅在 pending 存活期间盖黑；目标 new_room 或取消清空 pending 即恢复原生入场画面。
return function(get_pending)
  local sprite
  return function()
    local pending=get_pending()
    if not (pending and pending.hide_transit) then return end
    if not sprite then
      sprite=Sprite()
      sprite:Load('gfx/goodtripplus/bounds.anm2',true)
      sprite:SetFrame('line',0)
      sprite.Color=Color(0,0,0,1,0,0,0)
    end
    sprite.Scale=Vector((Isaac.GetScreenWidth()+2)/8,(Isaac.GetScreenHeight()+2)/8)
    sprite:Render(Vector(-1,-1))
  end
end
