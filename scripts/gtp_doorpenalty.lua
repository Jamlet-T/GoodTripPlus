-- 过门惩罚的纯策略：证据 -> 单次穿越费用 -> 最少惩罚路线。游戏 API 在 runtime 适配层。
local M = {}

-- 优先使用门本身的外观/数据与两侧类型；房间类型仅补字段缺失。
-- VarData=1 的 Flat File 去刺口径沿用 MinimapAPI nicejourney.lua；其它非零值不猜。
-- 外观名称用于辨别实际洞口，不能因红隐/隐藏房的类型直接免掉一扇已确认刺门。
function M.describe(door, owner_type, target_type, slot)
  local sprite = ''
  if door.GetSprite then
    local ok,value=pcall(function() return door:GetSprite():GetFilename() end)
    if ok and type(value)=='string' then sprite=value:lower() end
  end
  local ct=door.CurrentRoomType or owner_type
  local tt=door.TargetRoomType or target_type
  local vd=door.VarData
  local variant=door.Desc and door.Desc.Variant
  if door.GetSaveState then
    local state=door:GetSaveState()
    if state and type(state.VarData)=='number' then vd=state.VarData end
  end
  if door.GetVariant then variant=door:GetVariant() end
  -- 名称来自游戏 tools/ResourceExtractor/filelist.txt，不用模糊的 secret 子串猜门型。
  local filename=sprite:match('[^/\\]+$') or sprite
  local kind
  if filename=='door_08_holeinwall.anm2' or filename=='door_08_holeinwall _darkroom.anm2' then kind='hole'
  elseif filename=='door_04_selfsacrificeroomdoor.anm2' then kind='curse'
  elseif ct==10 or tt==10 then kind='curse'
  else kind='ordinary' end
  local spikes
  if kind~='curse' then spikes=false
  elseif vd==1 then spikes=false
  elseif vd==0 then spikes=true end
  return {slot=slot,variant=variant or -1,var_data=type(vd)=='number' and vd or -1,
    current_type=ct or -1,target_type=tt or -1,spikes=spikes,kind=kind,sprite=sprite,
    open=door:IsOpen()==true,locked=door.IsLocked and door:IsLocked()==true or false}
end

function M.penalties(edge, actor)
  if edge.spikes~=true then return {} end -- 未知不冒充已确认带刺；runtime 负责补充/取证。
  if edge.target_type==10 and edge.current_type~=10 and actor.flying then return {} end
  return {{kind='curse_damage',amount=1,edge=edge}}
end

-- neighbors 返回有向门边（含具体门槽），descriptor 只控制中间房探索/清怪。
-- Dijkstra 按（惩罚次数、房间跳数）排序；无惩罚的长路优先于有惩罚的短路。
-- 只有目标作为最优节点出队才结束，不能首次发现目标就停止。
function M.route(from,to,neighbors,descriptor,cost)
  if from==to then return {} end
  local dist,fees,parent={[from]=0},{[from]=0},{}
  local settled={}
  while true do
    local a
    for node in pairs(dist) do
      if not settled[node] and (a==nil or fees[node]<fees[a]
          or (fees[node]==fees[a] and dist[node]<dist[a])) then a=node end
    end
    if a==nil then return nil end
    if a==to then
      local result,cur={},to
      while cur~=from do
        local p=parent[cur]; table.insert(result,1,p.edge); cur=p.from
      end
      return result
    end
    settled[a]=true
    for _,edge in ipairs(neighbors(a)) do
      local b=edge.to
      local rd=descriptor(b)
      if not settled[b] and rd and (b==to or (rd.VisitedCount>0 and rd.Clear)) then
        local nd,nf=dist[a]+1,fees[a]+cost(edge)
        if dist[b]==nil or nf<fees[b] or (nf==fees[b] and nd<dist[b]) then
          dist[b],fees[b],parent[b]=nd,nf,{from=a,edge=edge}
        end
      end
    end
  end
end

-- 通用执行队列：以后钥匙/硬币等费用通过 handlers 注册；一帧至多执行一项。
function M.executor(handlers)
  local self={queue={},head=1,last_frame=nil,started=false}
  function self:clear() self.queue={}; self.head=1; self.last_frame=nil; self.started=false end
  function self:pending() return self.queue[self.head]~=nil end
  function self:add(events)
    for _,event in ipairs(events) do self.queue[#self.queue+1]=event end
  end
  function self:step(frame,ready)
    if self.last_frame==frame or not self:pending() then return end
    local event=self.queue[self.head]
    if self.started and not ready(event) then return end
    self.last_frame=frame; self.started=true
    self.head=self.head+1 -- 不重试被护盾/无敌拒绝的伤害。
    assert(handlers[event.kind],'unknown door penalty: '..tostring(event.kind))(event)
    if not self:pending() then self:clear(); self.last_frame=frame end
  end
  return self
end
return M
