--[[
  GoodTripPlus - 「Boss 奖励房间的门」出现时禁用传送（常开，无开关）
  ============================================================

  需求（2026-10-03 用户提出，同日收紧）
  ------------------------------------
  打败 boss 后，游戏可能给 boss 房开出一扇通往「奖励房间」的门
  （恶魔房 / 天使房 / Boss Rush / 死寂）。此时用 GoodTrip 误触传送出房，
  可能把还没进的奖励门错过。所以：

    **当前房间里存在这类「通往奖励房间的门」时，禁止一切传送。**

  为什么不是「刚打完 boss 就禁传」
  --------------------------------
  那是上一版的做法，窗口太宽：没开出任何奖励门的 boss 房（绝大多数情况）
  也会被拦 —— 正常打完 boss 就传不出去了（用户实测）。改成按**门**判定后，
  只有真有奖励门可进时才拦，而且门还在房间里就一直拦，与「奖励还摆在那儿、
  别动」的语义完全一致。

  判据（读门自己的目标房间；2026-10-03 用 IsaacDocs 的 GridEntityDoor 页面
  与 thicco-catto/library-of-isaac 的 Doors 模块交叉核对过）
  ---------------------------------------------------------
  遍历当前房间 8 个门槽（`DoorSlot.NUM_DOOR_SLOTS`），任一门满足以下之一即命中：
    · `door.TargetRoomType == RoomType.ROOM_DEVIL`(14)  —— 恶魔房的门
    · `door.TargetRoomType == RoomType.ROOM_ANGEL`(15)  —— 天使房的门
    · `door.TargetRoomType == RoomType.ROOM_BOSSRUSH`(17)
      或 `door.TargetRoomIndex == GridRooms.ROOM_BOSSRUSH_IDX`(-5)  —— Boss Rush
    · `door.TargetRoomIndex == GridRooms.ROOM_BLUE_WOOM_IDX`(-8)   —— 死寂（Hush）
  注意 **DoorVariant 里没有这些门型**（只有 0~8 九个普通值，见原版 enums.lua），
  所以必须看门的目标房间，不能看门的 variant。

  回溯线（The Ascent）排除：那里的 boss 房只是路过房、没有奖励门，直接跳过，
  免得任何边界情况误伤。

  拦在哪（不改 gtrep.lua）
  ------------------------
  包一层 `gt.check_teleble()`：保存原函数再替换，命中时直接返回 false。
  表现与其它准入拒绝完全一致 —— 光标不高亮、按 TAB 也不启用、松手也不会传。
  常开、没有开关；唯一的例外是 `gt.DebugMod` 调试模式（它本来就要绕过全部准入）。

  诊断
  ----
  控制台 `gtpdiag` 会附带一行本模块状态（含命中的门槽 / 目标类型 / 目标索引）；
  注意 MC_EXECUTE_CMD 回调**不能返回字符串**（会闪退，见 v1.5.7），这里只输出不返回。
]]--

-- 目标房间**类型**属于奖励房间的门
local REWARD_DOOR_TYPES = {
  [RoomType.ROOM_DEVIL] = true,       -- 恶魔房的门
  [RoomType.ROOM_ANGEL] = true,       -- 天使房的门
  [RoomType.ROOM_BOSSRUSH] = true,    -- Boss Rush 的门
}

-- 目标房间**索引**属于奖励房间的门（这些房间没有常规网格索引，用负的固定值表示）
local REWARD_DOOR_INDICES = {
  [GridRooms.ROOM_BOSSRUSH_IDX] = true,   -- Boss Rush（-5）
  [GridRooms.ROOM_BLUE_WOOM_IDX] = true,  -- 死寂 / Hush / Blue Womb（-8）
}

-- 命中奖励门的那个门槽（nil = 没有）；诊断用
local last_hit_slot = nil
local last_hit_desc = nil

-- 当前房间里是否有「通往奖励房间的门」
function gt:has_reward_door()
    last_hit_slot, last_hit_desc = nil, nil
    local r = Game():GetRoom()
    if not r then
      return false
    end
    for i = 0, DoorSlot.NUM_DOOR_SLOTS - 1 do
      local door = r:GetDoor(i)
      if door and (REWARD_DOOR_TYPES[door.TargetRoomType]
          or REWARD_DOOR_INDICES[door.TargetRoomIndex]) then
        last_hit_slot = i
        last_hit_desc = string.format("slot=%d var=%s targetType=%s targetIdx=%s",
          i, tostring(door.Desc and door.Desc.Variant),
          tostring(door.TargetRoomType), tostring(door.TargetRoomIndex))
        return true
      end
    end
    return false
end

-- 是否要拦传送：房间里还有奖励门，且不在回溯线
local function reward_door_blocks()
    local level = Game():GetLevel()
    if not level or level:IsAscent() then
      return false
    end
    return gt:has_reward_door()
end

-- 包一层准入判定：有奖励门时整体拒绝
local base_check_teleble = gt.check_teleble
if type(base_check_teleble) == "function" then
  gt.check_teleble = function(self, gid)
    -- 常开（用户 2026-10-03 要求不给开关）；gt.DebugMod 调试模式仍可绕过，
    -- 与 gtrep 里其它准入拒绝保持一致
    if not gt.DebugMod and reward_door_blocks() then
      return false
    end
    return base_check_teleble(self, gid)
  end
else
  Isaac.DebugString("[GoodTripPlus][rewardDoor] WARNING: gt.check_teleble 不存在，" ..
    "包装失败（加载顺序变了？）")
end

-- gtpdiag 附带本模块状态（与其它模块共用同一条命令；回调只输出、不返回字符串）
gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
  local cmd = tostring(command or ""):lower():match("^%s*(%S+)")
  if cmd ~= "gtpdiag" and cmd ~= "gtpd" then
    return
  end
  local present = gt:has_reward_door()
  local line = "rewardDoor: present=" .. tostring(present) ..
    (present and (" hit{" .. tostring(last_hit_desc) .. "}") or " (no devil/angel/bossrush/hush door)")
  pcall(function()
    Isaac.ConsoleOutput(line .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. line)
  end)
end)
