-- MiniMAPI main.lua:IsLarge/GetTransparency：配置绑定替代原生地图动作。
-- 游戏输入、暂停／玩家就绪状态和帧号由 gt 适配层提供，避免全局改写 Input 或访问上游私有计数。
return function(gt, api)
  if not api or type(api.GetConfig)~='function' or type(api.IsLarge)~='function'
    or type(api.GetTransparency)~='function' then return end
  -- 开局／首次绘图仍检查原生回调是否已注册，但不会再包一层绘图方法。
  if gt.replace_minimap_map_input then
    api._gtpNativeMapInputWrapped=gt:replace_minimap_map_input(api)
  end
  if api._gtpMapInputInstalled then return end
  api._gtpMapInputInstalled=true
  local original_transparency=api.GetTransparency
  local held_frames,last_frame=0,nil
  local function poll()
    local active,frame,suspended=gt:get_map_input_sample()
    if not active then
      local released=held_frames
      local valid_release=last_frame~=nil and frame>=last_frame and not suspended
      held_frames,last_frame=0,nil
      if valid_release and released>0 and type(api.NextMapDisplayMode)=='function'
        and (released<=8 or (api:GetConfig('DisplayMode')==3 and released==9)) then
        api:NextMapDisplayMode()
      end
      return false
    end
    if last_frame==nil or frame<last_frame then
      held_frames=1
    elseif frame>last_frame then
      held_frames=held_frames+frame-last_frame
    end
    last_frame=frame
    return true
  end
  -- 即使暂停时上游不绘图，也在运行循环里清空按住计数。
  gt.update_map_input=poll
  function api:IsLarge(...)
    local held=poll()
    return held or self:GetConfig('DisplayMode')==3
  end
  function api:GetTransparency(...)
    local value=original_transparency(self,...)
    if not poll() or not self:GetConfig('LargeMapFadeInOnHold') then return value end
    local base=gt:get_map_base_opacity(self)
    return base+(1-base)*math.min(held_frames/5,1)
  end
end
