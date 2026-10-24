--[[
  GoodTripPlus - 光标目标格解析（纯函数，可 headless 测）
  =====================================================

  光标落在某枚房间图标上时，有两个可能的目标格：

    · position_gid —— 按**屏幕位置**反算出的格号。位置↔格号是原版约定
      （画面第 56 格位置就是 56 号房），ChangeRoom 要去的正是这一格。
    · hit_cell     —— 光标命中那枚图标所属 descriptor 的格号。

  正常情况下两者相同。**混乱诅咒交换两间房内容**之后会不一致：

    · 游戏交换的是房间内容（Data/variant），格号、门、房型都不变
      （wiki：两间房的类型、尺寸、门位置、红房状态必须相同才会被交换）。
    · MiniMAPI 的 HandleCurseOfMaze 会交换两间房的 room.Position，让图标
      （含物品图标）跟着内容搬到内容现在所在的那一格 —— 这是对的，与 wiki
      「物品图标随房间更换位置」一致。
    · 于是那枚图标所属的 descriptor 已经不是画在它下面的那一格了。

  结论：**目标格必须取 position_gid**。用 hit_cell 会出现「点自己站着的房间，
  却被传送到另一间」「点对面那间却判 same_room」——玩家 2026-10-24 反馈的
  就是这个（3.0.1 曾在判定层硬挡标记图标，3.0.3 起改用这里的口径）。
  高亮不受影响：它画在命中的那枚图标上，见 gtrep 的 mmp_highlight_list_index。
]]--
local function valid_gid(gid)
  return type(gid) == "number" and gid >= 0 and gid <= 168
end

-- 返回目标格号；两路都不可用时返回 -99（调用方按「没有目标」处理）。
return function(position_gid, hit_cell)
  if valid_gid(position_gid) then return position_gid end
  if valid_gid(hit_cell) then return hit_cell end
  return -99
end
