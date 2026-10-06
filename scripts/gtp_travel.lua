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

-- ===== 影子对照（临时：步 1c 删除）=====
-- _legacy = 2.2.3 判定逻辑的逐行转写（check_teleble 本体 + 两个包装，包装在外），
-- 唯一改动是「读 gtrep 文件级 local」改为读访问器。返回 (boolean, 理由标签)。
-- 只在调试模式打开时与新判定同时跑，结论不一致就写 log（按 gid+理由去重防刷屏）。
--
-- **预期差异有两类，都不计入 MISMATCH：**
--   ① 上移进判定层的那四条规则造成的（它们以前在执行层，是我们故意改的）；
--   ② 旧判定因**类型白名单**拒绝、而新判定放行 —— 白名单已按用户要求整体删除，
--      改由「那扇门现在能不能走」把关（gtrep 的 gt:door_is_passage）。
-- 目标：真机跑一局后零 MISMATCH。
local EXPECTED_DIFF = {
  ["departure.mothers_shadow"] = true,
  ["departure.mom_room"]       = true,
  ["target.challenge_gate"]    = true,
  ["path.walk_time"]           = true,
}
local EXPECTED_ALLOW = {
  unexplored_type_gate = true,
}

local shadow_seen = {}
gt.shadow_mismatch_count = 0

function gt:shadow_check(gid, res, old_ok, old_why)
  if res.ok == old_ok then return end
  local key = tostring(gid) .. "|" .. tostring(res.rule or "-") .. "|" ..
    tostring(old_why)
  local tag = "MISMATCH"
  if (not res.ok) and EXPECTED_DIFF[res.rule] then
    tag = "EXPECTED"
  elseif res.ok and EXPECTED_ALLOW[old_why] then
    tag = "EXPECTED"
  end
  if tag == "MISMATCH" then
    gt.shadow_mismatch_count = gt.shadow_mismatch_count + 1
  end
  if shadow_seen[key] then return end
  shadow_seen[key] = true
  Isaac.DebugString(string.format(
    "[GTPshadow] %s gid=%s new=%s old=%s(%s)", tag, tostring(gid),
    tostring(res.rule or "ok"), tostring(old_ok), tostring(old_why)))
end

-- 2.2.3 类型白名单的原样副本。生产代码已把它删了（见 gtrep 里那段说明），
-- 但 _legacy 要复现旧行为，所以自己带一份。**与 _legacy 一起在步 1c 删除。**
--
-- ⚠️ 镜像世界是 **Room** 的方法，不是 Level 的（原实现用的是 gtrep 的 `room` local）。
-- 2026-10-06 实测踩过：这里若写成 lvl:IsMirrorWorld() 会 nil 调用抛错，而影子抛错会把
-- 整条 MC_POST_RENDER 链带崩（光标与地图边界一起消失、未探索目标一律传不进去）。
local function _legacy_type_gate(rd, lvl, rm)
  if rd.VisitedCount > 0 and rd.Clear then return true end
  if rd.Flags & RoomDescriptor.FLAG_RED_ROOM ~= 0 then return true end
  if gt:is_secret_room(rd) then return true end
  local t = rd.Data.Type
  if t == 10 and not gt:block_curse_room() then return true end
  if t == 1 or t == 5 or t == 6 or t == 13 then return true end
  if lvl and rm and (((lvl:GetStage() == 1
          and lvl:GetStageType() < StageType.STAGETYPE_REPENTANCE)
        or rm:IsMirrorWorld())
      and ((not Game():IsGreedMode() and t == 4) or t == 2)) then
    return true
  end
  return false
end

-- 2.2.3 判定的逐行转写。每条都能在 git 的 gtrep.lua:543-598（check_teleble）
-- 与 gtp_curseblock / gtp_bosswindow 的包装段里找到原句。
local function _legacy(gid)
  local st = gt:travel_cur_state()
  local cur, level, rm = st.cur, st.level, st.room

  -- 包装层（原加载顺序：gtp_curseblock 在最外、gtp_bosswindow 在里；两者都拦任何 gid）
  if gt:block_curse_room() and type(gid) == "number" and gid >= 0 and gid <= 168 then
    local rd = gt:room_desc_at(gid)
    if rd and rd.Data and rd.Data.Type == RoomType.ROOM_CURSE then
      return false, "curse_block"
    end
  end
  if level and not level:IsAscent() and gt.has_reward_door and gt:has_reward_door() then
    return false, "reward_door"
  end

  -- 本体
  if gid == -99 then return false, "no_target" end
  if (not gt:curse_map_visible()
      and (level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST) ~= 0) then
    return false, "lost_curse"
  end
  if gt:start_room_lock() then return false, "item_entrance" end
  local cid = cur.SafeGridIndex
  if gt:grid_room_desc(cid) == nil or not cur.Clear then
    return false, "cur_uncleared"
  end
  if (cur.Data.Type == 6 or cur.Data.Type == 11) and not gt:check_room_open() then
    return false, "cur_door_closed"
  end
  if gid == false then return true, "ok" end
  -- 读的就是 grid_room，不是 GetRoomByIdx
  if gt:grid_room_desc(gid) == nil then return false, "unknown_cell" end
  local trd = gt:grid_room_desc(gid)
  if trd.ListIndex == cur.ListIndex then return false, "same_room" end
  local travel_mode = gt:get_travel_mode()
  if travel_mode == 1 then return true, "mode1" end
  local reach = gt:get_config_bool("FairTripPath", true) and gt:get_reachable_rooms() or nil
  if trd.VisitedCount > 0 and trd.Clear
      and (not reach or reach[trd.SafeGridIndex] == true) then
    return true, "channel_b"
  end
  if travel_mode == 3 then return false, "mode3" end
  -- 旧实现的 check_neigh_connected 里含类型白名单，生产代码已删 → 这里自己判一次
  if (trd.DisplayFlags & 1) ~= 0 and not _legacy_type_gate(trd, level, rm) then
    return false, "unexplored_type_gate"
  end
  if gt:check_neigh_connected(trd, function(rd)
      return (rd.DisplayFlags & 1 ~= 0) and rd.VisitedCount > 0 and rd.Clear
        and (not reach or (reach[rd.SafeGridIndex]
          and gt:rooms_linked(rd.SafeGridIndex, trd.SafeGridIndex)))
    end) then
    return true, "channel_c"
  end
  return false, "channel_c_failed"
end

-- 影子绝不允许把游戏带崩 —— 它只是临时验证代码，而它在 can_travel_to 里**同步**跑，
-- 一抛错就会把整条 MC_POST_RENDER 链带崩（2026-10-06 实测：_legacy 里一次 nil 调用
-- 让光标与地图边界一起消失、未探索的目标一律传不进去）。
-- 所以这里一律 pcall；抛错一次就**永久停用影子**并写 log（宁可少一层验证，
-- 也不能让验证代码弄坏玩家体验）。
local shadow_broken = false
local function legacy_safe(gid)
  if shadow_broken then return nil, nil end
  local ok, res_ok, res_why = pcall(_legacy, gid)
  if not ok then
    shadow_broken = true
    Isaac.DebugString("[GTPshadow] _legacy 抛错，影子对照已停用（传送不受影响）：" ..
      tostring(res_ok))
    return nil, nil
  end
  return res_ok, res_why
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
  local res = gt:run_travel_stages({ "departure" }, gt:travel_ctx(nil))
  if gt:is_debug() then
    local old_ok, old_why = legacy_safe(false)
    if old_ok ~= nil then gt:shadow_check(false, res, old_ok, old_why) end
  end
  return res
end

-- 传送到某格：跑全部四段。① 必须重跑 —— 否则直接调它会漏掉当前房那一侧。
function gt:can_travel_to(gid)
  local res = gt:run_travel_stages(gt.travel_stages, gt:travel_ctx(gid))
  if gt:is_debug() then
    local old_ok, old_why = legacy_safe(gid)
    if old_ok ~= nil then gt:shadow_check(gid, res, old_ok, old_why) end
  end
  return res
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
    local hp = p:GetHearts() + p:GetSoulHearts() + p:GetBlackHearts()
    local st = ctx.level:GetStage()
    if st % 2 == 0 and st ~= 10 then
      if hp > 2 then return nil end
      return { stage = st, hp = hp, need = ">2" }
    end
    local maxhp = p:GetMaxHearts()
    if hp >= maxhp then return nil end
    return { stage = st, hp = hp, need = ">=" .. tostring(maxhp) }
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
  if gt.shadow_mismatch_count and gt.shadow_mismatch_count > 0 then
    draw("[GTPshadow] MISMATCH x" .. tostring(gt.shadow_mismatch_count),
      KColor(1, 1, 0.3, 1))
  end
end
