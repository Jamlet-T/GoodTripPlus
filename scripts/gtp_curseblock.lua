--[[
  GoodTripPlus - 「禁止传送进诅咒房」（GoodTrip [Fixed] 的 BlockCurseRoom，默认开）
  =================================================================

  需求（2026-10-05 用户报 bug：能传送进已探索过的诅咒房）
  ----------------------------------------------------
  诅咒房（RoomType.ROOM_CURSE = 10，进出时按门咬血的那种）在上游
  GoodTrip [Fixed] 里**默认不允许传送进入** —— 变量 `gt.BlockCurseRoom`，
  MCM 项「禁止传送进诅咒房」，默认开。
  本 mod 早期移植时把这一条连开关一起删了（改成「能传，但进门照旧扣血」），
  于是已探索过的诅咒房会落进「visited + clear」放行分支，能直接传进去
  （用户实测）。本模块把它补回来：

    · BlockCurseRoom = true（默认） → 全局禁止把传送目标落在诅咒房上；
    · BlockCurseRoom = false        → 不拦，诅咒房按普通房间处理（**含「相邻房间」档的
      未探索邻居豁免**：Fixed 的 check_neigh_connected 类型白名单本来把诅咒房(10)
      排除在外，导致关掉本开关也传不进「已显示但未探索」的诅咒房；该白名单在
      gtrep.lua 里同样按本开关放行类型 10，见那边的注释）。

  ⚠️ 本模块只管「传送到诅咒房」这个**目标**的准入；上面第二条里「关掉后按普通房间
  处理」要 gtrep.lua 的 check_neigh_connected 配合，两处都以 `gt:block_curse_room()`
  为唯一开关（定义在 gtrep.lua，与 get_travel_mode 同类）。

  语义 & 落点
  -----------
  · 只拦「**传送到**诅咒房」（目标房间类型 == 10）。**从诅咒房传出去不拦**
    ——用户要的是「不能传进去」，传出去反而方便；出去时该扣的血
    （`gt:check_curse_room()` 的过路费）照旧在 `gt:teleport_to_grid_index()` 里扣。
  · 判定位置**显式**（2026-10-06 起）：登记为 ② target_entry 段的规则
    `target.curse_blocked`。规则表按「段 → 段内登记顺序」跑，② 在 ③ range 之前，
    所以「全局禁止」对三个传送范围档位一视同仁 —— 不再依赖函数包装，
    也不再靠 `main.lua` 的 require 顺序决定谁在外面。
  · 目标房间类型读 `Level:GetRoomByIdx(gid, dim)`：与 gtrep.lua 的 `grid_room`
    同源（`gt:get_grid_room()` 就是照这个建的），所以判定口径与准入本体完全一致。
    `gid` 非合法格号（例如只问「当前房能不能开光标」时）一律放行，不误伤。
  · 与 gtp_bosswindow 同一套写法（各登记一条规则），表现与其它准入拒绝一致：
    光标不高亮、按 TAB 不启用、松手也不传。
  · 调试模式（`gt:is_debug()`）**不参与判定**（2026-10-06 用户要求：调试模式只出诊断、
    不改变任何传送逻辑）—— 所以开着调试模式时，本模块照常按开关拦/放。

  诊断
  ----
  控制台 `gtpdiag` 附带一行本模块状态（开关值 + 当前房间类型）。
  ⚠️ `MC_EXECUTE_CMD` 回调不能返回字符串（会闪退，见 v1.5.7），这里只输出不返回。
]]--

-- 目标格是不是「诅咒房」。
-- 读 Level:GetRoomByIdx（与 gtp_curseblock 移植时的原口径一致；判定层的
-- gt:room_desc_at 就是它的薄包装）。
local function is_curse_room_gid(gid)
    if type(gid) ~= "number" or gid < 0 or gid >= 169 then
        return false   -- gid == false：只在问当前房能不能开光标，不是传送目标
    end
    local rd = gt:room_desc_at(gid)
    return rd ~= nil and rd.Data ~= nil and rd.Data.Type == RoomType.ROOM_CURSE
end

-- 登记判定规则（2026-10-06 起不再包装 gt.check_teleble）。
-- 排在 ② target_entry 段 —— 「目标能不能进」，与档位无关；③ range 段在它之后，
-- 所以「全局禁止」对三个传送范围档位一视同仁。
gt:add_travel_rule({
    id = "target.curse_blocked", stage = "target_entry", order = 40,
    text = "「禁止传送进诅咒房」已开启",
    test = function(ctx)
        -- 调试模式不参与判定（2026-10-06 用户要求：debug 只出诊断、不改行为）
        if not gt:block_curse_room() then return nil end
        if not is_curse_room_gid(ctx.gid) then return nil end
        return { gid = ctx.gid }
    end,
})

-- gtpdiag 附带本模块状态（与其它模块共用同一条命令；回调只输出、不返回字符串）
gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
    local cmd = tostring(command or ""):lower():match("^%s*(%S+)")
    if cmd ~= "gtpdiag" and cmd ~= "gtpd" then
        return
    end
    local lvl = Game():GetLevel()
    local dsc = lvl and lvl:GetCurrentRoomDesc() or nil
    local cur = dsc and dsc.Data and dsc.Data.Type or -1
    local line = "curseBlock: blockCurseRoom=" .. tostring(gt:block_curse_room()) ..
        " currentRoomType=" .. tostring(cur) ..
        (cur == RoomType.ROOM_CURSE and " (current room IS a curse room)" or "")
    pcall(function()
        require("scripts.gtp_console").write(line .. "\n")
        Isaac.DebugString("[GoodTripPlus] " .. line)
    end)
end)
