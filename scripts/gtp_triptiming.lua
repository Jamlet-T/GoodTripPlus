-- 2.6.19/2.6.20 共用的观测探针：真实毫秒，不写游戏状态或控制过场。
return function(gt)
  local enabled,active,serial=true,nil,0
  local function probe(fn)
    if not enabled then return end
    local ok=pcall(fn)
    if not ok then
      enabled,active=false,nil
      pcall(Isaac.DebugString,'[GTPperf] disabled after diagnostic error')
    end
  end
  local function now() return Isaac.GetTime() end
  local function elapsed(start) return math.max(0,now()-start) end
  local function desc() return Game():GetLevel():GetCurrentRoomDesc() end
  local function write(t,event,extra)
    Isaac.DebugString(string.format(
      '[GTPperf] version=%s id=%s event=%s from=%s target=%s mode=%s dim=%s %s',
      tostring(gt.VERSION),t.id,event,t.from,t.target,t.mode,t.dimension,extra or ''))
  end
  local function context_ok(t)
    return gt:level_identity()==t.floor and gt:get_current_dimension()==t.dimension
      and Game():GetFrameCount()>=t.frame
  end
  local route_original=gt.prepare_travel_route
  if route_original then
    function gt:prepare_travel_route(route)
      local t,start
      probe(function() t=active; if t then start=now(); t.hops=route and #route or 0 end end)
      local result=table.pack(route_original(self,route))
      probe(function()
        if not t or t~=active then return end
        t.route_ms=elapsed(start)
        local r=result[1]
        t.transits=r and (r.transits or r.completed) or 0
      end)
      return table.unpack(result,1,result.n)
    end
  end
  local original=gt.teleport_to_grid_index
  function gt:teleport_to_grid_index(gid)
    local t
    probe(function()
      -- 中转期间或异步等待期间的重入不能覆盖正在测量的请求。
      if active then return end
      local current,target=desc(),gt:grid_room_desc(gid)
      if not target then return end
      serial=serial+1
      local start=now()
      t={id=serial,from=current.SafeGridIndex,target=gid,target_lid=target.ListIndex,
        mode=gt:get_teleport_transition(),dimension=gt:get_current_dimension(),
        floor=gt:level_identity(),frame=Game():GetFrameCount(),start=start,last_render=start,
        max_gap=0,route_ms=0,hops=0,transits=0}
      active=t
    end)
    -- 仅诊断用 pcall 隔离，游戏操作保持原始异常和返回值。
    local result=table.pack(original(self,gid))
    probe(function()
      if not t or t~=active then return end
      t.sync_ms=elapsed(t.start)
      write(t,'sync',string.format('status=%s sync_ms=%s route_ms=%s hops=%s transits=%s',
        result[1]==false and 'cancelled' or 'dispatched',t.sync_ms,t.route_ms,t.hops,t.transits))
      if result[1]==false then active=nil end
    end)
    return table.unpack(result,1,result.n)
  end
  gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM,function()
    probe(function()
      local t=active
      if not t then return end
      if not context_ok(t) then write(t,'cancel','status=context_changed'); active=nil; return end
      if not t.arrival_ms and desc().ListIndex==t.target_lid then
        t.arrival_ms=elapsed(t.start)
      end
    end)
  end)
  gt:AddCallback(ModCallbacks.MC_POST_RENDER,function()
    probe(function()
      local t=active
      if not t then return end
      if not context_ok(t) then write(t,'cancel','status=context_changed'); active=nil; return end
      local current=now()
      t.max_gap=math.max(t.max_gap,current-t.last_render)
      t.last_render=current
      if t.arrival_ms and t.sync_ms and desc().ListIndex==t.target_lid then
        write(t,'finish',string.format(
          'status=arrived sync_ms=%s route_ms=%s hops=%s transits=%s arrival_ms=%s total_ms=%s max_render_gap_ms=%s',
          t.sync_ms,t.route_ms,t.hops,t.transits,t.arrival_ms,current-t.start,t.max_gap))
        active=nil
      elseif Game():GetFrameCount()-t.frame>1200 then
        write(t,'cancel','status=timeout'); active=nil
      end
    end)
  end)
  gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED,function() active=nil end)
  gt:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT,function() active=nil end)
end
