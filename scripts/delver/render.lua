---@module "scripts.delver.render"
-- GoodTripPlus 版渲染：移植自 Lazy Delver 的 render.lua（MIT，见同目录 LICENSE-lazy-delver.txt）。
--
-- 与原版唯一的实质差别：**不再自己推算地图坐标**。
-- Lazy Delver 原来用 `update_pos_origin()` 按「游戏 RoomDescriptor.DisplayFlags」自己算锚点，
-- 而 MinimapAPI 画地图时用的是它自己的房间对象标志（GetDisplayFlags()），两者在边缘房间上会不一致，
-- 于是整张地图的锚点平移一格，标记就整体错位。
-- 这里直接复用 GoodTripPlus 的 gt:gid_to_rtmap_pos(cid) —— 那是传送光标用的同一套投影，
-- 逐项复刻了 MinimapAPI 的布局数学（含镜像世界的负缩放），因此与地图必然对齐。

local C = require("scripts.delver.const")
local geo = require("scripts.delver.geometry")
local log = require("scripts.delver.log")
local state = require("scripts.delver.state")
local map = require("scripts.delver.map")

local M = {}

local need_refresh = false

local TAB_HOLD_THRESHOLD = 3
local TAB_HOLD_MAX = 9
local tab_hold_cnt = -TAB_HOLD_THRESHOLD

local marker_sprite = Sprite()
marker_sprite:Load("gfx/goodtripplus/marker.anm2", true)
marker_sprite:SetFrame(marker_sprite:GetDefaultAnimation(), 1)


local function check_real_and_clear_fake()
  local rooms = Game():GetLevel():GetRooms()

  for _, secret_type in pairs(C.SECRET_TYPE) do
    local all_found = true
    for _, cand in pairs(map.candidates) do
      local lid = cand.lid
      if lid ~= nil and state.get_dimension() == C.DIMENSION.MIRROR then
        lid = map.rooms[lid].mirror_lid or lid
      end
      if lid ~= nil and cand.secret_type == secret_type then
        local desc = rooms:Get(lid)
        if desc and desc.DisplayFlags == 0 then
          all_found = false
        elseif secret_type ~= C.SECRET_TYPE.ULTRA then
          map.clear_fake_neighbors(lid)
        end
      end
    end

    if all_found then
      for cid, cand in pairs(map.candidates) do
        if cand.secret_type == secret_type then
          if cand.lid == nil then
            map.candidates[cid] = nil
          else
            cand.marker_status = C.MARKER.STATUS.FOUND
          end
        end
      end
    end
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
      if desc and desc.DisplayFlags ~= 0 then
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
    tab_hold_cnt = math.min(tab_hold_cnt + 1, TAB_HOLD_MAX)
  else
    tab_hold_cnt = math.max(tab_hold_cnt - 2, -TAB_HOLD_THRESHOLD)
  end
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

function M.render()
  if state.is_ignored() then return end

  if state.is_lost_cursed() or state.is_off_grid() then return end

  if tab_hold_cnt <= 0 then return end

  if not gt:get_config_bool("ShowSecretMarkers", true) then return end

  if not MinimapAPI then return end

  if need_refresh then refresh() end

  local show_red = state.can_see_red()

  for cid, cand in pairs(map.candidates) do
    if not show_red and cand.secret_type == C.SECRET_TYPE.ULTRA then
      goto continue
    end
    if cand.marker_status == C.MARKER.STATUS.HIDDEN or
       cand.marker_status == C.MARKER.STATUS.FOUND then
      goto continue
    end

    -- 与传送光标共用同一套投影，保证与 MinimapAPI 的地图逐像素对齐
    local pos = gt:gid_to_rtmap_pos(cid)

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
