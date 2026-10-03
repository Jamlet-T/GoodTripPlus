--[[
  GoodTripPlus - 大地图房间轮廓（黑边）修复
  ============================================================

  现象
  ----
  按住地图键（默认 TAB）展开的大地图，四周有一圈较厚的黑边；
  而点按 TAB 让大地图常驻时没有黑边。于是缩放过程中看不到黑边，
  缩放一结束黑边突然出现。

  根因（MinimapAPI 侧，已核实）
  ---------------------------
  那一圈黑边是 MinimapAPI 的**房间轮廓**（`RoomOutline` 精灵），不是本模组画的。
  它由 `MinimapAPI:renderRoomShadows()` 绘制，而这个函数开头就是一道很硬的门槛：

      function MinimapAPI:renderRoomShadows(useCutOff)
          if not (MinimapAPI:GetConfig("ShowShadows") and MinimapAPI:GetTransparency() == 1) then
              return
          end

  透明度**不正好等于 1** 就整段不画。于是两种大地图的表现分叉：

      * 常驻大地图：恒定 TransparencyLargeMap（本机 0.3）→ 门槛不通过 → 没有轮廓
      * 按住大地图：LargeMapFadeInOnHold 会在几帧内把透明度从 0.3 抬到 1，
        所以渐显期间没有轮廓，**抬到 1 的那一帧起轮廓突然开始画** → 黑边「突然出现」

  也就是说：它和之前那个「未探索隐藏房在放大时闪白」是**同一道 `== 1` 门槛的两种表现**。
  轮廓本身的颜色来自 `DefaultOutlineColorR/G/B`（本机为 0,0,0，纯黑），
  可在 MinimapAPI 菜单的 "Outline Color Red/Green/Blue" 里改；
  总的开关是 "Show Room Outlines"（对应 `ShowShadows`）。

  为什么轮廓看起来是「一圈」而不是「每个房间一圈」
  ----------------------------------------------
  `renderRoomShadows` 在**画房间本体之前**被调用（main.lua:1879），所以房间会盖住轮廓
  的内侧部分：相邻房间互相覆盖后，只有整张地图外缘那一圈轮廓还露在外面。

  本模组的处理
  ----------
  让大地图的表现与常驻状态保持一致：**大地图不再绘制房间轮廓**。
  做法是把 `MinimapAPI.renderRoomShadows` 包一层，`MinimapAPI:IsLarge()`（按住或常驻
  的大地图都算）为真时直接跳过。小地图不经过这条分支，观感完全不变。

  为什么用包装而不是改 MinimapAPI 的文件
  ------------------------------------
  * 工坊内容会被 Steam 校验/更新还原（见 tools/minimapapi-patch.sh 的说明）；
  * 改动别人的文件会扩大「未授权上游代码」的面积，也影响将来只发布自有模块的可行性。

  接线时机
  -------
  本模组目录名 `goodtripplus` 按字母序排在 `minimapi` 之前，**加载时 `MinimapAPI`
  这个全局还不存在**，所以不能在这里直接包。改为在 `MC_POST_UPDATE` 里懒接管
  （每帧检查一次，接管后立即置位不再检查）。

  诊断：控制台 `gtpdiag` 会附带 `mapOutline.*`。
]]--

local GTP_OUTLINE = {}

local stats = {
  wrapped = false,         -- 是否已经接管 MinimapAPI.renderRoomShadows
  skipped = 0,             -- 累计跳过的轮廓绘制次数（大地图每帧一次）
  last_result = "尚未接管",
}

local function log(message)
  if gt.DebugMod then
    Isaac.ConsoleOutput("[GoodTripPlus] " .. message .. "\n")
    Isaac.DebugString("[GoodTripPlus] " .. message)
  end
end

--[[
  大地图判定：MinimapAPI:IsLarge() 对「按住地图键」和「大地图常驻」都返回真，
  所以这里用它区分大小地图，正好覆盖需求里的两种情况。
]]--
local function is_large_map()
  return MinimapAPI ~= nil and type(MinimapAPI.IsLarge) == "function" and MinimapAPI:IsLarge()
end

local function try_wrap()
  if stats.wrapped then
    return true
  end
  if type(MinimapAPI) ~= "table" or type(MinimapAPI.renderRoomShadows) ~= "function" then
    return false
  end

  local original = MinimapAPI.renderRoomShadows
  MinimapAPI.renderRoomShadows = function(self, use_cutoff)
    if is_large_map() then
      stats.skipped = stats.skipped + 1
      if stats.skipped == 1 then
        stats.last_result = "已跳过大地图的房间轮廓绘制"
        log("轮廓修复：大地图不再绘制房间轮廓")
      end
      return
    end
    return original(self, use_cutoff)
  end

  stats.wrapped = true
  if stats.skipped == 0 then
    stats.last_result = "已接管（大地图尚未打开过）"
  end
  log("轮廓修复：已接管 MinimapAPI.renderRoomShadows")
  return true
end

gt:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
  try_wrap()
end)

gt:AddCallback(ModCallbacks.MC_EXECUTE_CMD, function(_, command)
  if not command or command:lower() ~= "gtpdiag" then
    return
  end
  local lines = {}
  lines[#lines + 1] = "mapOutline.wrapped=" .. tostring(stats.wrapped) ..
    " isLarge=" .. tostring(is_large_map()) ..
    " skipped=" .. stats.skipped
  lines[#lines + 1] = "mapOutline.lastResult=" .. stats.last_result
  lines[#lines + 1] = "mapOutline.minimapShowRoomOutlines=" ..
    tostring(MinimapAPI ~= nil and MinimapAPI.Config ~= nil and MinimapAPI.Config.ShowShadows)
  return table.concat(lines, "\n")
end)

GTP_OUTLINE.stats = stats
return GTP_OUTLINE
