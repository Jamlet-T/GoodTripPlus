--[[
  GoodTripPlus - 战斗时隐藏小地图（可选，默认关闭）
  ============================================================

  需求：开启后，战斗（当前房间未清理）时右上角的小地图消失；
  按住地图键（默认 TAB）仍然能唤起大地图，传送光标与各类标记照常可用。

  为什么不用 MinimapAPI 自带的 "Hide Map in Combat"
  -----------------------------------------------
  MinimapAPI 的确自带一个 `HideInCombat`（1=Never / 2=Bosses Only / 3=Always），但它的实现是
  在渲染回调开头直接 `return`，也就是**整块都不画**——包括按住 TAB 时的大地图。
  而这里要的行为是「小图藏起来、大地图照常」，所以不能用它。

  这里的做法：只覆盖小地图的透明度
  --------------------------------
  MinimapAPI 的所有绘制都通过 `MinimapAPI:GetTransparency()` 取透明度，而这个函数是**分模式**的
  （main.lua）：
      if MinimapAPI:IsLarge() then  -- 按住地图键时 mapheldframes > 0
          -- 大地图：Options.MapOpacity 或 TransparencyLargeMap（还有渐显）
      end
      return MinimapAPI:GetConfig("TransparencySmallMap")   -- 小地图
  而 `GetConfig` 会优先读运行时覆盖表：
      return MinimapAPI.OverrideConfig[option] ~= nil and MinimapAPI.OverrideConfig[option]
             or MinimapAPI.Config[option]

  所以把 `OverrideConfig.TransparencySmallMap` 设成 0，就等于「小地图整体不可见」
  （房间底色、房间图标、地图边框、地图标志全都用这个值当 alpha），
  而按住地图键切到大地图时用的是另一个键，**完全不受影响**。
  好处：
    * 不修改玩家在 MinimapAPI 里的配置（OverrideConfig 只在内存里，退出即还原）；
    * 不接管任何渲染、不和 MinimapAPI 抢回调，天然不会画坏别的东西。

  已知的小瑕疵（MinimapAPI 自身的问题，不去动它）
  ----------------------------------------------
  受「迷失诅咒」时它会在小地图位置画一个问号（`MinimapAPI:renderQuestionMark`），
  那处绘制没有设置颜色、不经过 GetTransparency，所以开启本功能后那个问号可能仍会显示。

  诊断：控制台 `gtpdiag` 会附带 `combatMap.*`。
]]--

local GTP_COMBAT = {}

local CONFIG_KEY = "HideMinimapInCombat"

-- MinimapAPI 里「小地图透明度」的配置键
local TRANSPARENCY_KEY = "TransparencySmallMap"

local override_active = false

local stats = {
  in_combat = false,
  overrides = 0,          -- 进入「战斗中」状态的次数
  last_result = "尚未触发",
}

local function log(message)
  if gt.DebugMod then
    Isaac.ConsoleOutput("[GoodTripPlus] " .. message .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. message)
  end
end

local function is_enabled()
  return gt:get_config_bool(CONFIG_KEY, false)
end

-- 与 MinimapAPI 的 "Always" 同义：当前房间还没清理干净
local function in_combat()
  local room = Game():GetRoom()
  return room ~= nil and not room:IsClear()
end

local function minimap_ready()
  return MinimapAPI ~= nil and MinimapAPI.OverrideConfig ~= nil and MinimapAPI.GetConfig ~= nil
end

local function update()
  if not minimap_ready() then return end

  local combat = in_combat()
  stats.in_combat = combat

  -- 只覆盖「小地图」这一项；大地图读的是另一个键，不受影响
  if is_enabled() and combat then
    if MinimapAPI.OverrideConfig[TRANSPARENCY_KEY] == 0 then
      override_active = true
      return
    end
    MinimapAPI.OverrideConfig[TRANSPARENCY_KEY] = 0
    override_active = true
    stats.overrides = stats.overrides + 1
    stats.last_result = "战斗中已隐藏小地图（第 " .. stats.overrides .. " 次）"
    log("战斗隐藏：已隐藏小地图（TransparencySmallMap 覆盖为 0）")
  elseif override_active then
    -- 战斗结束或功能被关掉：撤掉覆盖，回到玩家自己的配置
    MinimapAPI.OverrideConfig[TRANSPARENCY_KEY] = nil
    override_active = false
    stats.last_result = "已恢复小地图（覆盖已撤销）"
    log("战斗隐藏：已恢复小地图")
  end
end

gt:AddCallback(ModCallbacks.MC_POST_UPDATE, update)

--[[
  我们自己的绘制也要让路
  ----------------------
  MinimapAPI 的元素都跟着 GetTransparency 走，但**本模组自己画的**不受影响。
  目前我们只有一处是无条件绘制的：
    gtrep.lua 的 `gt:render_map_highlights()` —— 初始房间的绿色高亮，
    它由 `gt:render_cursor()` 每帧调用，没有按键门控（光标和隐藏房标记都有，
    见 gtrep.lua 的 `if mmp_ctrl then` 与 delver/render.lua 的 ACTION_MAP 判定）。
  所以这里把它包一层：小地图被隐藏、且玩家没在看大地图时直接跳过。
  用包装而不是去改 gtrep.lua，是为了让「战斗隐藏」这件事的代码集中在本模块里。
]]--
local function small_map_is_hidden()
  if not override_active then
    return false
  end
  -- 按住地图键时 MinimapAPI 画的是大地图（用的是另一个透明度键），此时高亮照常显示
  if MinimapAPI and MinimapAPI.IsLarge and MinimapAPI:IsLarge() then
    return false
  end
  return true
end

if gt and type(gt.render_map_highlights) == "function" then
  local original_render_map_highlights = gt.render_map_highlights
  gt.render_map_highlights = function(self, ...)
    if small_map_is_hidden() then
      return
    end
    return original_render_map_highlights(self, ...)
  end
end

gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
  if not command or command:lower() ~= "gtpdiag" then
    return
  end
  local lines = {}
  lines[#lines + 1] = "combatMap.enabled=" .. tostring(is_enabled()) ..
    " inCombat=" .. tostring(stats.in_combat) ..
    " hidden=" .. tostring(override_active) ..
    " smallMapHidden=" .. tostring(small_map_is_hidden())
  lines[#lines + 1] = "combatMap.overrides=" .. stats.overrides ..
    " lastResult=" .. stats.last_result
  lines[#lines + 1] = "combatMap.overrideValue=" ..
    tostring(MinimapAPI and MinimapAPI.OverrideConfig and MinimapAPI.OverrideConfig[TRANSPARENCY_KEY])
  return table.concat(lines, "\n")
end)

GTP_COMBAT.stats = stats
return GTP_COMBAT
