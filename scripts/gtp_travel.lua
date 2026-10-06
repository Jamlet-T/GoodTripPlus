--[[
  GoodTripPlus - 传送判定（策略层）
  =================================

  判定链的唯一真相：四段流水线，每段一张有序规则表。

      departure    -- 现在能不能走：只看当前房与玩家，与目标无关  -> can_open_cursor
      target_entry -- 目标能不能进：与档位无关
      range        -- 是否在允许范围内：按「可以传送到」的档位
      path         -- 路线与代价

  呼出光标 = 只跑 departure；房间高亮 = 跑全部；松手传送 = 跑全部。
  三者共用这一套判定，所以不会再出现「光标高亮着、松手却只响失败音」。

  规则形状：  { id, stage, text, test = function(ctx) ... end }
      test 返回 nil = 通过
      test 返回 表  = 拒绝，表里是补充细节（detail）
      ⚠️ 规则体两个分支都必须显式 return，不要靠 fall-through ——
         「忘了写 return」会静默变成放行，这类 bug 最难查。

  设计文档：docs/superpowers/specs/2026-10-06-travel-judgment-refactor-design.md
  实现计划：docs/superpowers/plans/2026-10-06-travel-judgment-refactor-step1a.md

  ⚠️ 本文件**绝不直接读** gtrep 的文件级 local（crd / crid / stage / room / level /
     player / grid_room / room_neighbours）—— 它们会被 get_grid_room() / new_room()
     整体重新赋值，捕获引用会拿到过时的那一层。一律走 gt: 访问器。
]]--

-- ===== 规则表 =====
-- 顺序即判定顺序；段间按此顺序，段内按登记顺序。
local STAGE_ORDER = { "departure", "target_entry", "range", "path" }
gt.travel_stages = STAGE_ORDER
gt.travel_rules = { departure = {}, target_entry = {}, range = {}, path = {} }

-- 登记一条规则。stage 未知就响亮报错并拒绝 —— 宁可少一条规则，
-- 也不要把规则静默塞进错的段（塞错段 = 它不再参与「能否呼出光标」的判断）。
--
-- 段内位置由规则自己带的 `order` 决定，**不是**登记顺序：这样加载顺序
--（main.lua 的 require 顺序）与文件内的书写顺序都不再影响判定顺序 ——
-- 这正是原实现「顺序由 require 顺序隐式决定」那个毛病的根治。
-- 省略 order 的规则排在所有带 order 的规则之后，并按登记顺序。
-- 理由：顺序会影响**报出的理由**（先命中的规则先说话），所以它必须是显式的。
function gt:add_travel_rule(rule)
  local bucket = gt.travel_rules[rule and rule.stage]
  if not bucket then
    Isaac.DebugString("[GoodTripPlus][travel] 未知 stage，规则未登记: " ..
      tostring(rule and rule.stage) .. " (id=" .. tostring(rule and rule.id) .. ")")
    return false
  end
  local order = rule.order or 1000
  local pos = #bucket + 1
  for i = 1, #bucket do
    if (bucket[i].order or 1000) > order then
      pos = i
      break
    end
  end
  table.insert(bucket, pos, rule)
  return true
end

-- 纯引擎：逐段逐条跑，命中即返回。不碰任何游戏 API，所以能 headless 测
-- （见 tools/test-travel.lua）。
function gt:run_travel_stages(stage_names, ctx)
  for _, sname in ipairs(stage_names) do
    local bucket = gt.travel_rules[sname]
    for i = 1, #bucket do
      local rule = bucket[i]
      local detail = rule.test(ctx)
      if detail then
        return { ok = false, stage = rule.stage, rule = rule.id,
                 text = rule.text, detail = detail }
      end
    end
  end
  return { ok = true }
end

-- ===== 判定上下文 =====
-- 每次调用新建一张小表；字段固定，不缓存、不跨帧复用（与仓库既有风格一致：
-- get_reachable_rooms() 每次调用本来就建两张表）。
-- reachable 是惰性闭包：只有真正走到 ③ 才跑可达岛 BFS；FairTripPath 关时恒返回 nil
-- （与旧实现里 `reach = FairTripPath and get_reachable_rooms() or nil` 同义）。
-- 刻意不放 stage 字段：target.challenge_gate 用 ctx.level:GetStage() 取，
-- 免得多个可能与 ctx.level 不同步的字段。
function gt:travel_ctx(gid)
  local st = gt:travel_cur_state()
  local ctx = {
    gid = gid,
    cur = st.cur,
    cur_gid = st.cur_gid,
    level = st.level,
    room = st.room,
    player = st.player,
    target = nil,
    mode = gt:get_travel_mode(),
    fair_path = gt:get_config_bool("FairTripPath", true),
    fair_time = gt:get_config_bool("FairTripTime", false),
  }
  if type(gid) == "number" and gid >= 0 and gid <= 168 then
    ctx.target = gt:grid_room_desc(gid)
  end
  local reach_cache = nil
  ctx.reachable = function()
    if not ctx.fair_path then return nil end
    if reach_cache == nil then
      reach_cache = gt:get_reachable_rooms()
    end
    return reach_cache
  end
  return ctx
end

-- ===== 两个入口 =====

-- 呼出光标：只跑 ①。它必须能在没有目标时回答 —— 所以 ① 段规则不得访问
-- ctx.gid / ctx.target。这条不变量正是「能否呼出光标」的定义。
function gt:can_open_cursor()
  return gt:run_travel_stages({ "departure" }, gt:travel_ctx(nil))
end

-- 传送到某格：跑全部四段。① 必须重跑 —— 否则直接调它会漏掉当前房那一侧。
function gt:can_travel_to(gid)
  return gt:run_travel_stages(gt.travel_stages, gt:travel_ctx(gid))
end

-- ===== ① departure：只看当前房与玩家 =====
-- ⚠️ 本段的规则不得访问 ctx.gid / ctx.target。

gt:add_travel_rule({
  id = "departure.lost_curse", stage = "departure", order = 10,
  text = "迷失诅咒下地图不可见（跟随 MinimapAPI 的 Display During Curse）",
  test = function(ctx)
    if gt:curse_map_visible() then return nil end
    if (ctx.level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST) == 0 then return nil end
    return {}
  end,
})

gt:add_travel_rule({
  id = "departure.item_entrance", stage = "departure", order = 20,
  text = "牌意解读 / 天堂阶梯的入口还在这个房间（离开就没了，别顶掉它）",
  test = function(ctx)
    if not gt:start_room_lock() then return nil end
    return {}
  end,
})

gt:add_travel_rule({
  id = "departure.cur_uncleared", stage = "departure", order = 30,
  text = "当前房间还没清怪",
  test = function(ctx)
    if gt:grid_room_desc(ctx.cur_gid) ~= nil and ctx.cur.Clear then return nil end
    return { cur_gid = ctx.cur_gid, clear = ctx.cur.Clear }
  end,
})

gt:add_travel_rule({
  id = "departure.cur_door_closed", stage = "departure", order = 40,
  text = "当前是 miniboss / 挑战房，门还关着",
  test = function(ctx)
    local t = ctx.cur.Data and ctx.cur.Data.Type
    if t ~= 6 and t ~= 11 then return nil end
    if gt:check_room_open() then return nil end
    return { cur_type = t }
  end,
})

gt:add_travel_rule({
  id = "departure.mothers_shadow", stage = "departure", order = 50,
  text = "Mother's Shadow 还在这个房间里（会打断它的流程）",
  test = function(ctx)
    for _, en in pairs(Isaac.GetRoomEntities()) do
      if en.Type == EntityType.ENTITY_MOTHERS_SHADOW then
        return { entity = en.Type }
      end
    end
    return nil
  end,
})

gt:add_travel_rule({
  id = "departure.mom_room", stage = "departure", order = 60,
  text = "Mom / Ultra Greed 房（防打断清怪后的后续流程；回溯线除外）",
  test = function(ctx)
    if ctx.level:IsAscent() then return nil end
    local name = ctx.cur.Data and ctx.cur.Data.Name
    if name ~= "Mom" and name ~= "Ultra Greed" then return nil end
    return { room_name = name }
  end,
})

-- ===== ② target_entry：与档位无关 =====

gt:add_travel_rule({
  id = "target.no_target", stage = "target_entry", order = 10,
  text = "光标没落在任何已显示的房间上",
  test = function(ctx)
    local g = ctx.gid
    if type(g) == "number" and g >= 0 and g <= 168 then return nil end
    return { gid = tostring(g) }
  end,
})

gt:add_travel_rule({
  id = "target.unknown_cell", stage = "target_entry", order = 20,
  text = "这个格子不在本层的房间表里",
  test = function(ctx)
    if ctx.target ~= nil then return nil end
    return { gid = ctx.gid }
  end,
})

gt:add_travel_rule({
  id = "target.same_room", stage = "target_entry", order = 30,
  text = "目标就是当前房间",
  test = function(ctx)
    if ctx.target.ListIndex ~= ctx.cur.ListIndex then return nil end
    return { list_index = ctx.target.ListIndex }
  end,
})

gt:add_travel_rule({
  id = "target.challenge_gate", stage = "target_entry", order = 60,
  text = "目标是还没完成的挑战房，当前血量不满足进入条件",
  test = function(ctx)
    if ctx.target.Data.Type ~= 11 or ctx.target.ChallengeDone then return nil end
    local p = ctx.player
    -- hp 三项相加、全部按**半心**计（原 Fixed 逻辑）
    local hearts = p:GetHearts()
    local soul = p:GetSoulHearts()
    local black = p:GetBlackHearts()
    local hp = hearts + soul + black
    local st = ctx.level:GetStage()
    if st % 2 == 0 and st ~= 10 then
      -- 偶数层：原实现是「hp > 2 就拒绝」⇒ 放行要求 hp <= 2（即 ≤1 心）。
      -- ⚠️ 2026-10-06 实测事故：这里曾被写成「hp > 2 就放行」，恰好反了 ——
      -- 结果是「符合开启条件的红色挑战房传不进去」。tools/test-travel.lua 第 9 段
      -- 有断言锁死这两支的方向（影子对照照不到，原因见那里的注释）。
      if hp <= 2 then return nil end
      return { stage = st, hp = hp, hearts = hearts, soul = soul,
               black = black, need = "<=2" }
    end
    -- 其余（奇数层与 stage 10）：原实现是「hp < GetMaxHearts() 就拒绝」⇒ 放行要求满血
    local maxhp = p:GetMaxHearts()
    if hp >= maxhp then return nil end
    return { stage = st, hp = hp, hearts = hearts, soul = soul,
             black = black, need = ">=" .. tostring(maxhp) }
  end,
})

-- ===== ③ range：按「可以传送到」的档位 =====

gt:add_travel_rule({
  id = "range.within_scope", stage = "range", order = 10,
  text = "超出「可以传送到」的范围",
  test = function(ctx)
    -- 任意房间档：gid 来自光标投影，必然已显示，直接放行
    if ctx.mode == 1 then return nil end
    local reach = ctx.reachable()
    local t = ctx.target
    -- 通道 B：目标自己已探索已清怪，且在自己这块可达岛上
    if t.VisitedCount > 0 and t.Clear
        and (reach == nil or reach[t.SafeGridIndex] == true) then
      return nil
    end
    if ctx.mode == 3 then
      return { branch = "mode3" }
    end
    -- 通道 C：目标旁边有「已显示 + 已探索 + 已清」的房，且两者之间有真门
    local near = gt:check_neigh_connected(t, function(rd)
      if (rd.DisplayFlags & 1) == 0 then return false end
      if not (rd.VisitedCount > 0 and rd.Clear) then return false end
      if reach == nil then return true end
      return reach[rd.SafeGridIndex] == true
        and gt:rooms_linked(rd.SafeGridIndex, t.SafeGridIndex)
    end)
    if near then return nil end
    return { branch = "channel_c", mode = ctx.mode }
  end,
})

-- ===== ④ path：路线与代价 =====

gt:add_travel_rule({
  id = "path.walk_time", stage = "path", order = 10,
  text = "「按距离增加游戏时间」开着，但找不到可步行的路线",
  test = function(ctx)
    if not ctx.fair_time then return nil end
    local dist = gt:fair_trip(ctx.cur_gid, ctx.gid)
    if dist ~= 999 then return nil end
    return { dist = dist }
  end,
})

-- ===== 诊断 =====

-- 规则全表：一眼看全「一共几条、什么顺序」
function gt:travel_rules_dump()
  local L = { "travelRules:" }
  for _, sname in ipairs(gt.travel_stages) do
    local ids = {}
    for _, rule in ipairs(gt.travel_rules[sname]) do
      ids[#ids + 1] = rule.id
    end
    L[#L + 1] = "  " .. sname .. " (" .. #ids .. "): " .. table.concat(ids, ", ")
  end
  return table.concat(L, "\n")
end

-- 逐段逐条跑一遍并打印结果（体现短路：被拒之后的段标 skipped）。
-- ⚠️ 会真跑一遍规则（含可达岛 BFS），只在诊断路径上调，别放进每帧渲染。
--
-- `ascii` = true 时**只用 ASCII**：屏幕浮层必须用这个模式 —— 诊断字体是
-- font/terminus.fnt（**位图 ASCII 字体，画不出中文**），中文在屏幕上会整段空白
-- （2026-10-06 实测：屏幕上只剩 "[拒绝 gid=35]" 里的 ASCII 部分，理由那截是空的）。
-- 所以 ascii 模式印**规则 id**而不是中文散文；中文散文留在 log.txt / 控制台里。
-- 第二个返回值 = 是否可传送（浮层要靠它决定画不画）。
function gt:travel_verdict_dump(gid, ascii)
  local ctx = gt:travel_ctx(gid)
  local L = { string.format("travelDiag: target gid=%s mode=%d fairPath=%s fairTime=%s",
    tostring(gid), ctx.mode, tostring(ctx.fair_path), tostring(ctx.fair_time)) }
  local stopped, verdict = false, nil
  for _, sname in ipairs(gt.travel_stages) do
    if stopped then
      L[#L + 1] = "  [" .. sname .. "] skipped (short-circuited)"
    else
      local bucket = gt.travel_rules[sname]
      local hit_rule, hit_detail = nil, nil
      for i = 1, #bucket do
        local detail = bucket[i].test(ctx)
        if detail then
          hit_rule, hit_detail = bucket[i], detail
          break
        end
      end
      if hit_rule then
        local bits = {}
        for k, v in pairs(hit_detail) do
          bits[#bits + 1] = tostring(k) .. "=" .. tostring(v)
        end
        table.sort(bits)
        L[#L + 1] = string.format("  [%s] REJECT %s  %s  {%s}",
          sname, hit_rule.id, ascii and "" or hit_rule.text,
          table.concat(bits, " "))
        stopped = true
        verdict = hit_rule.id
      else
        L[#L + 1] = string.format("  [%s] %d rules -> all passed", sname, #bucket)
      end
    end
  end
  L[#L + 1] = verdict and ("  verdict: NOT teleportable (" .. verdict .. ")")
    or "  verdict: teleportable"
  return table.concat(L, "\n"), (verdict == nil)
end

-- ===== 免按键取证（调试模式）=====
-- 光标停在一个**会被拒**的房间上时，自动把整段判定过程 + 当前房间的门表写进 log.txt。
-- 为什么要这个：2026-10-06 反复踩到「用户报问题 → 我请用户按 F4/截图 → 用户没按/截不全
-- → 白跑一轮」。光标扫过去就落盘，把取证负担从用户挪回代码。
-- 按 (gid, 规则) 去重、每层清空，不会刷屏。
local travel_reject_logged = {}

function gt:travel_reset_reject_log()
  travel_reject_logged = {}
end

-- 当前房间每扇门的一行摘要（变体 / 开着没 / 算不算通路 / 通向哪）
-- —— 「上锁的门算不算通路」那条规则只能靠这个字段核对。
function gt:travel_doors_dump()
  local room = Game():GetRoom()
  if not room then return "  doors: no room" end
  local L = {}
  for i = 0, 7 do
    local door = room:GetDoor(i)
    if door then
      local open = "-"
      pcall(function() open = tostring(door:IsOpen()) end)
      L[#L + 1] = string.format(
        "  door slot=%d variant=%s isOpen=%s passage=%s targetIdx=%s targetType=%s",
        i, tostring(door.Desc and door.Desc.Variant), open,
        tostring(gt:door_is_passage(door)),
        tostring(door.TargetRoomIndex), tostring(door.TargetRoomType))
    end
  end
  return #L > 0 and table.concat(L, "\n") or "  doors: none"
end

function gt:auto_log_travel_reject(gid, res)
  if not gt:is_debug() or res.ok then return end
  local key = tostring(gid) .. "|" .. tostring(res.rule)
  if travel_reject_logged[key] then return end
  travel_reject_logged[key] = true
  local text = gt:travel_verdict_dump(gid, true)
  Isaac.DebugString("[GTPtrip] rejected target (auto, no keypress needed)\n" ..
    text .. "\n" .. gt:travel_doors_dump())
end

-- ===== 屏幕理由浮层（仅调试模式）=====
-- 调试模式打开、且正按住地图键时，光标停在会被拒的房间上就把**整条判定过程**
-- 画在屏幕左上角（逐段逐条 + 短路 + 规则 id + detail）；通过时不画。
-- 正常游玩完全不出（仍只有失败音）。
--
-- 为什么一次印一整段而不是一句话：2026-10-06 实测教训 —— 原来只印一句中文理由，
-- 而诊断字体画不出中文，用户屏幕上只剩 "gid=35"，什么也判断不了。
-- 印成 ASCII 的整段判定，一张截图就能定位到规则与它的入参。
-- 为什么不复用 gt:show_diag_overlay：那个是给一次性 dump 用的帧数生存期浮层，
-- 这里是「跟着光标实时变、松手即消失」。
function gt:render_travel_reason(cursor_pos, cursor_active)
  if not gt:is_debug() or not cursor_active then return end
  local font = gt:get_diag_font()
  if not font then return end
  local y = 20
  local function draw(s, color)
    font:DrawString(s, 16, y, color, 0, false)
    y = y + 11
  end
  local gid = gt:get_pos_grid_index(cursor_pos)
  if gid == -99 then
    draw("[BLOCKED] cursor is not on any displayed room cell", KColor(1, 0.45, 0.35, 1))
  else
    -- ascii = true：诊断字体是位图 ASCII 字体，中文会整段空白
    local text, ok = gt:travel_verdict_dump(gid, true)
    if not ok then
      for line in text:gmatch("[^\n]+") do
        draw(line, KColor(1, 0.45, 0.35, 1))
      end
    end
  end
end
