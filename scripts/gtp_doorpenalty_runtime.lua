-- 游戏适配：按门证据规划惩罚，并逐次交给引擎；不直接修改生命或清除无敌帧。
local Policy = require('scripts.gtp_doorpenalty')
return function(gt)
  local owner,identity
  local handlers={}
  local rules={{id='curse_door',test=Policy.penalties}}
  -- 过路费取证只在调试模式开启时写 [GTPtoll]；规则与伤害照常执行。
  local function log(line)
    if not (gt.is_debug and gt:is_debug()) then return end
    pcall(function() Isaac.DebugString('[GTPtoll] '..line) end)
  end
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
  -- 离网房间（SafeGridIndex < 0：恶魔房 -1、Boss Rush -5、死寂 -8 …）**不是网格上的普通节点**：
  -- 门通向它们是「传送」而不是「走过去」，几何层（gtp_route.lua）按占格永远算不出落点。
  -- 让它们进过路费图，路线就会规划出注定落不了地的跳，整趟传送被判 ambiguous_geometry
  -- 取消（2026-10-25 真机日志：boss 房的门图里留着 156 -> -1，五次远程传送全部静默失败）。
  -- 判定层早就是这个口径（gtp_travel 的 travel_ctx 只接受 0..168），这里补齐执行侧的路线图。
  local function on_grid(gid) return type(gid)=='number' and gid>=0 end
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
    -- 出发点本身离网（玩家站在恶魔房里往外传）：网格上没有可规划的路线，
    -- 交回调用方按「无路线」直接传送，别去枚举注定落不了地的跳。
    if not on_grid(a) then return result end
    -- 一对房间可能有多扇门：先逐槽枚举，不能只读房间对的单一门槽。
    for slot,e in pairs(gt:door_evidence_from(a)) do
      if on_grid(e.to) then
        if link[a] and link[a][e.to]~=nil
            and ((e.variant or -1)<1 or (e.variant or -1)>7 or e.open==true) then
          result[#result+1]=edge_for(a,e.to,slot); seen[e.to]=true
        end
        -- 同一房间对存在多扇门时，关闭门的快照不能再经房间对兜底变成通路。
        seen[e.to]=true
      end
    end
    for b,slot in pairs(link[a] or {}) do
      if not seen[b] and on_grid(b) then
        result[#result+1]=edge_for(a,b,type(slot)=='number' and slot or -1); seen[b]=true
      end
    end
    -- 旧档中未重新扫过的房间，可用配置门位补通路；扫过无边的锁门/墙不能兜底。
    for _,b in ipairs(gt:travel_room_neighbors(a)) do
      if not seen[b] and on_grid(b) and not swept[a] and not swept[b] and gt:has_door_between(a,b) then
        result[#result+1]=edge_for(a,b,-1)
      end
    end
    table.sort(result,function(x,y)
      if x.to~=y.to then return x.to<y.to end
      return x.slot<y.slot
    end)
    return result
  end

  -- 规划一次门图路线，返回 (门事件, 路线)。路线同时是落点依据：执行层用它的
  -- 最后一条边决定入场门槽与过场出发房，费用与落点不再各算一套。
  -- 无路线时 route 为 nil（调用方自行回退），events 仍按诅咒房兜底。
  function gt:plan_door_penalties(from,to)
    local p=Isaac.GetPlayer(0)
    owner=p -- 仅规划时使用当前角色；路线优先少惩罚，再比较距离。
    local source,target=descriptor(from),descriptor(to)
    from=source and source.SafeGridIndex or from
    to=target and target.SafeGridIndex or to
    local actor={flying=p:IsFlying()}
    local route=Policy.route(from,to,neighbors,descriptor,function(edge)
      return #gt:door_penalties(edge,actor)
    end, function(rd) return gt:room_is_clear(rd) end)
    local fallback=not route
    if fallback then
      route={}
      local a,b=descriptor(from),descriptor(to)
      if a and a.Data and a.Data.Type==10 then route[#route+1]=edge_for(from,to,-1) end
      if b and b.Data and b.Data.Type==10 and not (a and a.Data and a.Data.Type==10) then
        route[#route+1]=edge_for(from,to,-1)
      end
      if #route==0 then route=nil end
    end
    local events={}
    for index,edge in ipairs(route or {}) do
      -- 保留飞行豁免的门事件，执行时再判断角色状态；避免过程中失去飞行漏扣。
      for _,rule in ipairs(rules) do
        local context=rule.id=='curse_door' and {flying=false} or actor
        for _,event in ipairs(rule.test(edge,context) or {}) do
          event.route_index=index
          events[#events+1]=event
        end
      end
      log(string.format('edge from=%s to=%s slot=%s source=%s spikes=%s types=%s/%s flying=%s',
        edge.from,edge.to,tostring(edge.slot),edge.source,tostring(edge.spikes),
        edge.current_type,edge.target_type,tostring(actor.flying)))
    end
    -- 兜底路线只用于费用，不能拿来当落点路线（它未必是真实通路）。
    return events, (not fallback) and route or nil
  end
  -- 费用按规划结果结算；与 plan_door_penalties 分离，执行层可以在换房/过场前
  -- 先规划、斩断路线，随后再按快照时序结算。
  function gt:apply_door_penalty_events(events)
    assert(not executor:pending(),'previous door penalties still pending')
    identity=gt:level_identity()
    executor:add(events or {})
    executor:step(Game():GetFrameCount(),function() return true end)
  end
  function gt:apply_travel_door_penalties(from,to)
    local events=gt:plan_door_penalties(from,to)
    gt:apply_door_penalty_events(events)
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
