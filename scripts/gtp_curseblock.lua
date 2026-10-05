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
  · 判定放**早**：包一层 `gt.check_teleble()`，在任何「放行」分支（含 TravelMode
    「任意房间」的提前 return）之前拦下 —— 这样「全局禁止」对三个传送范围档位
    一视同仁。
  · 目标房间类型读 `Level:GetRoomByIdx(gid, dim)`：与 gtrep.lua 的 `grid_room`
    同源（`gt:get_grid_room()` 就是照这个建的），所以判定口径与准入本体完全一致。
    `gid` 非合法格号（例如 `gt:check_teleble(false)` —— 只在问「当前房能不能开
    光标」，不是传送目标）一律放行，不误伤。
  · 与 gtp_bosswindow 同一套写法（包装函数、不改 gtrep.lua 的准入本体），
    所以表现与其它准入拒绝一致：光标不高亮、按 TAB 不启用、松手也不传。
  · 调试模式（`gt:is_debug()`）绕过，与其它准入拒绝一致。

  诊断
  ----
  控制台 `gtpdiag` 附带一行本模块状态（开关值 + 当前房间类型）。
  ⚠️ `MC_EXECUTE_CMD` 回调不能返回字符串（会闪退，见 v1.5.7），这里只输出不返回。
]]--

-- 目标格是不是「诅咒房」
function gt:is_curse_room_gid(gid)
    if type(gid) ~= "number" or gid < 0 or gid >= 169 then
        return false   -- gid == false：只在问当前房能不能开光标，不是传送目标
    end
    local lvl = Game():GetLevel()
    if not lvl then
        return false
    end
    local rd = lvl:GetRoomByIdx(gid, gt:get_current_dimension())
    return rd ~= nil and rd.Data ~= nil and rd.Data.Type == RoomType.ROOM_CURSE
end

-- 开关本身是 gt:block_curse_room()（定义在 gtrep.lua，与 get_travel_mode 同类）。

-- 本模块是否拦下这个传送目标
function gt:curse_room_blocks(gid)
    if gt:is_debug() then
        return false
    end
    return gt:block_curse_room() and gt:is_curse_room_gid(gid)
end

-- 包一层准入判定：目标是诅咒房时整体拒绝
local base_check_teleble = gt.check_teleble
if type(base_check_teleble) == "function" then
    gt.check_teleble = function(self, gid)
        if gt:curse_room_blocks(gid) then
            return false
        end
        return base_check_teleble(self, gid)
    end
else
    Isaac.DebugString("[GoodTripPlus][curseBlock] WARNING: gt.check_teleble 不存在，" ..
        "包装失败（加载顺序变了？）")
end

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
        Isaac.ConsoleOutput(line .. "\n")
        Isaac.DebugString("[GoodTripPlus] " .. line)
    end)
end)
