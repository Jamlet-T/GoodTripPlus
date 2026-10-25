-- 两端中转的游戏适配。首尾使用真实门；安全的中段远程桥接，其余逐门兜底。
-- 中转取证只在调试模式开启时写 [GTProute]；换房与返回值不受影响。
local Route=require('scripts.gtp_route')
return function(gt,cells)
  local function trace(message)
    if not (gt.is_debug and gt:is_debug()) then return end
    pcall(function() Isaac.DebugString('[GTProute] '..message) end)
  end
  -- 取消行**不受调试开关控制**：静默失败就是 2026-10-25 用户报的问题本体 —— 屏幕上一句话
  -- 都没有，日志里也只有开了调试才有一行。每次失败的行程只多写这一行，不会刷屏。
  local function trace_failure(message)
    pcall(function() Isaac.DebugString('[GTProute] '..message) end)
  end
  function gt:prepare_travel_route(route)
    if not route or #route==0 then return nil end
    local game=Game()
    local lvl=game:GetLevel()
    local identity,dimension,frame=gt:level_identity(),gt:get_current_dimension(),game:GetFrameCount()
    local first=gt:travel_cur_state()
    -- 任意房间档可从战斗房出发；没有正常步行前提时沿用直接传送，不新增准入禁令。
    if not gt:room_is_clear(first.cur) then return nil end
    -- completed 是已确认抵达的原路线前缀，用于取消时费用；transits 才是实际加载次数。
    local result={completed=0,transits=0}
    local held_maze=false
    local hops={}
    local function context_ok()
      local st=gt:travel_cur_state()
      return gt:level_identity()==identity and gt:get_current_dimension()==dimension
        and game:GetFrameCount()>=frame and st.player and st.player:Exists()
        and not st.player:IsDead() and st.cur and st.room,st
    end
    local function live_hop(hop)
      local valid,st=context_ok()
      local source=gt:grid_room_desc(hop.from)
      if not valid or not source or st.cur.ListIndex~=source.ListIndex
          or not gt:room_is_clear(st.cur) then error('context_changed') end
      local door=st.room:GetDoor(hop.slot)
      local rd=door and gt:room_desc_at(door.TargetRoomIndex)
      local target=gt:grid_room_desc(hop.to)
      if not door or not rd or not target or rd.ListIndex~=target.ListIndex
          or not gt:door_is_passage(door) then error('door_changed') end
    end
    gt._route_transit=true
    local ok,err=pcall(function()
      if #route>168 or not first.cur or route[1].from~=first.cur.SafeGridIndex then error('invalid_route') end
      for i,edge in ipairs(route) do
        if i>1 and edge.from~=route[i-1].to then error('broken_route') end
        hops[i]=Route.hop(edge,function(gid) return gt:grid_room_desc(gid) end,cells())
        -- 带上出问题的那一跳：只写 ambiguous_geometry 时看不出是哪条边、更看不出
        -- 目标是不是离网房（0 个候选和多个候选都会走到这里）。
        if not hops[i] then error(string.format('ambiguous_geometry hop=%s->%s slot=%s',
          tostring(edge.from),tostring(edge.to),tostring(edge.slot))) end
      end
      local last=hops[#hops]
      result.arrive,result.slot=last.cell,last.entry
      local current=lvl.GetCurrentRoomIndex and lvl:GetCurrentRoomIndex() or first.cur.SafeGridIndex
      local needs_transit=#hops>1 and Route.wall(current,last.cell)~=last.entry%4
      if needs_transit then
        if lvl:GetCurses() & LevelCurse.CURSE_OF_MAZE~=0 then
          lvl:RemoveCurses(LevelCurse.CURSE_OF_MAZE); held_maze=true
        end
        local i=1
        while i<#hops do
          local hop=hops[i]
          live_hop(hop)
          local bridge=i==2 and i<#hops-1 and Route.bridge_allowed(
            gt:grid_room_desc(hop.from),gt:grid_room_desc(last.from),cells())
          local reached=i
          if bridge then
            reached=#hops-1
            hop=hops[reached]
          end
          lvl.EnterDoor,lvl.LeaveDoor=-1,bridge and -1 or hop.slot
          trace(string.format('transit from=%s to=%s cell=%s leave=%s bridge=%s',
            gt:travel_cur_state().cur.SafeGridIndex,hop.to,hop.cell,lvl.LeaveDoor,tostring(not not bridge)))
          game:ChangeRoom(hop.cell,-1)
          local valid,st=context_ok()
          local target=gt:grid_room_desc(hop.to)
          if not valid or not target or st.cur.ListIndex~=target.ListIndex then error('unexpected_arrival') end
          result.completed=reached
          result.transits=result.transits+1
          i=reached+1
        end
      end
      result.leave=-1
      if result.completed==#hops-1 then
        live_hop(last)
        result.leave=last.slot
      end
    end)
    gt._route_transit=false
    if not ok then
      result.failed=true
      result.reason=tostring(err)
      local valid=context_ok()
      result.charge_partial=not not valid
      if gt:level_identity()==identity then
        lvl.EnterDoor,lvl.LeaveDoor=-1,-1
        if held_maze then lvl:AddCurse(LevelCurse.CURSE_OF_MAZE,false) end
      end
      trace_failure('cancel completed='..result.completed..' reason='..result.reason)
      return result
    end
    result.maze=held_maze
    trace(string.format('ready hops=%s transits=%s cell=%s entry=%s leave=%s',
      #hops,result.transits,result.arrive,result.slot,result.leave))
    return result
  end
end
