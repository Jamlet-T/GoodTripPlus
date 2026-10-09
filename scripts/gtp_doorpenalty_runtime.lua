-- 游戏适配：按门证据规划惩罚，并逐次交给引擎；不直接修改生命或清除无敌帧。
local Policy = require('scripts.gtp_doorpenalty')
return function(gt)
  local owner,identity
  local handlers={}
  local rules={{id='curse_door',test=Policy.penalties}}
  local function log(line) pcall(function() Isaac.DebugString('[GTPtoll] '..line) end) end
  handlers.curse_damage=function(event)
    local p=owner
    -- 在执行时重新检查飞行（受伤可能使角色/道具状态改变）。
    if #Policy.penalties(event.edge,{flying=p:IsFlying()})==0 then return end
    local accepted=p:TakeDamage(event.amount,
      DamageFlag.DAMAGE_CURSED_DOOR | DamageFlag.DAMAGE_NO_PENALTIES,EntityRef(p),0)
    log(string.format('hit from=%s to=%s slot=%s accepted=%s',
      event.edge.from,event.edge.to,tostring(event.edge.slot),tostring(accepted)))
  end
  local executor=Policy.executor(handlers)
  function gt:register_door_penalty_handler(kind,handler)
    assert(type(kind)=='string' and type(handler)=='function')
    handlers[kind]=handler
  end
  function gt:register_door_penalty_rule(id,test)
    assert(type(id)=='string' and type(test)=='function')
    for _,rule in ipairs(rules) do assert(rule.id~=id,'duplicate door penalty rule') end
    rules[#rules+1]={id=id,test=test}
  end
  function gt:door_penalties(edge,actor)
    local result={}
    for _,rule in ipairs(rules) do
      for _,event in ipairs(rule.test(edge,actor) or {}) do result[#result+1]=event end
    end
    return result
  end
  function gt:door_penalty_pending() return executor:pending() end
  function gt:clear_door_penalties() executor:clear(); owner=nil; identity=nil end

  local function descriptor(gid) return gt:grid_room_desc(gid) or gt:room_desc_at(gid) end
  local function fallback(a,b,slot)
    local ra,rb=descriptor(a),descriptor(b)
    local ct=ra and ra.Data and ra.Data.Type or -1
    local tt=rb and rb.Data and rb.Data.Type or -1
    return {from=a,to=b,slot=slot,current_type=ct,target_type=tt,source='room_fallback',
      spikes=ct==10 or tt==10}
  end
  local function edge_for(a,b,slot)
    local record=gt:door_evidence_from(a)[slot]
    if record and record.to==b then
      local edge={}
      for k,v in pairs(record) do edge[k]=v end
      edge.source='door_snapshot'
      if edge.spikes==nil then
        local inferred=fallback(a,b,slot)
        edge.spikes=inferred.spikes
        edge.source='door_unknown_room_fallback'
        -- 只在没有已知门状态时，用当前去刺饰品补充推断。
        if owner:HasTrinket(151) then edge.spikes=false end
      end
      return edge
    end
    local edge=fallback(a,b,slot)
    if owner:HasTrinket(151) then edge.spikes=false end
    return edge
  end
  local function neighbors(a)
    local link,swept=gt:get_door_graph()
    local result,seen={},{}
    -- 一对房间可能有多扇门：先逐槽枚举，不能只读房间对的单一门槽。
    for slot,e in pairs(gt:door_evidence_from(a)) do
      if link[a] and link[a][e.to]~=nil then
        result[#result+1]=edge_for(a,e.to,slot); seen[e.to]=true
      end
    end
    for b,slot in pairs(link[a] or {}) do
      if not seen[b] then result[#result+1]=edge_for(a,b,type(slot)=='number' and slot or -1); seen[b]=true end
    end
    -- 旧档中未重新扫过的房间，可用配置门位补通路；扫过无边的锁门/墙不能兜底。
    for _,b in ipairs(gt:travel_room_neighbors(a)) do
      if not seen[b] and not swept[a] and not swept[b] and gt:has_door_between(a,b) then
        result[#result+1]=edge_for(a,b,-1)
      end
    end
    table.sort(result,function(x,y)
      if x.to~=y.to then return x.to<y.to end
      return x.slot<y.slot
    end)
    return result
  end

  function gt:plan_door_penalties(from,to)
    local p=Isaac.GetPlayer(0)
    owner=p -- 仅规划时使用当前角色；路线优先少惩罚，再比较距离。
    local source,target=descriptor(from),descriptor(to)
    from=source and source.SafeGridIndex or from
    to=target and target.SafeGridIndex or to
    local actor={flying=p:IsFlying()}
    local route=Policy.route(from,to,neighbors,descriptor,function(edge)
      return #gt:door_penalties(edge,actor)
    end)
    if not route then
      route={}
      local a,b=descriptor(from),descriptor(to)
      if a and a.Data and a.Data.Type==10 then route[#route+1]=edge_for(from,to,-1) end
      if b and b.Data and b.Data.Type==10 and not (a and a.Data and a.Data.Type==10) then
        route[#route+1]=edge_for(from,to,-1)
      end
    end
    local events={}
    for _,edge in ipairs(route) do
      -- 保留飞行豁免的门事件，执行时再判断角色状态；避免过程中失去飞行漏扣。
      for _,rule in ipairs(rules) do
        local context=rule.id=='curse_door' and {flying=false} or actor
        for _,event in ipairs(rule.test(edge,context) or {}) do events[#events+1]=event end
      end
      log(string.format('edge from=%s to=%s slot=%s source=%s spikes=%s types=%s/%s flying=%s',
        edge.from,edge.to,tostring(edge.slot),edge.source,tostring(edge.spikes),
        edge.current_type,edge.target_type,tostring(actor.flying)))
    end
    return events
  end
  function gt:apply_travel_door_penalties(from,to)
    assert(not executor:pending(),'previous door penalties still pending')
    local events=gt:plan_door_penalties(from,to)
    identity=gt:level_identity()
    executor:add(events)
    executor:step(Game():GetFrameCount(),function() return true end)
  end
  function gt:update_door_penalties()
    if not executor:pending() or Game():IsPaused() then return end
    if identity~=gt:level_identity() or not owner or not owner:Exists() or owner:IsDead() then
      gt:clear_door_penalties(); return
    end
    executor:step(Game():GetFrameCount(),function()
      return owner:GetDamageCooldown()<=0
    end)
  end
  if ModCallbacks.MC_POST_UPDATE then gt:AddCallback(ModCallbacks.MC_POST_UPDATE,gt.update_door_penalties) end
  gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED,gt.clear_door_penalties)
  gt:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL,gt.clear_door_penalties)
  if ModCallbacks.MC_PRE_GAME_EXIT then gt:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT,gt.clear_door_penalties) end
end
