-- 地图知识的纯文本编解码与应用；不访问游戏全局或实体。
local M={}
local function hex(s) return s:gsub('.',function(c) return string.format('%02x',c:byte()) end) end
local function unhex(s)
  if #s%2~=0 or s:find('[^%x]') then return nil end
  return s:gsub('%x%x',function(c) return string.char(tonumber(c,16)) end)
end
function M.icons_capture(levels)
  local lines={}
  for dim,rooms in pairs(levels or {}) do
    for _,room in ipairs(rooms) do
      local d=room.Descriptor
      if d and d.ListIndex~=nil then
        local prefix=string.format('%d %d %d',dim,d.ListIndex,d.SafeGridIndex or -999)
        lines[#lines+1]='R '..prefix..' '..tostring(room.DisplayFlags or d.DisplayFlags or 0)
        for _,icon in ipairs(room.ItemIcons or {}) do
          if type(icon)=='string' or type(icon)=='number' then
            lines[#lines+1]='K '..prefix..' '..(type(icon)=='number' and 'n' or 's')..hex(tostring(icon))
          end
        end
      end
    end
  end
  -- K 行顺序影响图标顺序，不能逐行排序；每个房间单独有序，Levels 的迭代顺序稳定。
  return table.concat(lines,'\n')
end
function M.icons_restore(text,levels,current_lid,current_dim)
  local saved={}
  for line in (text or ''):gmatch('[^\n]+') do
    local tag,dim,lid,gid,tail=line:match('^(%u) (%d+) (%d+) (%-?%d+) (.*)$')
    if tag then
      dim,lid,gid=tonumber(dim),tonumber(lid),tonumber(gid)
      saved[dim]=saved[dim] or {}; saved[dim][lid]=saved[dim][lid] or {gid=gid,icons={}}
      local row=saved[dim][lid]
      if tag=='R' then
        local value=tonumber(tail)
        if value and value>=0 and value<=2147483647 and value==math.floor(value) then row.flags=value end
      elseif tag=='K' then
        local value=unhex(tail:sub(2))
        if tail:sub(1,1)=='n' then value=value and tonumber(value) end
        if value~=nil and (tail:sub(1,1)=='n' or tail:sub(1,1)=='s') then row.icons[#row.icons+1]=value end
      end
    end
  end
  local restored=0
  for dim,rooms in pairs(levels or {}) do
    for _,room in ipairs(rooms) do
      local d=room.Descriptor
      local row=d and saved[dim] and saved[dim][d.ListIndex]
      if row and (d.SafeGridIndex==nil or row.gid==d.SafeGridIndex) then
        if row.flags then room.DisplayFlags=(room.DisplayFlags or 0)|row.flags end
        if (d.VisitedCount or 0)>0 and not(dim==current_dim and d.ListIndex==current_lid)
          and #(room.ItemIcons or {})==0 and #row.icons>0 then
          room.ItemIcons=row.icons; restored=restored+1
        end
      end
    end
  end
  return restored
end
function M.delver_capture(map)
  local lines={}
  for cid in pairs(map.fake_baseline or {}) do
    if not map.candidates[cid] then lines[#lines+1]='X '..cid end
  end
  for cid,candidate in pairs(map.candidates or {}) do
    for _,entry in ipairs(candidate.entries or {}) do
      if entry.checked then lines[#lines+1]=string.format('C %d %d %d',cid,entry.source_lid,entry.doorslot) end
    end
  end
  table.sort(lines)
  return table.concat(lines,'\n')
end
function M.delver_restore(text,map)
  local removed=0
  for line in (text or ''):gmatch('[^\n]+') do
    local cid=line:match('^X (%d+)$')
    if cid then
      cid=tonumber(cid)
      if map.candidates[cid] and map.candidates[cid].lid==nil then
        map.candidates[cid]=nil; removed=removed+1
      end
    else
      local c,l,s=line:match('^C (%d+) (%d+) (%d+)$')
      local candidate=c and map.candidates[tonumber(c)]
      if candidate then for _,entry in ipairs(candidate.entries or {}) do
        if entry.source_lid==tonumber(l) and entry.doorslot==tonumber(s) then entry.checked=true end
      end end
    end
  end
  return removed
end
return M
