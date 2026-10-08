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
-- 段间按此顺序；段内按 order，相同 order 保持登记顺序。
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
-- （见 tests/travel.lua）。
-- 任意档只保留目标有效性检查；其他档继续执行完整规则。
function gt:travel_rule_enabled(rule, ctx)
  if ctx.mode ~= 1 then return true end
  return rule.id == "target.no_target" or rule.id == "target.unknown_cell"
    or rule.id == "target.same_room"
end

function gt:run_travel_stages(stage_names, ctx)
  for _, sname in ipairs(stage_names) do
    local bucket = gt.travel_rules[sname]
    for i = 1, #bucket do
      local rule = bucket[i]
      local detail = gt:travel_rule_enabled(rule, ctx) and rule.test(ctx) or nil
      if detail then
        return { ok = false, stage = rule.stage, rule = rule.id,
                 text = rule.text, detail = detail }
      end
    end
  end
  return { ok = true }
end

-- ===== 门通路口径（哪扇门算「实际通路」）=====
-- 放在策略层而不是 gtrep：它是一条**口径**（门图与诊断共用），而且在这里能被 headless
-- 测到 —— gtrep 加载不了，那边一行引用错误只有进游戏才暴露。2026-10-06 实测教训：
-- 我按行号替换时误删了本表，door_is_passage 引用成了 nil 全局 → 每帧
-- "attempt to index a nil value (global 'LOCKED_DOOR_VARIANTS')" → 渲染链崩 → 传送光标瞬消。
--
-- 实测数据（真机日志 `door slot=` 行逐门打印 variant/isOpen/passage）：
--   普通门 / 炸开的隐藏房 / boss 房 / 红挑战房闸门 ......... variant=8
--   上锁的宝藏房门 / 上锁的街机厅门 ...................... variant=1 isOpen=false
--   没炸开的隐藏墙 ...................................... variant=7 isOpen=false
--
-- 判据：**variant 不是锁定型，或者门此刻开着**（两条任一成立即算通路）。
--   · 1..6(各种 LOCKED) / 7(HIDDEN) 且门关着 → 不算通路（「商店上锁传不进去」的由来）
--   · variant 锁定型但门开着 → 算通路，留给「解锁后 variant 未变、只有 IsOpen 变 true」；
--     **实测反证它不误放**：上锁的门 isOpen=false，这条后路对它们不发作。
--   · 0(UNSPECIFIED) / 8(UNLOCKED) → 算通路。
--   · sweep_doors 也会读取隐藏墙，以便撤销已失效的旧连接。
-- ⚠️ 这段被改过三次（只看 variant → 只看 IsOpen → 两条任一）。选它的理由是「门开着就能走」
--    这个口径，而不是「哪条更简单」。
local is_passage = require("scripts.gtp_passage")
function gt:door_is_passage(door)
  return is_passage(door)
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
  if gt:get_travel_mode() == 1 then return { ok = true } end
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
    if ctx.mode == 1 and ctx.target ~= nil and not gt:is_grid_room_displayed(ctx.gid) then
      return { gid = ctx.gid, selectable = false }
    end
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

-- 挑战房的「进入条件现状」：规则本体与诊断探针都读这一份，避免两处漂移。
-- 非挑战房 / 玩家不可用 时返回 nil。
function gt:challenge_entry_state(gid)
  local rd = gt:grid_room_desc(gid)
  if not (rd and rd.Data and rd.Data.Type == 11) then return nil end
  local p = Isaac.GetPlayer(0)
  if not p or not p:Exists() then return nil end
  local door = gt:door_to(gid)
  local open = false
  if door then
    local okc, v = pcall(function() return door:IsOpen() end)
    open = okc and v == true
  end
  local lvl = Game():GetLevel()
  return {
    done = rd.ChallengeDone == true,
    door = door,
    door_open = open,
    -- 全按**半心**计（官方文档：GetHearts / GetSoulHearts / GetMaxHearts 都是半心单位）
    hearts = p:GetHearts(),
    soul = p:GetSoulHearts(),
    -- ⚠️ 这是**位掩码**不是数量（官方文档原文：「并不返回黑心的数量；而是返回一个位掩码，
    -- 用于表示哪些灵魂心是黑心」）。**绝不能把它加进血量总和** —— 原 Fixed 公式就是那么错的。
    black_mask = p:GetBlackHearts(),
    maxhearts = p:GetMaxHearts(),
    stage = lvl and lvl:GetStage() or 0,
  }
end

gt:add_travel_rule({
  id = "target.challenge_gate", stage = "target_entry", order = 60,
  text = "目标是挑战房，而当前血量不满足它的进入条件",
  test = function(ctx)
    local s = gt:challenge_entry_state(ctx.gid)
    if not s then return nil end                -- 非挑战房 / 玩家不可用
    if s.done then return nil end               -- 打完了的挑战房不再查条件（Fixed 原语义）
    -- 血量总和 = **红心 + 魂心**（两者都是半心单位）。
    -- ⚠️⚠️ 绝不能加 GetBlackHearts() —— 官方文档原文：「这个函数并不返回黑心的数量；
    --      而是返回一个**位掩码**」。原 Fixed 的 `红+魂+黑` 就错在这里，而且这一个错
    --      把两种挑战房都带偏了（这条规则因此改了四轮）。
    local hp = s.hearts + s.soul
    -- ★ 判据就是**层数奇偶**（用户 2026-10-06 明确）—— 因为挑战房有两种，
    --   而种类由出现楼层决定（所以奇偶 == 种类）：
    --     普通挑战房 = 每章**第一层**（奇数 stage，含合并楼层）→ 要求**满血**
    --     头目挑战房 = 每章**第二层**（偶数 stage；stage 10 特例除外）→ 要求 **≤1 心**
    --   也就是说 Fixed 的奇偶分支本来就是对的，只有上面那处位掩码是 bug。
    --   实测两例（stage=4 头目房）：红+魂=2 → 闸门开；红+魂=4 → 闸门关 —— 与本节判据一致。
    if s.stage % 2 == 0 and s.stage ~= 10 then
      -- 头目挑战房：hp > 2 就拒绝 ⇒ 放行要求 ≤1 心（= 2 个半心）
      if hp <= 2 then return nil end
      return { branch = "boss_challenge(hp<=2)", stage = s.stage, hp = hp,
               hearts = s.hearts, soul = s.soul, blackMask = s.black_mask,
               door = s.door and tostring(s.door_open) or "none", need = "hp<=2" }
    end
    -- 普通挑战房：hp < GetMaxHearts() 就拒绝 ⇒ 放行要求满血
    -- （这一支**没有实测数据**覆盖；沿用 Fixed 的比较形状，只去掉位掩码。若日后发现
    --  它不对，请按实测改，并把这个注释换成实测记录。）
    if hp >= s.maxhearts then return nil end
    return { branch = "challenge(hp>=max)", stage = s.stage, hp = hp,
             maxhearts = s.maxhearts, hearts = s.hearts, soul = s.soul,
             door = s.door and tostring(s.door_open) or "none",
             need = "hp>=" .. tostring(s.maxhearts) }
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
      if reach[rd.SafeGridIndex] ~= true then return false end
      -- 最后一跳要区分两个**看起来一样、其实不同**的情形（2026-10-06 实测两次）：
      --   ① 隔墙相邻（网格挨着但**根本没有门**）：兜底会当成连通 → 上锁的宝藏房 /
      --      街机厅因此能被传进去 ✗。必须**拒**。
      --   ② 有门、但那个邻居本次没重新扫过（继续存档 / rewind 后门图被清空）：
      --      边没学到不代表不通 ✗。必须**放**。
      -- 区别就在「这一侧配置上有没有门」→ 读 RoomConfigRoom.Doors（位掩码）。
      local a, b = rd.SafeGridIndex, t.SafeGridIndex
      if gt:has_known_passage(a, b) then return true end
      local _, sa = gt:door_links_of(a)
      local _, sb = gt:door_links_of(b)
      if sa or sb then return false end          -- 有一边扫过 → 没学到边就是真没有通路
      return gt:has_door_between(a, b) == true    -- 都没扫过 → 只在配置上真有门时才认
    end)
    if near then return nil end
    return { branch = "channel_c", mode = ctx.mode }
  end,
})

-- ===== 计时代价：执行层调用，不参与准入 =====
function gt:travel_time_distance(from, to)
  if gt:get_travel_mode() == 1 or not gt:get_config_bool("FairTripTime", false) then
    return 0
  end
  local dist = gt:fair_trip(from, to)
  if dist == 999 then return 0 end -- BFS 的无路线哨兵，不是实际距离
  return dist
end

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
-- 所以 ascii 模式印**规则 id**而不是中文散文；控制台也只用 ASCII，中文说明仅供日志使用。
-- 第二个返回值 = 是否可传送（浮层要靠它决定画不画）。
function gt:travel_verdict_dump(gid, ascii)
  local ctx = gt:travel_ctx(gid)
  local L = { string.format("travelDiag: target gid=%s mode=%d fairPath=%s fairTime=%s",
    tostring(gid), ctx.mode, tostring(ctx.fair_path), tostring(ctx.fair_time)) }
  if ctx.mode == 1 then
    L[#L + 1] = "  unrestricted mode: gameplay gates bypassed; selectable map targets only"
  end
  local stopped, verdict = false, nil
  for _, sname in ipairs(gt.travel_stages) do
    if stopped then
      L[#L + 1] = "  [" .. sname .. "] skipped (short-circuited)"
    else
      local bucket = gt.travel_rules[sname]
      local hit_rule, hit_detail = nil, nil
      for i = 1, #bucket do
        local detail = gt:travel_rule_enabled(bucket[i], ctx) and bucket[i].test(ctx) or nil
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
-- 光标停在一个目标上时，自动把整段判定过程 + 门表写进 log.txt。
-- 为什么要这个：2026-10-06 反复踩到「用户报问题 → 我请用户按 F4/截图 → 用户没按/截不全
-- → 白跑一轮」。光标扫过去就落盘，把取证负担从用户挪回代码。
--
-- **被拒要记，挑战房被放行也要记** —— 放行同样可能判错。2026-10-06 实测就撞上过
-- 「闸门关着却放行」，而那时取证只在被拒时落盘，于是这件事在日志里完全看不见。
-- 去重键带上现场状态（门状态 / 血量 / 打完没），所以状态一变就是新的一行；
-- 否则第一次那条「正常放行」会把后来的错判盖住（用户那次正是先正常、后错判）。
-- 每层清空，量有界。
local travel_probe_logged = {}

function gt:travel_reset_probe_log()
  travel_probe_logged = {}
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

-- 挑战房的现场探针：把判据依赖的输入全打出来（非挑战房返回 nil）
--
-- ⚠️ **两种挑战房**：`RoomType.ROOM_CHALLENGE (11)` 的文档注释区分了「普通挑战房」与
-- 「头目挑战房」两种变体（引用两个不同图标）。本探针打出 variant / subtype / name /
-- flags / 房间生成表摘要，就是为了在日志里**认出是哪一种** —— 不要假设它们同一套条件。
function gt:challenge_probe(gid)
  local s = gt:challenge_entry_state(gid)
  if not s then return nil end
  local rd = gt:grid_room_desc(gid)
  local kind = "?"
  pcall(function()
    local d = rd and rd.Data or {}
    local parts = {}
    parts[#parts + 1] = "variant=" .. tostring(d.Variant)
    parts[#parts + 1] = "subtype=" .. tostring(d.Subtype)
    parts[#parts + 1] = "name=" .. tostring(d.Name)
    parts[#parts + 1] = "flags=" .. tostring(rd and rd.Flags)
    -- 房间生成表摘要（前 12 项 type/variant）—— 头目挑战房里应该有 boss 级条目
    local sp = {}
    local list = d.Spawns
    if list then
      local n = list.Size or #list
      for i = 0, n - 1 do
        local e = (list.Get and list:Get(i)) or list[i + 1]
        if e then
          sp[#sp + 1] = tostring(e.Type) .. "/" .. tostring(e.Variant)
          if #sp >= 12 then break end
        end
      end
    end
    parts[#parts + 1] = "spawns=[" .. (#sp > 0 and table.concat(sp, " ") or "none") .. "]"
    kind = table.concat(parts, " ")
  end)
  return string.format(
    "  challengeProbe gid=%s door=%s isOpen=%s hearts=%s soul=%s blackMask=%s " ..
    "maxHearts=%s stage=%s challengeDone=%s  (hearts/soul/maxHearts 皆为半心；blackMask 是位掩码)\n" ..
    "    roomKind: %s",
    tostring(gid), s.door and "yes" or "none", tostring(s.door_open),
    tostring(s.hearts), tostring(s.soul), tostring(s.black_mask),
    tostring(s.maxhearts), tostring(s.stage), tostring(s.done), kind)
end

-- 目标房的现场摘要（每次取证都带）：类型 / 探过没 / 清怪没 / 显示旗标 / 是否隐藏房 / 当前档位
-- —— 2026-10-06 加：报「传进未炸开的隐藏房」时，日志里必须能直接看出目标是什么房。
function gt:travel_target_dump(gid)
  local rd = gt:grid_room_desc(gid)
  if not rd then return "  target: not in grid_room" end
  return string.format(
    "  target: type=%s visited=%s clear=%s dispFlags=0x%x isSecret=%s mode=%d",
    tostring(rd.Data and rd.Data.Type), tostring(rd.VisitedCount),
    tostring(rd.Clear), rd.DisplayFlags or 0,
    tostring(gt:is_secret_room(rd)), gt:get_travel_mode()) ..
    "  doorsBits=" .. tostring(rd.Data and rd.Data.Doors) ..
    "  (RoomConfigRoom.Doors 位掩码；读不到就是 nil)"
end

-- 目标房在**门图**里已学到的边（诊断用）：这是回答「这条通路是哪来的」的唯一办法 ——
-- 上锁的门 passage=false，可如果先前某刻它的门是开的，这条边就已经记下了（门图只增不减），
-- 而当前房间的门表**看不到别人房间的门**。
function gt:travel_links_dump(gid)
  local rd = gt:grid_room_desc(gid)
  if not rd then return "  links: no target" end
  local links, swept = gt:door_links_of(rd.SafeGridIndex)
  local parts = {}
  for _, e in ipairs(links) do
    parts[#parts + 1] = tostring(e.other) .. "(slot " .. tostring(e.slot) .. ")"
  end
  return string.format("  links(sgi=%s swept=%s): %s", tostring(rd.SafeGridIndex),
    tostring(swept), #parts > 0 and table.concat(parts, " ") or "none")
end

local function auto_log_travel_body(gid, res)
  if not gt:is_debug() then return end
  local probe = gt:challenge_probe(gid)
  -- 放过谁也要记：**非普通房**的放行都记（ROOM_DEFAULT 放行是常态，记了会刷屏）。
  -- ⚠️ 2026-10-06 实测教训：原来只记「被拒 + 挑战房被放行」，于是「传进未炸开的隐藏房」
  --    在日志里毫无痕迹、只能靠猜 —— 取证条件不能按「我怀疑什么」来收窄。
  if res.ok and not probe then
    local rd = gt:grid_room_desc(gid)
    local t = rd and rd.Data and rd.Data.Type
    if t == nil or t == 1 then return end
  end
  local key = tostring(gid) .. "|" .. tostring(res.rule) .. "|" .. (probe or "")
  if travel_probe_logged[key] then return end
  travel_probe_logged[key] = true
  local lines = { "[GTPtrip] " .. (res.ok and "allowed" or "rejected") ..
    " target (auto, no keypress needed)  rule=" .. tostring(res.rule or "-") }
  lines[#lines + 1] = gt:travel_verdict_dump(gid, true)
  lines[#lines + 1] = gt:travel_target_dump(gid)
  lines[#lines + 1] = gt:travel_links_dump(gid)
  if probe then lines[#lines + 1] = probe end
  lines[#lines + 1] = gt:travel_doors_dump()
  Isaac.DebugString(table.concat(lines, "\n"))
end

-- 取证是**诊断**：绝不能因为诊断自身的 bug 把渲染链带崩（2026-10-06 实测教训 ——
-- 影子对照一次 nil 调用就让光标 / 地图边界 / 未探索目标全废）。整段 pcall，
-- 出错只留一行告警，绝不弄坏它要排查的功能。
function gt:auto_log_travel(gid, res)
  if not gt:is_debug() then return end
  local okc, err = pcall(auto_log_travel_body, gid, res)
  if not okc then
    Isaac.DebugString("[GTPtrip] auto-log 抛错，本条取证已跳过：" .. tostring(err))
  end
end

-- ===== 屏幕理由浮层（仅调试模式）=====
-- 调试模式打开、且正按住地图键时，光标停在会被拒的房间上就把**整条判定过程**
-- 画在屏幕左上角（逐段逐条 + 短路 + 规则 id + detail）；通过时不画。
-- 正常游玩完全不出（仍只有失败音）。
--
-- 为什么一次印一整段而不是一句话：2026-10-06 实测教训 —— 原来只印一句中文理由，
-- 而诊断字体画不出中文，用户屏幕上只剩 "gid=35"，什么也判断不了。
-- 印成 ASCII 的整段判定，一张截图就能定位到规则与它的入参。
-- 为什么不复用一次性 dump 的那条路：那条浮层是**帧数生存期**的（要等 15 秒才消失），
-- 而这里是「跟着光标实时变、松手即消失」。另外那条黄色浮层已于 2026-10-06 整体删除
-- （只挡视线，内容 log.txt 里都有），所以屏幕上的诊断显示**只剩这一条**。
function gt:render_travel_reason(cursor_pos, cursor_active)
  if not gt:is_debug() or not cursor_active then return end
  local font = gt:get_diag_font()
  if not font then return end
  local y = 20
  local function draw(s, color)
    font:DrawString(s, 16, y, color, 0, false)
    y = y + 11
  end
  local gid = gt.get_cursor_grid_index and gt:get_cursor_grid_index(cursor_pos)
    or gt:get_pos_grid_index(cursor_pos)
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
