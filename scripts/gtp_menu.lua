-- 来源：gtrep.lua:1782-1978；只负责菜单注册，不挂游戏生命周期回调。
local get_strings = require("scripts.gtp_locale")
return function(gt)
  local mcm_registered = false
  function gt:register_menu()
  if not mcm_registered and ModConfigMenu then
    mcm_registered = true
    local L = get_strings(Options.Language)
    -- 保留旧存档的 2/3 编号；已删除的值 1（立即出现）和 4（复得游魂修复档）都迁移为 2。
    if gt.TeleportTransition == 1 or gt.TeleportTransition == 4 then gt.TeleportTransition = 2 end
    local saved = ModConfigMenu.Config and ModConfigMenu.Config["GoodTripPlus"]
    if saved and (saved.TeleportTransition == 1 or saved.TeleportTransition == 4) then
      saved.TeleportTransition = 2
    end
    local tab = L.tabs.mapping
    local function begin_tab(name)
      tab = name
      ModConfigMenu.AddTitle("GoodTripPlus", tab, L.title)
    end
    begin_tab(L.tabs.mapping)
    -- ⚠️ 菜单顺序 = 下面这些注册调用的书写顺序（MCM 无脑 append）。
    -- 全部 MCM 项集中在这里按功能子页注册，子页内保留原有相对顺序。
    -- 各功能模块（gtp_mapbounds / gtp_minebuttons / gtp_delirium 等）
    -- 不再各自注册 MCM 项，只留配置键说明。
    -- 顺序：映射 → 光标 → 传送设置 → 地图显示 → 房间标记 → 调试。
    local function add_map_key_setting(key, kind, name, info, labels)
      local controller_setting=kind==ModConfigMenu.OptionType.KEYBIND_CONTROLLER
      local function capture_shoulder()
        if not Input or not Input.IsButtonTriggered then return nil end
        -- 显式取消优先；绑定弹窗沿用 MCM 扫描手柄的范围，排除键盘索引 0。
        for _,name in ipairs({'KEY_ESCAPE','KEY_BACKSPACE'}) do
          local button=Keyboard and Keyboard[name]
          if button and Input.IsButtonTriggered(button,0) then return nil end
        end
        for index=1,4 do
          if Input.IsButtonTriggered(5,index) then return nil end -- BUTTON_B
        end
        for index=1,4 do
          for _,button in ipairs({8,11}) do -- BUMPER_LEFT / BUMPER_RIGHT
            if Input.IsButtonTriggered(button,index) then return button,index end
          end
        end
      end
      local function current_binding()
        local config = ModConfigMenu.Config and ModConfigMenu.Config["GoodTripPlus"]
        local value = config and config[key]
        if value == nil then return -1 end
        if value == false then return -1 end
        return value
      end
      ModConfigMenu.AddSetting("GoodTripPlus", tab, {
        Type = kind,
        Default = -1,
        CurrentSetting = current_binding,
        Display = function()
          local value = current_binding()
          local label = (value == nil or value == false or value == -1)
            and L.map_key_fallback
            or (labels[value] or tostring(value))
          return name .. ": " .. label
        end,
        OnChange = function(value)
          local source = value == nil and 'clear' or 'assigned'
          local capture_index
          if value==nil and controller_setting then
            value,capture_index=capture_shoulder()
            if value~=nil then source='shoulder-capture' end
          end
          local config = ModConfigMenu.Config and ModConfigMenu.Config["GoodTripPlus"]
          if config then
            if value == nil then config[key] = -1 else config[key] = value end
            if Isaac and Isaac.DebugString then
              pcall(Isaac.DebugString, string.format('[GTPinput] binding key=%s value=%s source=%s controller=%s',
                key, tostring(config[key]), source, tostring(capture_index or '-')))
            end
          end
        end,
        PopupGfx = ModConfigMenu.PopupGfx and ModConfigMenu.PopupGfx.WIDE_SMALL,
        -- MCM 仅在有 OnSelect 时允许菜单确认动作进入按键捕获分支。
        -- KEYBIND_CONTROLLER 会先处理原始按钮，因此此函数无需执行操作。
        OnSelect = controller_setting and function() end or nil,
        PopupWidth = 280,
        Popup = function()
          return kind == ModConfigMenu.OptionType.KEYBIND_KEYBOARD
            and L.map_keyboard_key_popup or L.map_controller_key_popup
        end,
        Info = info,
      })
    end
    -- 保留 MCM 原生清空行为；未绑定时跟随对应设备的游戏地图动作。
    add_map_key_setting("MapKeyboardKey", ModConfigMenu.OptionType.KEYBIND_KEYBOARD,
      L.map_keyboard_key_name, L.map_keyboard_key_desc,
      InputHelper and InputHelper.KeyboardToString or {})
    add_map_key_setting("MapControllerKey", ModConfigMenu.OptionType.KEYBIND_CONTROLLER,
      L.map_controller_key_name, L.map_controller_key_desc,
      InputHelper and InputHelper.ControllerToString or {})
    begin_tab(L.tabs.cursor)
    ModConfigMenu.AddNumberSetting(
      "GoodTripPlus", tab,
      "CursorSpeed",
      1, 5, 0.25, 2,
      L.cursor_speed_name,
      L.cursor_speed_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "CursorGridStep",
      false,
      L.cursor_grid_step_name,
      L.cursor_grid_step_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "MouseTeleport",
      true,
      L.mouse_teleport_name,
      L.mouse_teleport_desc
    )
    begin_tab(L.tabs.travel)
    ModConfigMenu.AddNumberSetting(
      "GoodTripPlus", tab,
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
      "GoodTripPlus", tab,
      "BlockCurseRoom",
      true,
      L.block_curse_name,
      L.block_curse_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "AllowDevilAngelDoorTeleport",
      false,
      L.allow_devil_angel_name,
      L.allow_devil_angel_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "AllowRushHushDoorTeleport",
      false,
      L.allow_rush_hush_name,
      L.allow_rush_hush_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "FairTripPath",
      true,
      L.fairpath_name,
      L.fairpath_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "AutoUnlockAdjacent",
      false,
      L.auto_unlock_name,
      L.auto_unlock_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "ArriveAtDoor",
      true,
      L.arrivedoor_name,
      L.arrivedoor_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "FairTripTime",
      false,
      L.fairtime_name,
      L.fairtime_desc
    )
    ModConfigMenu.AddNumberSetting(
      "GoodTripPlus", tab,
      "TeleportTransition",
      2, 3, 1, 2,
      L.transition_name,
      L.transition_values,
      L.transition_desc
    )
    begin_tab(L.tabs.display)
    -- 「迷失诅咒下显示地图」= 代理 MinimapAPI 的 OverrideLost（它的菜单里叫 "Display During Curse"，
    -- 默认关）。这一项同时决定迷失诅咒期间能否传送（见 gt:curse_map_visible() 与
    -- gtp_travel 的 departure.lost_curse 规则）：
    -- 地图照常显示 → 传送照常；地图被诅咒藏起来 → 传送也停用。
    -- 同样是纯代理（只读写 MinimapAPI.Config，不另存值）；注意 MinimapAPI 自己那一项没有改 ConfigPreset
    -- 的动作，这里也不加，行为与它完全一致。
    if MinimapAPI and MinimapAPI.Config then
      ModConfigMenu.AddSetting(
        "GoodTripPlus", tab,
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
    -- （FastTransition 原先是同一批，2026-10-05 起已并入上面的「传送过场」两选一项。）
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
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
        "GoodTripPlus", tab,
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
        "GoodTripPlus", tab,
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
      "GoodTripPlus", tab,
      "CombatKeepLargeMap",
      false,
      L.combat_keep_large_name,
      L.combat_keep_large_desc
    )
    begin_tab(L.tabs.markers)
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "ShowSecretMarkers",
      true,
      L.secret_markers_name,
      L.secret_markers_desc
    )
    ModConfigMenu.AddNumberSetting(
      "GoodTripPlus", tab,
      "SingleNeighborSecretMode",
      1, 2, 1, 2,
      L.single_neighbor_secret_name,
      L.single_neighbor_secret_values,
      L.single_neighbor_secret_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "ShowSecretDoorOutlines",
      true,
      L.secret_outlines_name,
      L.secret_outlines_desc
    )
    ModConfigMenu.AddNumberSetting(
      "GoodTripPlus", tab,
      "SecretDoorOutlineOpacity",
      0, 100, 5, 100,
      L.secret_outlines_opacity_name,
      L.secret_outlines_opacity_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "DoorOutlinesDuringCurse",
      true,
      L.outlines_curse_name,
      L.outlines_curse_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "FoolsSkullRoom",
      true,
      L.fools_skull_name,
      L.fools_skull_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "MineButtonRoom",
      true,
      L.minebutton_name,
      L.minebutton_desc
    )
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "DeliriumRoom",
      false,
      L.delirium_name,
      L.delirium_desc
    )
    begin_tab(L.tabs.debug)
    -- 调试模式（诊断用，默认关）：读配置的 gt:is_debug() 每帧实时取，勾掉立刻生效。
    ModConfigMenu.AddBooleanSetting(
      "GoodTripPlus", tab,
      "DebugMod",
      false,
      L.debug_name,
      L.debug_desc
    )
  end
  end
end
