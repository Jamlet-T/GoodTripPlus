-- 精确门槽几何。只读取描述符及占格，不访问游戏 API。
local M={}
local steps={[0]=-1,[1]=-13,[2]=1,[3]=13}
function M.wall(from,to)
  local dx,dy=from%13-to%13,from//13-to//13
  if math.abs(dx)>math.abs(dy) then return dx>0 and 2 or 0 end
  return dy<=0 and 1 or 3
end
local function slot_at(rd,cell,wall)
  local offset=wall%2==0 and cell//13-rd.GridIndex//13 or cell%13-rd.GridIndex%13
  if offset<0 or offset>1 then return nil end
  return wall+4*offset
end
function M.hop(edge,descriptor,cells)
  local src,dst=descriptor(edge.from),descriptor(edge.to)
  if not src or not dst then return nil end
  local candidates={}
  for wall=0,3 do
    for secondary=0,1 do
      local slot=wall+secondary*4
      if edge.slot==nil or edge.slot<0 or edge.slot==slot then
        local chosen
        for cell,rd in pairs(cells) do
          if rd.ListIndex==src.ListIndex and slot_at(src,cell,wall)==slot then
            if not chosen or ((wall==0 or wall==1) and cell<chosen)
                or ((wall==2 or wall==3) and cell>chosen) then chosen=cell end
          end
        end
        if chosen then
          local cell=chosen+steps[wall]
          local same_row=wall%2==1 or chosen//13==cell//13
          local nextroom=cells[cell]
          if same_row and nextroom and nextroom.ListIndex==dst.ListIndex then
            local entry=slot_at(dst,cell,(wall+2)%4)
            if entry then candidates[#candidates+1]={from=edge.from,to=edge.to,
              cell=cell,slot=slot,entry=entry} end
          end
        end
      end
    end
  end
  if #candidates==1 then return candidates[1] end
end
return M
