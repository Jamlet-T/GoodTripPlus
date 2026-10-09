-- 当前房间真实门适配。预览不修改资源；开锁后等待引擎门动画，重扫门图再传送。
local Policy=require('scripts.gtp_unlock')
return function(gt)
  local pending
  local function trace(message)
    pcall(function() Isaac.DebugString('[GTPunlock] '..message) end)
  end
  function gt:adjacent_unlock_pending() return pending~=nil end
  function gt:clear_adjacent_unlock() pending=nil end
  function gt:adjacent_unlock_state(gid)
    if not gt:get_config_bool('AutoUnlockAdjacent',false) then return nil end
    local target=gt:grid_room_desc(gid)
    local st=gt:travel_cur_state()
    local p=st.player
    if not target or not st.cur or not st.cur.Clear or not st.room or
      not p or not p:Exists() or p:IsDead() then return nil end
    if target.ListIndex==st.cur.ListIndex then return nil end
    for slot=0,7 do
      local door=st.room:GetDoor(slot)
      if door and type(door.TargetRoomIndex)=='number' and door.TargetRoomIndex>=0 then
        local rd=gt:room_desc_at(door.TargetRoomIndex)
        if rd and rd.Data and rd.ListIndex==target.ListIndex then
          local variant=door.Desc and door.Desc.Variant
          local cost=Policy.cost({variant=variant,open=door:IsOpen(),locked=door:IsLocked(),
            arcade=door.IsTargetRoomArcade and door:IsTargetRoomArcade(),
            pay_to_play=p.HasCollectible and p:HasCollectible(240)})
          if cost then
            return {door=door,slot=slot,cost=cost,affordable=Policy.affordable(cost,
              {keys=p:GetNumKeys(),coins=p:GetNumCoins(),golden=p:HasGoldenKey()}),player=p}
          end
        end
      end
    end
  end
  function gt:prepare_adjacent_unlock(gid,source)
    if pending then return 'pending' end
    local s=gt:adjacent_unlock_state(gid)
    if not s then return 'ready' end
    if not s.affordable then return 'failed' end
    local p,door=s.player,s.door
    local keys,coins=p:GetNumKeys(),p:GetNumCoins()
    local accepted
    if s.cost.kind=='coin' then
      -- TryUnlock 文档仅保证钥匙解锁；金币门显式扣费，不调用钥匙接口。
      p:AddCoins(-s.cost.amount)
      door:SetLocked(false); door:Open()
      accepted=not door:IsLocked()
      if not accepted then p:AddCoins(s.cost.amount) end
    else
      accepted=false
      for _=1,s.cost.amount do
        if not door:IsLocked() then accepted=true; break end
        if not door:TryUnlock(p,false) then break end
        accepted=not door:IsLocked()
      end
    end
    trace(string.format('gid=%s slot=%s kind=%s accepted=%s keys=%s->%s coins=%s->%s open=%s locked=%s',
      gid,s.slot,s.cost.kind,tostring(accepted),keys,p:GetNumKeys(),coins,p:GetNumCoins(),
      tostring(door:IsOpen()),tostring(door:IsLocked())))
    if not accepted then return 'failed' end
    gt:sweep_doors(); gt:save_door_state()
    if door:IsOpen() then return 'ready' end
    pending={gid=gid,source=source,door=door,from=gt:travel_cur_state().cur.ListIndex,
      identity=gt:level_identity(),frame=Game():GetFrameCount(),player=p}
    return 'pending'
  end
  gt:AddCallback(ModCallbacks.MC_POST_UPDATE,function()
    if not pending or Game():IsPaused() then return end
    local req=pending
    local st=gt:travel_cur_state()
    if not gt:get_config_bool('AutoUnlockAdjacent',false) or req.identity~=gt:level_identity()
      or not st.cur or st.cur.ListIndex~=req.from or not req.player:Exists() or req.player:IsDead()
      or Game():GetFrameCount()-req.frame>120 then
      pending=nil; trace('cancel gid='..req.gid); return
    end
    if not req.door:IsOpen() then return end
    pending=nil
    gt:sweep_doors(); gt:save_door_state()
    gt:try_cursor_travel(req.gid,req.source)
  end)
  for _,cb in ipairs({ModCallbacks.MC_POST_NEW_ROOM,ModCallbacks.MC_POST_NEW_LEVEL,
    ModCallbacks.MC_POST_GAME_STARTED,ModCallbacks.MC_PRE_GAME_EXIT}) do
    gt:AddCallback(cb,gt.clear_adjacent_unlock)
  end
end
