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
    if not gt:get_config_bool('AutoUnlockAdjacent',true) then return nil,'disabled' end
    local target=gt:grid_room_desc(gid)
    local st=gt:travel_cur_state()
    local p=st.player
    if not target or not st.cur or not gt:room_is_clear(st.cur) or not st.room or
      not p or not p:Exists() or p:IsDead() then return nil,'invalid_context' end
    if target.ListIndex==st.cur.ListIndex then return nil,'same_room' end
    local reason='no_matching_door'
    for slot=0,7 do
      local door=st.room:GetDoor(slot)
      if door and type(door.TargetRoomIndex)=='number' and door.TargetRoomIndex>=0 then
        local rd=gt:room_desc_at(door.TargetRoomIndex)
        if rd and rd.Data and rd.ListIndex==target.ListIndex then
          local variant=door.Desc and door.Desc.Variant
          local cost=Policy.cost({variant=variant,state=door.State,open=door:IsOpen(),locked=door:IsLocked(),
            arcade=door.IsTargetRoomArcade and door:IsTargetRoomArcade(),
            pay_to_play=p.HasCollectible and p:HasCollectible(CollectibleType.COLLECTIBLE_PAY_TO_PLAY)})
          if cost then
            return {door=door,slot=slot,cost=cost,affordable=Policy.affordable(cost,
              {keys=p:GetNumKeys(),coins=p:GetNumCoins(),golden=p:HasGoldenKey()}),player=p}
          end
          reason=string.format('unsupported slot=%s variant=%s open=%s locked=%s payToPlay=%s',
            slot,tostring(variant),tostring(door:IsOpen()),tostring(door:IsLocked()),
            tostring(p.HasCollectible and p:HasCollectible(CollectibleType.COLLECTIBLE_PAY_TO_PLAY)))
        end
      end
    end
    return nil,reason
  end
  function gt:adjacent_unlock_dump(gid)
    local s,reason=gt:adjacent_unlock_state(gid)
    if not s then return '  unlock: '..tostring(reason) end
    return string.format('  unlock: slot=%s kind=%s need=%s affordable=%s keys=%s coins=%s golden=%s',
      s.slot,s.cost.kind,s.cost.amount,tostring(s.affordable),s.player:GetNumKeys(),
      s.player:GetNumCoins(),tostring(s.player:HasGoldenKey()))
  end
  function gt:prepare_adjacent_unlock(gid,source)
    if pending then return 'pending' end
    local s=gt:adjacent_unlock_state(gid)
    if not s then return 'ready' end
    if not s.affordable then return 'failed' end
    local p,door=s.player,s.door
    local keys,coins=p:GetNumKeys(),p:GetNumCoins()
    local accepted
    local remaining=s.cost.amount
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
        local beforeKeys,beforeState=p:GetNumKeys(),door.State
        local result=door:TryUnlock(p,false)
        accepted=not door:IsLocked()
        -- 双锁的第一把可能已扣费却返回 false。仅在有进展时继续，
        -- 总调用次数仍受预检费用限制，不强开、不手工扣钥匙。
        trace(string.format('step gid=%s slot=%s result=%s keys=%s->%s state=%s->%s locked=%s',
          gid,s.slot,tostring(result),beforeKeys,p:GetNumKeys(),tostring(beforeState),
          tostring(door.State),tostring(door:IsLocked())))
        if accepted then remaining=0; break end
        if p:GetNumKeys()<beforeKeys or door.State~=beforeState then
          remaining=remaining-1
        end
        if not result and p:GetNumKeys()>=beforeKeys and door.State==beforeState then break end
      end
    end
    trace(string.format('gid=%s slot=%s kind=%s accepted=%s keys=%s->%s coins=%s->%s open=%s locked=%s',
      gid,s.slot,s.cost.kind,tostring(accepted),keys,p:GetNumKeys(),coins,p:GetNumCoins(),
      tostring(door:IsOpen()),tostring(door:IsLocked())))
    if not accepted and remaining==s.cost.amount then return 'failed' end
    gt:sweep_doors(); gt:save_door_state()
    if door:IsOpen() then return 'ready' end
    pending={gid=gid,source=source,door=door,from=gt:travel_cur_state().cur.ListIndex,
      identity=gt:level_identity(),frame=Game():GetFrameCount(),player=p,remaining=remaining,slot=s.slot}
    return 'pending'
  end
  gt:AddCallback(ModCallbacks.MC_POST_UPDATE,function()
    if not pending or Game():IsPaused() then return end
    local req=pending
    local st=gt:travel_cur_state()
    if not gt:get_config_bool('AutoUnlockAdjacent',true) or req.identity~=gt:level_identity()
      or not st.cur or st.cur.ListIndex~=req.from or not req.player:Exists() or req.player:IsDead()
      or Game():GetFrameCount()-req.frame>120 then
      pending=nil; trace('cancel gid='..req.gid); return
    end
    if req.door:IsLocked() and req.remaining>0 then
      -- 第一锁动画可能暂时拒绝第二把；保留用户请求，逐更新帧尝试。
      local p,door=req.player,req.door
      if not p:HasGoldenKey() and p:GetNumKeys()<1 then
        pending=nil; trace('cancel insufficient keys gid='..req.gid); return
      end
      local beforeKeys,beforeState=p:GetNumKeys(),door.State
      local result=door:TryUnlock(p,false)
      if not door:IsLocked() then req.remaining=0
      elseif p:GetNumKeys()<beforeKeys or door.State~=beforeState then
        req.remaining=req.remaining-1
      end
      if result or p:GetNumKeys()~=beforeKeys or door.State~=beforeState then
        trace(string.format('resume gid=%s result=%s keys=%s->%s state=%s->%s remaining=%s',
          req.gid,tostring(result),beforeKeys,p:GetNumKeys(),tostring(beforeState),
          tostring(door.State),req.remaining))
      end
    end
    if req.door:IsLocked() or not req.door:IsOpen() then return end
    pending=nil
    gt:sweep_doors(); gt:save_door_state()
    gt:try_cursor_travel(req.gid,req.source)
  end)
  for _,cb in ipairs({ModCallbacks.MC_POST_NEW_ROOM,ModCallbacks.MC_POST_NEW_LEVEL,
    ModCallbacks.MC_POST_GAME_STARTED,ModCallbacks.MC_PRE_GAME_EXIT}) do
    gt:AddCallback(cb,gt.clear_adjacent_unlock)
  end
end
