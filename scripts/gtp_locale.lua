-- 来源：gtrep.lua:1680-1780（2026-10-07 提取，语言行为保持不变）。
-- Mod Config Menu text, localized based on the game's language setting
-- (Options.Language). Anything not explicitly recognized falls back to
-- English.
local GT_STRINGS = {
  en = {
    title = "GoodTripPlus",
    cursor_speed_name = "Cursor Speed",
    mouse_teleport_name = "Mouse Teleport",
    mouse_teleport_desc = "Follow the mouse and left-click to teleport while holding the map key. Disabling this keeps keyboard/controller teleport available. Default: enabled",
    cursor_speed_desc = "Pixels the cursor moves per frame. Default: 2",
    cursor_grid_step_name = "Move One Grid Cell at a Time",
    cursor_grid_step_desc = "Each direction press moves one 1x1 room cell. Hold does not repeat. Ignores Cursor Speed; mouse movement is unchanged. Default: disabled",
    curse_display_name = "Display During Curse",
    curse_display_desc = "Mirrors MinimapAPI's setting. Default: disabled. Teleport is available only while the map is shown",
    travel_mode_name = "Can Teleport To",
    travel_mode_values = {[1] = "Any Room", [2] = "Neighbor Room", [3] = "Explored Rooms"},
    travel_mode_desc = {
      [1] = "Teleport at any time to any selectable map room. Severely disrupts game balance; enable with caution. Ignores connected-room restrictions and Fair Trip Time.",
      [2] = "Teleport to explored, cleared rooms or selectable rooms connected to an explored, cleared neighbor by a passage. Connected-room restrictions still apply when enabled. Default mode.",
      [3] = "Teleport only to explored, cleared rooms. Unexplored neighbors are excluded. Connected-room restrictions still apply when enabled.",
    },
    block_curse_name = "Block Curse Room Teleport",
    block_curse_desc = "Cannot teleport into Curse Rooms (they damage you on entry/exit). Default: enabled",
    transition_name = "Teleport Transition",
    transition_values = {[2] = "Fade", [3] = "Teleport Effect"},
    transition_desc = "Fade or Teleport effect. Default: Fade",
    fairpath_name = "Only Teleport to Connected Rooms",
    auto_unlock_name = "Auto Spend Items to Unlock Adjacent Doors and Teleport",
    auto_unlock_desc = "Spend keys or coins to open adjacent doors and teleport. Requires enough resources. Default: disabled",
    fairpath_desc = "Require a route through explored, cleared rooms. Ignored in Any Room mode. Turning this off removes the reachability restriction; Fair Trip Time does not restrict entry. Default: enabled",
    arrivedoor_name = "Arrive At Door",
    arrivedoor_desc = "Arrive standing at the exact door a walk would have come in by. Default: enabled",
    fairtime_name = "Fair Trip Time",
    fairtime_desc = "Add time based on a walkable route through explored, cleared rooms and player speed. With no route, add no time; this option never restricts entry. Ignored in Any Room mode. Default: disabled",
    secret_markers_name = "Secret Room Candidate Markers",
    secret_markers_desc = "Marks where Secret / Super Secret / Ultra Secret rooms could be. Default: enabled",
    fools_skull_name = "Mark The Fool Skull Room",
    fools_skull_desc = "Default: enabled",
    map_bounds_name = "Show Map Bounds",
    map_bounds_desc = "Default: enabled",
    highlight_start_name = "Highlight Start Room",
    highlight_start_desc = "Mirrors MinimapAPI's setting. Default: disabled",
    hide_combat_name = "Hide Map in Combat",
    hide_combat_values = {[1] = "Never", [2] = "Bosses Only", [3] = "Always"},
    hide_combat_desc = "Mirrors MinimapAPI's setting. Default: Never",
    combat_keep_large_name = "Keep Large Map in Combat",
    combat_keep_large_desc = "Only hide the small map when combat hiding applies. Hold the map button to show the large map. Default: OFF. MinimapAPI cutscene and special fight restrictions still apply.",
    delirium_name = "Mark the Delirium Room in The Void",
    delirium_desc = "Default: disabled",
    minebutton_name = "Mark the Rail Button Rooms in Mines II",
    minebutton_desc = "Default: enabled",
    debug_name = "Debug Mode",
    debug_desc = "Diagnostics only; never changes teleporting. Keep it off for normal play. Default: disabled",
  },
  zh_hans = {
    title = "GoodTripPlus",
    cursor_speed_name = "光标速度",
    mouse_teleport_name = "鼠标传送",
    mouse_teleport_desc = "按住地图键时让光标跟随鼠标，并用左键点击传送。关闭后仍可用键盘/手柄传送。默认开启",
    cursor_speed_desc = "光标每帧移动的像素数。默认值：2",
    cursor_grid_step_name = "每次移动一格",
    cursor_grid_step_desc = "每次按方向键移动一个1x1房间格距，长按不重复。不使用光标速度，鼠标移动不受影响。默认关闭",
    curse_display_name = "迷失诅咒下显示地图",
    curse_display_desc = "代理 MinimapAPI 对应设置。默认关。只在显示地图时可传送。",
    travel_mode_name = "可以传送到",
    travel_mode_values = {[1] = "任意房间", [2] = "相邻房间", [3] = "已探索房间"},
    travel_mode_desc = {
      [1] = "任意时刻传送至任意房间，极大破坏游戏平衡，请谨慎启用。此模式忽略连通限制与按距离增加游戏时间。",
      [2] = "可传送至已探索且已清怪的房间，以及与已探索、已清怪房间存在通路的地图可选房间。开启连通限制时，目标还需从当前房间可达。默认模式。",
      [3] = "仅可传送至已探索且已清怪的房间，不包含尚未探索的相邻房间。开启连通限制时，目标还需从当前房间可达。",
    },
    block_curse_name = "禁止传送进诅咒房",
    block_curse_desc = "开启后不能传送进会在进出时扣血的诅咒房。默认开启。",
    transition_name = "传送过场",
    transition_values = {[2] = "淡入淡出", [3] = "传送动画"},
    transition_desc = "淡入淡出 / 传送动画。默认：淡入淡出。",
    fairpath_name = "只能传送到已连通的房间",
    auto_unlock_name = "相邻房门自动消耗物品开门传送",
    auto_unlock_desc = "消耗钥匙或金币打开相邻房门后传送，资源不足无法传送。默认关闭。",
    fairpath_desc = "要求沿已探索、已清怪房间逐门抵达目标。关闭后不要求与当前房间连通，计时开关不会限制准入。任意房间模式下不生效。默认开启。",
    arrivedoor_name = "传送后站在门口",
    arrivedoor_desc = "传送到走路会走进来的那扇门门口。默认开启。",
    fairtime_name = "按距离增加游戏时间",
    fairtime_desc = "按经过已探索、已清怪房间的可步行路线长度和玩家移速补回游戏时间。有路线则补时，无路线则不补时，不影响能否传送。任意房间模式下不生效。默认关闭。",
    secret_markers_name = "显示隐藏房候选标记",
    secret_markers_desc = "按住地图键时标出隐藏房 / 超级隐藏房 / 究极隐藏房的可能位置。默认开启。",
    fools_skull_name = "标记深牢 II 的愚者骷髅房",
    fools_skull_desc = "默认开启。",
    map_bounds_name = "显示地图边界",
    map_bounds_desc = "默认开启。",
    highlight_start_name = "高亮初始房间",
    highlight_start_desc = "代理 MinimapAPI 对应设置。默认关。",
    hide_combat_name = "战斗时隐藏地图",
    hide_combat_values = {[1] = "从不", [2] = "仅 Boss 房", [3] = "总是"},
    hide_combat_desc = "代理 MinimapAPI 对应设置。默认：从不。",
    combat_keep_large_name = "战斗时保留大地图",
    combat_keep_large_desc = "战斗隐藏生效时仅隐藏小地图，长按地图键（默认 Tab）仍可呼出大地图。默认关闭。MinimapAPI 的过场与特殊战斗隐藏限制仍生效。",
    delirium_name = "标记虚空层的精神错乱房",
    delirium_desc = "默认关闭。",
    minebutton_name = "标记矿洞 II 的轨道按钮房",
    minebutton_desc = "默认开启。",
    debug_name = "调试模式",
    debug_desc = "所有调试信息的总开关，只出诊断、不影响传送。正常游玩请关闭。默认关闭。",
  },
}
-- A few plausible spellings/casings for each supported language, since the
-- exact string Options.Language returns can vary by game version/branch.
local GT_LANG_ALIASES = {
  zh_hans = { "zh", "zh_hans", "zh-hans", "zh_cn", "zh-cn", "zh_chs", "chinese_s", "chi_s" },
}
local function get_strings(raw)
  if type(raw) == "string" then
    local lang = raw:lower()
    for code, aliases in pairs(GT_LANG_ALIASES) do
      for _, alias in ipairs(aliases) do
        if lang == alias then
          return GT_STRINGS[code]
        end
      end
    end
  end
  return GT_STRINGS.en
end
return get_strings
