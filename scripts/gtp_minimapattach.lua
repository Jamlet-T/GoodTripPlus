-- MiniMAPI 的名字决定模组加载顺序；在加载时和进入游戏时都尝试挂载。
local defaults = require('scripts.gtp_minimapdefaults')
local map_input = require('scripts.gtp_mapinput')
local combat_map = require('scripts.gtp_combatmap')
local distance = require('scripts.gtp_distancefix')
local shadows = require('scripts.gtp_boundedshadow')

return function(gt)
  local last_status, render_checked, menu_registered

  local function attach(phase, before_save_load)
    local api = MinimapAPI
    if api then
      if before_save_load then defaults(api) end
      map_input(gt, api)
      combat_map(gt, api)
      distance(api)
      shadows(api)
    end
    menu_registered = gt:register_menu()

    local status = string.format('ready=%s mapInputInstalled=%s nativeMapInputWrapped=%s slotApi=%s',
      tostring(api ~= nil), tostring(api ~= nil and api._gtpMapInputInstalled == true),
      tostring(api ~= nil and api._gtpNativeMapInputWrapped == true),
      tostring(Input ~= nil and type(Input.GetKeyboardDeviceId) == 'function'))
    if status ~= last_status then
      last_status = status
      pcall(function() Isaac.DebugString('[GTPminimap] phase=' .. phase .. ' ' .. status) end)
    end
  end

  local function on_render()
    local api = MinimapAPI
    if not (api and api.Config and type(api.GetConfig) == 'function') then return end
    if api ~= render_checked then
      render_checked = api
      attach('render', false)
    elseif not menu_registered and ModConfigMenu then
      menu_registered = gt:register_menu()
    end
  end

  attach('load', true)
  if gt.AddPriorityCallback then
    -- MiniMAPI 的 OnGameLoad 在 -201 合并存档；之后只补挂载，不再写出厂值。
    local before_minimap = -202
    gt:AddPriorityCallback(ModCallbacks.MC_POST_GAME_STARTED, before_minimap, function()
      attach('start', true)
    end)
    gt:AddPriorityCallback(ModCallbacks.MC_POST_RENDER, before_minimap, on_render)
  else
    gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function() attach('start', false) end)
    gt:AddCallback(ModCallbacks.MC_POST_RENDER, on_render)
  end
end
