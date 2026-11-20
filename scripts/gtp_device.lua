-- 地图键的设备解析（纯函数，可独立加载）。
-- J460 及更早：键盘玩家的 ControllerIndex 是 0，0..3 都可能是手柄槽位；
-- J510 起：键盘玩家在 Lua 中得到的是无符号的 4294967294（即 int32 的 -2）。
-- 所以键盘判定必须跟随玩家自己的索引，不能硬编码 0；
-- 手柄绑定只对真实槽位（有符号后 >0）生效，负索引/无符号大数都不是手柄。
local M = {}
local UINT32 = 4294967296
local SIGN_BIT = 2147483648
local function signed(v)
  if type(v) ~= "number" then return nil end
  if v >= SIGN_BIT then return v - UINT32 end
  return v
end
function M.keyboard_device(controller)
  local s = signed(controller)
  if s and s < 0 then return controller end
  return 0
end
-- 手柄槽位 0 与旧版「键盘 = 0」无法区分，沿用旧行为：
-- 只对 >0 的槽位读取手柄绑定；0 继续交给游戏原生 ACTION_MAP。
function M.is_gamepad(controller)
  local s = signed(controller)
  return s ~= nil and s > 0
end
return M
