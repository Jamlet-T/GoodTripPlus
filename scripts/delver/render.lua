---@module "scripts.delver.render"
-- GoodTripPlus 版渲染：移植自 Lazy Delver 的 render.lua（MIT，见同目录 LICENSE-lazy-delver.txt）。
--
-- 与原版唯一的实质差别：**不再自己推算地图坐标**。
-- Lazy Delver 原来用 `update_pos_origin()` 按「游戏 RoomDescriptor.DisplayFlags」自己算锚点，
-- 而 MinimapAPI 画地图时用的是它自己的房间对象标志（GetDisplayFlags()），两者在边缘房间上会不一致，
-- 于是整张地图的锚点平移一格，标记就整体错位。
-- 这里直接复用 GoodTripPlus 的 gt:gid_to_rtmap_pos(cid) —— 那是传送光标用的同一套投影，
-- 逐项复刻了 MinimapAPI 的布局数学（含镜像世界的负缩放），因此与地图必然对齐。
--
-- 第二个差别：MinimapAPI 战斗隐藏（HideInCombat 等）生效时不画标记（见 minimapapi_hides_map）。

local C = require("scripts.delver.const")
local geo = require("scripts.delver.geometry")
local log = require("scripts.delver.log")
local state = require("scripts.delver.state")
local map = require("scripts.delver.map")
local visibility = require("scripts.gtp_delvervisibility")

local M = {}

local need_refresh = false

local TAB_HOLD_THRESHOLD = 3
local TAB_HOLD_MAX = 9
local tab_hold_cnt = -TAB_HOLD_THRESHOLD

local marker_sprite = Sprite()
marker_sprite:Load("gfx/goodtripplus/marker.anm2", true)
marker_sprite:SetFrame(marker_sprite:GetDefaultAnimation(), 1)

-- MinimapAPI 的「战斗时隐藏地图」（HideInCombat，外加几处无条件隐藏）是在它的
-- 渲染回调**开头直接 return**——条件命中时整块地图（含按住 TAB 的大地图）都不画。
-- 我们自己画的标记不在它的管辖范围，若不跟进，会出现「地图没了、标记浮在屏幕上」。
-- 下面把它的隐藏条件逐条镜像过来（minimapi 2.58，main.lua 渲染回调开头 2218-2244 行）。
local function minimapapi_hides_map()
  local game = Game()
  local gameroom = game:GetRoom()

  -- boss 开场过场动画
  if gameroom:GetFrameCount() == 0
  and gameroom:GetType() == RoomType.ROOM_BOSS
  and not gameroom:IsClear() then
    return true
  end
  -- Mega Satan 战（BossID: 55），无条件隐藏
  if gameroom:GetType() == RoomType.ROOM_BOSS and gameroom:GetBossID() == 55 then
    return true
  end
  -- Beast 战，无条件隐藏
  if MinimapAPI.isRepentance
  and gameroom:GetType() == RoomType.ROOM_DUNGEON
  and game:GetLevel():GetAbsoluteStage() == LevelStage.STAGE8 then
    return true
  end
  -- 玩家设置的战斗隐藏档位：2 = 未清理的 boss 房，3 = 任意未清理房间
  local hide_mode = MinimapAPI:GetConfig("HideInCombat")
  if hide_mode == 2 then
    if not gameroom:IsClear() and gameroom:GetType() == RoomType.ROOM_BOSS then
      return true
    end
  elseif hide_mode == 3 then
    if not gameroom:IsClear() then
      return true
    end
  end
  -- StageAPI 重实现的层间过场动画（仅当 MinimapAPI 走 MC_POST_HUD_RENDER 时存在）
  if MinimapAPI.UsingPostHUDRender and StageAPI and StageAPI.TransitionAnimationData
  and StageAPI.TransitionAnimationData.State == 2 then
    return true
  end
  return false
end

-- 暴露给本模组的其它模块：gtp_mapbounds.lua（地图边界高亮）也要在地图被隐藏时
-- 跟着藏，共用这一份镜像条件，避免两处各写一份将来走偏。
M.minimapapi_hides_map = minimapapi_hides_map


local function check_real_and_clear_fake()
  local rooms = Game():GetLevel():GetRooms()

  for _, secret_type in pairs(C.SECRET_TYPE) do
    local all_found = true
    local newly_found, removed = 0, 0
    for _, cand in pairs(map.candidates) do
      local lid = cand.lid
      if lid ~= nil and state.get_dimension() == C.DIMENSION.MIRROR then
        lid = map.rooms[lid].mirror_lid or lid
      end
      if lid ~= nil and cand.secret_type == secret_type then
        local desc = rooms:Get(lid)
        if not desc or visibility.flags(desc, state.get_dimension()) == 0 then
          all_found = false
          cand.marker_status = C.MARKER.STATUS.HIDDEN
        else
          -- 多隐藏房楼层：已发现的那个也立即隐藏自身标记，剩余候选仍需保留。
          if cand.marker_status ~= C.MARKER.STATUS.FOUND then newly_found = newly_found + 1 end
          cand.marker_status = C.MARKER.STATUS.FOUND
          if secret_type ~= C.SECRET_TYPE.ULTRA then map.clear_fake_neighbors(lid) end
        end
      end
    end

    if all_found then
      for cid, cand in pairs(map.candidates) do
        if cand.secret_type == secret_type then
          if cand.lid == nil then
            map.candidates[cid] = nil
            removed = removed + 1
          else
            cand.marker_status = C.MARKER.STATUS.FOUND
          end
        end
      end
    end
    if newly_found > 0 or removed > 0 then visibility.trace(function()
      return '[GTPdelver] reveal type=' .. secret_type .. ' dimension=' .. state.get_dimension()
        .. ' newly-found=' .. newly_found .. ' all-found=' .. tostring(all_found)
        .. ' removed-fake=' .. removed
    end) end
  end
end

local function clear_ultra_fake()
  for cid, cand in pairs(map.candidates) do
    if cand.secret_type ~= C.SECRET_TYPE.ULTRA then goto continue end
    if cand.lid then goto continue end

    local level = Game():GetLevel()
    for _, n_cid in pairs(geo.get_neighbors(cid)) do
      local n_desc = level:GetRoomByIdx(n_cid)
      if n_desc and n_desc.Data then
        map.candidates[cid] = nil
        break
      end
    end

    ::continue::
  end
end

local function update_marker()
  local rooms = Game():GetLevel():GetRooms()

  for _, cand in pairs(map.candidates) do
    if cand.marker_status == C.MARKER.STATUS.FOUND then
      goto continue
    end

    local any_visible = false
    local all_checked = true
    for _, entry in ipairs(cand.entries) do
      if not entry.checked then
        all_checked = false
      end

      local lid
      if state.get_dimension() == C.DIMENSION.MIRROR then
        lid = map.rooms[entry.source_lid].mirror_lid
      else
        lid = entry.source_lid
      end
      if not lid then
        log.error("room " .. entry.source_lid .. " should have a mirror lid")
        goto continue
      end

      local desc = rooms:Get(lid)
      if desc and visibility.flags(desc, state.get_dimension()) ~= 0 then
        any_visible = true
      end
    end

    if not any_visible then
      cand.marker_status = C.MARKER.STATUS.HIDDEN
    elseif not all_checked then
      cand.marker_status = C.MARKER.STATUS.DIM
    else
      cand.marker_status = C.MARKER.STATUS.BRIGHT
    end

    ::continue::
  end
end

function M.tab_hold_check()
  if state.is_ignored() then return end

  local controller_id = Isaac.GetPlayer(0).ControllerIndex
  if Input.IsActionPressed(ButtonAction.ACTION_MAP, controller_id) then
    -- 淡入保留：按住时逐帧 +1，直到 TAB_HOLD_MAX
    tab_hold_cnt = math.min(tab_hold_cnt + 1, TAB_HOLD_MAX)
  else
    -- 松开地图键**立即**归零（用户 2026-10-03 要求：不要淡出，松手就消失）。
    -- 直接跳到下限，而不是逐帧 -2；这样隐藏房标记与地图边界高亮一起瞬间消失。
    tab_hold_cnt = -TAB_HOLD_THRESHOLD
  end
end

-- 供本模组其它模块使用：地图边界高亮（gtp_mapbounds.lua）与隐藏房候选标记共用
-- **同一份**淡入节奏，所以直接读这里的计数，而不是自己再数一遍。
-- 返回淡入系数 [0, 1]；0 表示现在不该画（没按住地图键 / 还没淡入 / 层被忽略）。
function M.get_fade()
  if state.is_ignored() or tab_hold_cnt <= 0 then
    return 0
  end
  return tab_hold_cnt / TAB_HOLD_MAX
end

local function refresh()
  check_real_and_clear_fake()
  if state.can_see_entrance() or state.can_see_red() then
    local lid = Game():GetLevel():GetCurrentRoomDesc().ListIndex
    map.clear_fake_neighbors(lid)
  end
  clear_ultra_fake()
  update_marker()
  need_refresh = false
end

function M.refresh()
  if state.is_ignored() then return end
  need_refresh = true
end

-- 2.5.11：候选维护与 TAB/地图绘制分离。换房的排除证据必须在当前房
-- 消费，不能等下一次打开地图时才拿另一个房间的现场处理。
function M.update()
  if state.is_ignored() then return end
  if need_refresh then refresh() end
end

function M.render()
  -- PEFFECT/道具回调可能晚于 POST_UPDATE；在任何显示闸门前消费这一帧的新证据。
  M.update()
  if state.is_ignored() then return end

  if state.is_lost_cursed() or state.is_off_grid() then return end

  if tab_hold_cnt <= 0 then return end

  if not gt:get_config_bool("ShowSecretMarkers", true) then return end

  if not MinimapAPI then return end

  -- MinimapAPI 战斗隐藏生效中：地图整块没画，标记必须跟着藏
  if minimapapi_hides_map() then return end

  local show_red = state.can_see_red()
  local project

  for cid, cand in pairs(map.candidates) do
    if not show_red and cand.secret_type == C.SECRET_TYPE.ULTRA then
      goto continue
    end
    if cand.marker_status == C.MARKER.STATUS.HIDDEN or
       cand.marker_status == C.MARKER.STATUS.FOUND then
      goto continue
    end

    -- 与传送光标共用同一套投影，保证与 MinimapAPI 的地图逐像素对齐
    project = project or gt:make_rtmap_projector()
    local pos = project(cid)

    local colors = C.MARKER.COLORS[cand.secret_type]
    local alpha = C.MARKER.ALPHA[cand.marker_status]
    marker_sprite.Color = Color(
      colors[1], colors[2], colors[3],
      alpha * (tab_hold_cnt / TAB_HOLD_MAX),
      0, 0, 0
    )
    marker_sprite:Render(pos)

    ::continue::
  end
end

return M
