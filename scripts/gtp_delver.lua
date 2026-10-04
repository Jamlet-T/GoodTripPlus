--[[
  GoodTripPlus - 隐藏房候选标记
  ============================================================

  功能合并自 Lazy Delver（作者 dokee，MIT 许可，许可证原文见
  scripts/delver/LICENSE-lazy-delver.txt），候选位置的推演逻辑原样移植，
  只在「标记画在哪里」这一层做了替换。

  功能：在小地图上标出隐藏房 / 超级隐藏房 / 究极隐藏房的**可能位置**，随探索逐步排除错误位置。
    * 按住地图键（默认 TAB）显示
    * 白色 = 普通隐藏房候选，金色 = 超级隐藏房候选，红色 = 究极隐藏房候选（持有红钥匙 /
      红钥匙碎片 / 该隐的魂石时才显示）
    * 明亮 = 所有相邻房间都已探查；暗淡 = 还有相邻房间没去过
    * 进房间后若门到墙的路径被挡（实心墙、无门）→ 排除该候选
    * 炸弹在门位附近爆炸 → 排除对应的假候选
    * 真隐藏房在地图上出现后，同类假候选自动清除

  与原版 Lazy Delver 的唯一实质差别
  ---------------------------------
  原版自己推算地图坐标（用游戏的 RoomDescriptor.DisplayFlags 当锚点），而 MinimapAPI 画地图时
  用的是它自己的房间对象标志（GetDisplayFlags()），两者在边缘房间上会不一致（指南针 / 蓝地图 /
  隐房标记 / 大房间的 GridIndex≠SafeGridIndex 等），整张地图的锚点会平移一格，标记因此错位。
  这里改成复用 GoodTripPlus 的 gt:gid_to_rtmap_pos() —— 也就是传送光标用的同一套投影，
  它逐项复刻了 MinimapAPI 的布局数学（含镜像世界的负缩放），所以与地图逐像素对齐。
  另外标记绘制在与光标相同的渲染层（地图之后），不会再被地图图案压住。

  **启用本功能时请禁用 Lazy Delver 本体**，否则两套标记会同时画出来。

  开关：Mod Config Menu → GoodTripPlus → 「显示隐藏房候选标记」，或 gtconfig.lua 里
  设置 gt.ShowSecretMarkers = false。
]]

local C = require("scripts.delver.const")
local state = require("scripts.delver.state")
local map = require("scripts.delver.map")
local room = require("scripts.delver.room")
local render = require("scripts.delver.render")

-- 本项目修 bug（2026-10-03，用户报）：上游 delver/state.lua 里的 lost_cursed 是**缓存值**，
-- 只在 M.check() 跑到末尾时才更新，而 state.check() 只挂在 MC_POST_NEW_ROOM 上 ——
-- 于是「地图先完整显示过（候选已算好）、之后才被塞进迷失诅咒（药丸 P25 / 道具）」时，
-- 诅咒状态一直停在 false，长按 TAB 仍画出隐藏房候选，直到换一次房间（check() 重跑）才消失。
-- 这里把该访问器换成**实时读取**：GetCurses() 随时可查，每帧一次的开销可忽略；
-- 只覆盖这一个函数，不动上游移植文件 delver/state.lua。
state.is_lost_cursed = function()
  local level = Game():GetLevel()
  return level ~= nil
    and (level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST) ~= 0
end

local function enabled()
  return gt:get_config_bool("ShowSecretMarkers", true)
end

-- 换房间：重算地图数据、做门位检查、标记需要刷新
gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
  state.check()
  if not enabled() then
    return
  end
  room.door_check()
  render.refresh()
end)

-- 按住地图键时把标记淡入（松开**立即消失**，见 delver/render.lua 的 tab_hold_check）。
-- 注意：这个计数**与开关无关** —— 地图边界高亮（gtp_mapbounds.lua）也读它来同步
-- 淡入与显示条件，所以关掉隐藏房标记时不能让它停摆（2026-10-03）。
gt:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
  render.tab_hold_check()
end)

-- 炸弹在门位附近爆炸 → 排除假候选
gt:AddCallback(ModCallbacks.MC_POST_EFFECT_INIT, function(_, effect)
  if not enabled() then
    return
  end
  room.bomb_check(effect)
  render.refresh()
end, EffectVariant.BOMB_EXPLOSION)

-- 相关主动道具 / 卡牌 / 药丸使用后刷新候选
for _, item in ipairs(state.items.active) do
  gt:AddCallback(item.mc, function()
    if not enabled() then
      return
    end
    if item.clear then
      local lid = Game():GetLevel():GetCurrentRoomDesc().ListIndex
      map.clear_fake_neighbors(lid)
    end
    render.refresh()
  end, item.type)
end

-- 红钥匙类道具 / 透视类被动的持有状态变化
gt:AddCallback(ModCallbacks.MC_POST_PEFFECT_UPDATE, function(_, player)
  if not enabled() then
    return
  end
  if state.is_ignored() then
    return
  end

  local function check(param, has)
    if not has then
      param.possess = false
      return
    end
    if not param.possess then
      param.possess = true
      render.refresh()
    end
  end

  local active0, active1 = player:GetActiveItem(0), player:GetActiveItem(1)
  check(state.items.red[CollectibleType.COLLECTIBLE_RED_KEY],
    (active0 == CollectibleType.COLLECTIBLE_RED_KEY) or
    (active1 == CollectibleType.COLLECTIBLE_RED_KEY)
  )

  local card0, card1 = player:GetCard(0), player:GetCard(1)
  check(state.items.red[Card.CARD_CRACKED_KEY],
    (card0 == Card.CARD_CRACKED_KEY) or (card1 == Card.CARD_CRACKED_KEY)
  )
  check(state.items.red[Card.CARD_SOUL_CAIN],
    (card0 == Card.CARD_SOUL_CAIN) or (card1 == Card.CARD_SOUL_CAIN)
  )

  for type, param in pairs(state.items.passive) do
    check(param, player:HasCollectible(type))
  end
end)

-- 绘制：必须和传送光标用同一个回调，因为 MinimapAPI 在 REPENTOGON 下是在
-- MC_POST_HUD_RENDER 里画自己那张地图的；画在 MC_POST_RENDER 会被地图盖住。
-- 优先级比光标早 1，保证光标压在标记之上。
do
  local is_repentance = REPENTANCE or REPENTANCE_PLUS
  local marker_priority = ((CallbackPriority and CallbackPriority.LATE) or 1000) - 1

  if REPENTOGON then
    gt:AddPriorityCallback(ModCallbacks.MC_POST_HUD_RENDER, marker_priority, render.render)
    gt.markerRenderCallback = "MC_POST_HUD_RENDER (REPENTOGON)"
  elseif StageAPI and StageAPI.Loaded then
    StageAPI.AddCallback("GoodTripPlus", "POST_HUD_RENDER", 0.5, render.render)
    gt.markerRenderCallback = "StageAPI POST_HUD_RENDER"
  elseif is_repentance then
    gt:AddPriorityCallback(ModCallbacks.MC_POST_RENDER, marker_priority, render.render)
    gt.markerRenderCallback = "MC_POST_RENDER (priority)"
  else
    gt:AddCallback(ModCallbacks.MC_POST_RENDER, render.render)
    gt.markerRenderCallback = "MC_POST_RENDER (plain)"
  end
end
