-- 传送光标颜色预设（纯数据，可独立加载）。
-- 白色箭头贴图按乘法着色：预设选亮色，避免结果偏暗；alpha 仍由淡入控制。
local M = {}
-- 1 = 默认白色；顺序与 MCM 的显示标签一一对应。
M.COLORS = {
  {1, 1, 1},        -- White
  {1, 0.35, 0.35},  -- Red
  {1, 0.65, 0.25},  -- Orange
  {1, 1, 0.45},     -- Yellow
  {0.45, 1, 0.55},  -- Green
  {0.45, 1, 1},     -- Cyan
  {0.55, 0.7, 1},   -- Blue
  {0.8, 0.55, 1},   -- Purple
  {1, 0.55, 0.8},   -- Pink
}
function M.count()
  return #M.COLORS
end
-- 越界或非数字一律回落到默认白色。
function M.get(index)
  return M.COLORS[tonumber(index) or 1] or M.COLORS[1]
end
return M
