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
    * 破墙泪弹撞网格 / 铁镐挥动命中门位 → 排除对应假候选；同房间揭露立即刷新
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

  另外两处只覆盖「访问器」、不动上游文件（详见文件里 state.is_lost_cursed 处的注释）：
    * 迷失诅咒状态改成**实时读取**（上游是换房才刷新的缓存，药丸/道具当场给诅咒时会滞后）；
    * 「因迷失诅咒而隐藏」这一条**跟随 MinimapAPI 的 Display During Curse（OverrideLost）**：
      MinimapAPI 强制显示地图时，隐藏房候选与地图边界高亮照常绘制 —— 与「迷失诅咒下能不能传送」
      同一口径（v2.1.1，用户要求）。二者都走 gt:curse_map_visible()。

  开关：Mod Config Menu → GoodTripPlus → 「显示隐藏房候选标记」，或 gtconfig.lua 里
  设置 gt.ShowSecretMarkers = false。
]]

local C = require("scripts.delver.const")
local state = require("scripts.delver.state")
local map = require("scripts.delver.map")
local room = require("scripts.delver.room")
local render = require("scripts.delver.render")
local visibility = require("scripts.gtp_delvervisibility")

-- 本项目对这个访问器有两处覆盖（都只改 gtp_delver 这一层，不动上游移植文件 delver/state.lua；
-- 它的消费点只有两处「要不要画」的闸门：delver/render.lua 的 M.render 与 gtp_mapbounds.lua 的 render）：
--
--  ①（2026-10-03，用户报 bug）上游 delver/state.lua 里的 lost_cursed 是**缓存值**，只在 M.check()
--     跑到末尾时才更新，而 state.check() 只挂在 MC_POST_NEW_ROOM 上 —— 于是「地图先完整显示过
--     （候选已算好）、之后才被塞进迷失诅咒（药丸 P25 / 道具）」时，诅咒状态一直停在 false，
--     长按 TAB 仍画出隐藏房候选，直到换一次房间（check() 重跑）才消失。改成**实时读取**诅咒位。
--
--  ②（2026-10-05，用户要求）与「迷失诅咒下能不能传送」保持同一口径：MinimapAPI 的 OverrideLost
--     （其 MCM 里的 "Display During Curse"）为真时地图照常显示 ⇒ 隐藏房候选标记与地图边界高亮
--     也不再藏。判据统一走 gt:curse_map_visible()（读的是同一份 MinimapAPI 配置）。
--
-- ⚠️ 因此本函数的**语义**已从「本层是否带迷失诅咒」收窄为「本层地图是否**因为迷失诅咒**而隐藏」
--    （诅咒生效 **且** MinimapAPI 没有强制显示）。改名会牵动上游 delver 文件，故沿用原名，
--    在这里说明。目前没有第三个消费点依赖它的「纯诅咒」语义。
state.is_lost_cursed = function()
  if gt.curse_map_visible and gt:curse_map_visible() then
    return false
  end
  local level = Game():GetLevel()
  return level ~= nil
    and (level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST) ~= 0
end

local function enabled()
  return gt:get_config_bool("ShowSecretMarkers", true)
end
require("scripts.gtp_delverlive")(gt, state, map, room, render, enabled)

-- 换房间：重算地图数据、做门位检查、标记需要刷新
--
-- ⚠️ 状态维护必须在开关闸门**之前**（2026-10-04 用户报的 bug）：
-- `state.has_changed` 初始为 true、换层时又会置回 true，唯一复位点是
-- `map.reload()` 末尾的 `state.done()`；而 reload 只在 room.door_check() 开头被调。
-- 旧代码把它整个放在 `enabled()` 之后，导致关掉 ShowSecretMarkers 时
-- has_changed 永久卡死 → `state.is_ignored()` 恒为 true →
-- 地图边界高亮（gtp_mapbounds.lua）读同一份 state，被它拦得永远不画。
-- 所以「层身份 / 维度 / has_changed 复位」这条共享状态链必须无条件跑；
-- 门位排除与候选刷新才是标记专属、留在闸门后。
gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
  state.check()
  if state.has_changed() then
    map.reload() -- 无条件维护共享状态（内部会 state.update + state.done）
  end
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
  render.update()
  render.tab_hold_check()
end)

-- 炸弹在门位附近爆炸 → 排除假候选
gt:AddCallback(ModCallbacks.MC_POST_EFFECT_INIT, function(_, effect)
  if not enabled() then
    return
  end
  local changed = room.bomb_check(effect)
  render.refresh()
  visibility.trace(function()
    return '[GTPdelver] bomb x=' .. tostring(effect.Position.X)
      .. ' y=' .. tostring(effect.Position.Y) .. ' excluded-fake=' .. tostring(changed)
      .. ' dimension=' .. tostring(state.get_dimension())
      .. ' ignored=' .. tostring(state.is_ignored()) .. ' refresh=true'
  end)
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
