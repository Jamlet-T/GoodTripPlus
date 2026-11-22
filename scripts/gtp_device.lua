-- 地图键的设备解析（纯函数，可独立加载）。
-- J510 起（1.9.7.19）：键盘玩家在 Lua 中得到的是无符号的 4294967294（即 int32 的 -2），
-- 手柄槽位是 0..3；J460 及更早：键盘玩家是 0，0..3 都可能是手柄槽位。
-- 所以键盘判定必须跟随玩家自己的索引，不能硬编码 0；
-- 手柄绑定对所有非负槽位（含 0 号槽）生效：0 号槽在 J510+ 是真实手柄槽。
-- J460 的「键盘 = 0」与 0 号槽不可区分，作为已知取舍：未绑定时由原生 ACTION_MAP 兜底。
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
-- 0 号槽必须按手柄处理（J510+ 手柄槽位是 0..3）。曾经只对 >0 的槽位读手柄绑定，
-- 结果同一绑定在 0 号槽被忽略、热插拔换到 1 号槽后突然生效，表现为地图键“被改绑”。
function M.is_gamepad(controller)
  local s = signed(controller)
  return s ~= nil and s >= 0
end
return M
