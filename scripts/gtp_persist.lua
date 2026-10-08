--[[
  GoodTripPlus - 门图状态的序列化（**纯函数，不碰任何游戏 API**）
  =================================================================

  为什么需要它：门图（「哪扇门现在能走」）是每进程一份、且 new_level() 每次触发就清空；
  而游戏**只对当前房间**回答门的状态（Room:GetDoor 属于 Game():GetRoom()）。
  其它房间只能读到 RoomConfigRoom.Doors —— 那是「哪几侧有门」的门位掩码，
  **不含「锁没锁 / 墙炸没炸」**。所以进程一重启，这份知识没有任何办法重新推导 → 只能存下来。

  本文件只负责「表 <-> 文本」这一层，**pure**（因此能进 tests/travel.lua 的 headless 测试）；
  读写存档、什么时候存，都在 gtrep 里。设计与取舍见
  docs/superpowers/specs/2026-10-06-door-graph-persistence-design.md

  格式（行式纯文本，首行版本串；解析不认识的行就跳过 —— 失败安全 + 向前兼容）：

      GTPDG2
      I <identity>
      D <dim> <a> <b> <slot>      -- slot 0 表示「另一端裸标记」（值为 true）
      S <dim> <a>
      O <sgi> <0|1>               -- 诅咒房门外的刺
      N <sgi> <0|1>               -- 诅咒房门内的刺
      P <sgi> <sgi>               -- 隐藏房 -> 前室
]]--

-- 版本串。改了格式就换它 —— 旧档会被整份忽略（代价只是重新探一次图）。
-- GTPDG1 可能已被换层回调把旧图写成新层身份，不能继续信任。
local MAGIC = "GTPDG2"
gt.PERSIST_MAGIC = MAGIC

-- state = { identity = string,
--           link = {[dim]={[a]={[b]=slot or true}}}, swept = {[dim]={[a]=true}},
--           bare_out = {[sgi]=bool}, bare_in = {[sgi]=bool}, pre = {[sgi]=sgi} }
-- 返回文本；state 里缺哪块就当空。
function gt.persist_serialize(state)
  if type(state) ~= "table" then return nil end
  local body = {}
  for key, value in pairs(state.sections or {}) do
    if type(key)=='string' and key:match('^%w+$') and type(value)=='string' then
      local hex=value:gsub('.',function(c) return string.format('%02x',string.byte(c)) end)
      body[#body+1]='E '..key..' '..hex
    end
  end
  for dim, row in pairs(state.link or {}) do
    for a, cols in pairs(row) do
      for b, v in pairs(cols) do
        -- true（裸标记）编码成 slot 0；其余是真实门槽（1..8）
        body[#body + 1] = string.format("D %d %d %d %d", dim, a, b, v == true and 0 or v)
      end
    end
  end
  for dim, row in pairs(state.swept or {}) do
    for a in pairs(row) do
      body[#body + 1] = string.format("S %d %d", dim, a)
    end
  end
  for sgi, v in pairs(state.bare_out or {}) do
    body[#body + 1] = string.format("O %d %d", sgi, v and 1 or 0)
  end
  for sgi, v in pairs(state.bare_in or {}) do
    body[#body + 1] = string.format("N %d %d", sgi, v and 1 or 0)
  end
  for sgi, v in pairs(state.pre or {}) do
    body[#body + 1] = string.format("P %d %d", sgi, v)
  end
  -- 排序只为输出稳定（可 diff），不影响语义；版本串与 identity 单独放前面，不参与排序
  table.sort(body)
  local head = { MAGIC, "I " .. tostring(state.identity or "") }
  for i = 1, #body do head[#head + 1] = body[i] end
  return table.concat(head, "\n")
end

-- 解析文本 -> state；任何不认识/不完整/版本不符的情况都返回 nil（**绝不报错**）。
function gt.persist_parse(text)
  if type(text) ~= "string" or text == "" then return nil end
  local state = { link = {}, swept = {}, bare_out = {}, bare_in = {}, pre = {}, sections = {} }
  local first = true
  for line in text:gmatch("[^\n]+") do
    if first then
      first = false
      if line ~= MAGIC then return nil end     -- 版本不符：整份忽略
    else
      local tag = line:sub(1, 1)
      if tag == "I" then
        state.identity = line:sub(3)
      elseif tag == 'E' then
        local key, hex=line:match('^E (%w+) (%x*)$')
        if key and #hex%2==0 then
          state.sections[key]=hex:gsub('%x%x',function(pair) return string.char(tonumber(pair,16)) end)
        end
      elseif tag == "D" then
        local dim, a, b, slot = line:match("^D (%d+) (%d+) (%d+) (%d+)$")
        if dim then
          dim, a, b, slot = tonumber(dim), tonumber(a), tonumber(b), tonumber(slot)
          state.link[dim] = state.link[dim] or {}
          state.link[dim][a] = state.link[dim][a] or {}
          state.link[dim][a][b] = (slot == 0) and true or slot
        end
      elseif tag == "S" then
        local dim, a = line:match("^S (%d+) (%d+)$")
        if dim then
          dim, a = tonumber(dim), tonumber(a)
          state.swept[dim] = state.swept[dim] or {}
          state.swept[dim][a] = true
        end
      elseif tag == "O" or tag == "N" then
        local sgi, v = line:match("^" .. tag .. " (%d+) (%d+)$")
        if sgi then
          local bucket = (tag == "O") and state.bare_out or state.bare_in
          bucket[tonumber(sgi)] = (tonumber(v) == 1)
        end
      elseif tag == "P" then
        local a, b = line:match("^P (%d+) (%d+)$")
        if a then state.pre[tonumber(a)] = tonumber(b) end
      end
      -- 其它行：跳过（向前兼容）
    end
  end
  if not state.identity or state.identity == "" then return nil end
  return state
end
