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
    · `door.TargetRoomType == RoomType.ROOM_DEVIL`(14)  —— 临时恶魔房的门
    · `door.TargetRoomType == RoomType.ROOM_ANGEL`(15)  —— 临时天使房的门
    · `door.TargetRoomType == RoomType.ROOM_BOSSRUSH`(17)
      或 `door.TargetRoomIndex == GridRooms.ROOM_BOSSRUSH_IDX`(-5)  —— Boss Rush
    · `door.TargetRoomIndex == GridRooms.ROOM_BLUE_WOOM_IDX`(-8)   —— 死寂（Hush）
  注意 **DoorVariant 里没有这些门型**（只有 0~8 九个普通值，见原版 enums.lua），
  所以必须看门的目标房间，不能看门的 variant。

  2.5.9：红钥匙生成的恶魔/天使房是常驻房间，不属于这个保护窗口。
  用描述符 FLAG_RED_ROOM 核对当前房和门目标（当前维度），豁免房内出口与相邻入口；
  无明确红房证据时继续保护。Boss Rush / Hush 固定索引保护优先，不受此豁免影响。

  回溯线（The Ascent）排除：那里的 boss 房只是路过房、没有奖励门，直接跳过，
  免得任何边界情况误伤。

  拦在哪
  ------
  登记为 ① departure 段的规则 `departure.reward_door`（2026-10-06 起不包装函数）。
  ① 段是「现在能不能走」，它决定**光标能不能呼出** —— 所以房间里有奖励门时连光标都不出。
  表现与其它准入拒绝完全一致。常开、没有开关；**任何设置都不能绕过**
  （包括「调试模式」—— 2026-10-06 起调试模式只出诊断、不改变任何传送判定）。

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

local function is_red_reward_room(rd)
    local t = rd and rd.Data and rd.Data.Type
    return (t == RoomType.ROOM_DEVIL or t == RoomType.ROOM_ANGEL)
      and ((rd.Flags or 0) & RoomDescriptor.FLAG_RED_ROOM) ~= 0
end

local function is_temporary_reward_door(door, current_is_red_reward)
    if REWARD_DOOR_INDICES[door.TargetRoomIndex] then return true end
    if not REWARD_DOOR_TYPES[door.TargetRoomType] then return false end
    if door.TargetRoomType == RoomType.ROOM_BOSSRUSH then return true end
    -- 红房内出口的门类型也可能保留恶魔/天使类型，不能只查门外目标。
    if current_is_red_reward then return false end
    local idx = door.TargetRoomIndex
    local target = type(idx) == "number" and idx >= 0 and gt:room_desc_at(idx) or nil
    return not is_red_reward_room(target)
end

-- 当前房间里是否有「通往奖励房间的门」
function gt:has_reward_door()
    last_hit_slot, last_hit_desc = nil, nil
    local r = Game():GetRoom()
    if not r then
      return false
    end
    local current_is_red_reward = is_red_reward_room(gt:travel_cur_state().cur)
    for i = 0, DoorSlot.NUM_DOOR_SLOTS - 1 do
      local door = r:GetDoor(i)
      if door and is_temporary_reward_door(door, current_is_red_reward) then
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

-- 登记判定规则（2026-10-06 起不再包装 gt.check_teleble）。
-- 排在 ① departure 段 —— 「现在能不能走」，与目标无关：有奖励门时**连光标都呼不出**。
-- 常开（用户 2026-10-03 要求不给开关），且**不可绕过**（调试模式自 2026-10-06 起
-- 不再参与判定，只出诊断）。
gt:add_travel_rule({
  id = "departure.reward_door", stage = "departure", order = 70,
  text = "房间里有通往奖励房间的门（恶魔房 / 天使房 / Boss Rush / 死寂）",
  test = function(ctx)
    if not reward_door_blocks() then return nil end
    return { slot = last_hit_slot, door = last_hit_desc }
  end,
})

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
    require("scripts.gtp_console").write(line .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. line)
  end)
end)
