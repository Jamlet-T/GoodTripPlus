-- 来源：gtrep.lua:1782-1978；只负责菜单注册，不挂游戏生命周期回调。
local get_strings = require("scripts.gtp_locale")
return function(gt)
  local mcm_registered = false
  function gt:register_menu()
  if not mcm_registered and ModConfigMenu then
    mcm_registered = true
    local L = get_strings(Options.Language)
    ModConfigMenu.AddTitle("GoodTripPlus", nil, L.title)
    -- ⚠️ 菜单顺序 = 下面这些注册调用的书写顺序（MCM 无脑 append）。
    -- 2026-10-04 起全部 MCM 项集中在这里按序注册（用户指定的顺序），
    -- 各功能模块（gtp_mapbounds / gtp_minebuttons / gtp_delirium 等）
    -- 不再各自注册 MCM 项，只留配置键说明。
    -- 顺序：光标 → 传送行为（Fixed 系）→ 显示类 → 房间标记类。
    ModConfigMenu.AddNumberSetting(
      "GoodTripPlus", nil,
      "CursorSpeed",
      1, 5, 0.25, 2,
      L.cursor_speed_name,
      L.cursor_speed_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "CursorGridStep",
      false,
      L.cursor_grid_step_name,
      L.cursor_grid_step_desc
    )
    ModConfigMenu.AddNumberSetting(
      "GoodTripPlus", nil,
      "TravelMode",
      1, 3, 1, 2,
      L.travel_mode_name,
      L.travel_mode_values,
      function()
        return L.travel_mode_desc[gt:get_travel_mode()] or L.travel_mode_desc[2]
      end
    )
    -- 「禁止传送进诅咒房」= 恢复移植基底（MLX's Tweak）的同名选项（变量 gt.BlockCurseRoom，
    -- 默认开；现行 GoodTrip [Fixed] 2.2.58 已无此项，它靠 check_neigh_connected 的类型白名单
    -- 把诅咒房排除）。早期移植时把这一条连开关一起删了，导致已探索过的诅咒房能被直接传送进去
    -- （2026-10-05 用户报的 bug）。消费点：scripts/gtp_curseblock.lua（拦住目标）+
    -- 本文件 check_neigh_connected 的白名单（放行类型 10）。
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "BlockCurseRoom",
      true,
      L.block_curse_name,
      L.block_curse_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "FairTripPath",
      true,
      L.fairpath_name,
      L.fairpath_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "ArriveAtDoor",
      true,
      L.arrivedoor_name,
      L.arrivedoor_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "FairTripTime",
      false,
      L.fairtime_name,
      L.fairtime_desc
    )
    ModConfigMenu.AddNumberSetting(
      "GoodTripPlus", nil,
      "TeleportTransition",
      1, 3, 1, 2,
      L.transition_name,
      L.transition_values,
      L.transition_desc
    )
    -- 「迷失诅咒下显示地图」= 代理 MinimapAPI 的 OverrideLost（它的菜单里叫 "Display During Curse"，
    -- 默认关）。这一项同时决定迷失诅咒期间能否传送（见 gt:curse_map_visible() 与
    -- gtp_travel 的 departure.lost_curse 规则）：
    -- 地图照常显示 → 传送照常；地图被诅咒藏起来 → 传送也停用。
    -- 同样是纯代理（只读写 MinimapAPI.Config，不另存值）；注意 MinimapAPI 自己那一项没有改 ConfigPreset
    -- 的动作，这里也不加，行为与它完全一致。
    if MinimapAPI and MinimapAPI.Config then
      ModConfigMenu.AddSetting(
        "GoodTripPlus", nil,
        {
          Type = ModConfigMenu.OptionType.BOOLEAN,
          Default = false,
          CurrentSetting = function()
            return MinimapAPI.Config.OverrideLost == true
          end,
          Display = function()
            return L.curse_display_name .. ": " ..
              (MinimapAPI.Config.OverrideLost == true and "ON" or "OFF")
          end,
          OnChange = function(newVal)
            MinimapAPI.Config.OverrideLost = newVal and true or false
          end,
          Info = L.curse_display_desc,
        }
      )
    end
    -- HighlightCursorRoom 不注册 MCM 菜单项（2026-10-04 用户决定）：默认常开，仅可在 gtconfig.lua 覆盖。
    -- （FastTransition 原先是同一批，2026-10-05 起已并入上面的「传送过场」三选一项。）
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "ShowSecretMarkers",
      true,
      L.secret_markers_name,
      L.secret_markers_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "ShowMapBounds",
      true,
      L.map_bounds_name,
      L.map_bounds_desc
    )
    -- 以下两项 = **代理** MinimapAPI 自己的设置（不是我们自己的配置项）：
    -- 值只存在 MinimapAPI.Config 里，所以用 MCM 的自定义设置表（CurrentSetting 读、OnChange 写），
    -- 而不是 AddBooleanSetting / AddNumberSetting（那些会往 ModConfigMenu.Config 里另存一份，
    -- 两边就会各说各话）。读写同一份 MinimapAPI.Config = 与 MinimapAPI 自己菜单里那一项天然双向同步
    -- （在它那边改，这边也变），存档也照旧由 MinimapAPI 自己 SaveData 保存。
    -- 结构照抄 MinimapAPI config_menu.lua 的对应项（布尔：Type/Default/CurrentSetting/Display/OnChange/Info；
    -- 数字：再加 Minimum/Maximum/ModifyBy —— 注意这几个字段是首字母大写）。
    if MinimapAPI and MinimapAPI.Config then
      -- ①「高亮初始房间」→ MinimapAPI 的 HighlightStartRoom
      ModConfigMenu.AddSetting(
        "GoodTripPlus", nil,
        {
          Type = ModConfigMenu.OptionType.BOOLEAN,
          Default = false,
          CurrentSetting = function()
            return MinimapAPI.Config.HighlightStartRoom == true
          end,
          Display = function()
            return L.highlight_start_name .. ": " ..
              (MinimapAPI.Config.HighlightStartRoom == true and "ON" or "OFF")
          end,
          OnChange = function(newVal)
            MinimapAPI.Config.HighlightStartRoom = newVal and true or false
            -- 与 MinimapAPI 自己那份菜单的处理一致：改了就变成「自定义」配置（预设 0）
            if MinimapAPI.Config.ConfigPreset ~= nil then
              MinimapAPI.Config.ConfigPreset = 0
            end
          end,
          Info = L.highlight_start_desc,
        }
      )
      -- ②「战斗时隐藏地图」→ MinimapAPI 的 HideInCombat（1 从不 / 2 仅 Boss 房 / 3 总是，出厂默认 1）
      ModConfigMenu.AddSetting(
        "GoodTripPlus", nil,
        {
          Type = ModConfigMenu.OptionType.NUMBER,
          Minimum = 1,
          Maximum = 3,
          ModifyBy = 1,
          Default = 1,
          CurrentSetting = function()
            return MinimapAPI.Config.HideInCombat or 1
          end,
          Display = function()
            local v = MinimapAPI.Config.HideInCombat or 1
            return L.hide_combat_name .. ": " .. (L.hide_combat_values[v] or tostring(v))
          end,
          OnChange = function(newVal)
            MinimapAPI.Config.HideInCombat = newVal
            if MinimapAPI.Config.ConfigPreset ~= nil then
              MinimapAPI.Config.ConfigPreset = 0
            end
          end,
          Info = L.hide_combat_desc,
        }
      )
    end
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "CombatKeepLargeMap",
      false,
      L.combat_keep_large_name,
      L.combat_keep_large_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "FoolsSkullRoom",
      true,
      L.fools_skull_name,
      L.fools_skull_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "MineButtonRoom",
      true,
      L.minebutton_name,
      L.minebutton_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "DeliriumRoom",
      false,
      L.delirium_name,
      L.delirium_desc
    )
    -- 调试模式（诊断用，默认关）：读配置的 gt:is_debug() 每帧实时取，勾掉立刻生效。
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", nil,
      "DebugMod",
      false,
      L.debug_name,
      L.debug_desc
    )
  end
  end
end
