-- 地图键 / 方向键的设备解析（纯函数，可独立加载）。
--
-- 以撒 Lua 侧的编号经历过三代：
--   J460–J509：键盘 ControllerIndex = 0，手柄槽位 0..3；输入查询参数同一套编号。
--   J510–J513：键盘 ControllerIndex = -2（Lua 侧可能拿到无符号 4294967294），
--               手柄槽位 0..3；输入查询参数仍是同一套编号。
--   J514+：新增 Input.GetKeyboardDeviceId()（返回 -2），六个输入查询
--           （IsActionPressed / IsActionTriggered / IsButtonPressed /
--             IsButtonTriggered / GetActionValue / GetButtonValue）改为
--           **查询槽位**：0 = 键盘，1 = 第一个手柄，2 = 第二个……
--           而 EntityPlayer.ControllerIndex 仍是「键盘 -2 / 手柄 0..3」。
--           因此手柄查询必须 +1，键盘查询必须传 0。
--
-- 新 API 只能能力探测（Input.GetKeyboardDeviceId 存在即 J514+）；探测不到时
-- 完全沿用旧编号，保证在旧版本上行为不变。
local M = {}
local UINT32 = 4294967296
local SIGN_BIT = 2147483648
local function signed(v)
  if type(v) ~= "number" then return nil end
  if v >= SIGN_BIT then return v - UINT32 end
  return v
end
local function slot_api()
  return Input ~= nil and type(Input.GetKeyboardDeviceId) == "function"
end
-- 键盘查询槽位。J514+ 固定 0；旧版本跟随玩家自己的索引（J510+ 键盘 = -2）。
function M.keyboard_device(controller)
  if slot_api() then return 0 end
  local s = signed(controller)
  if s and s < 0 then return controller end
  return 0
end
-- 手柄查询槽位；不是手柄（键盘 / nil）时返回 nil。
-- J514+ 手柄槽位 = ControllerIndex + 1；旧版本直接用手柄槽位。
-- 0 号槽必须按手柄处理：曾经只对 >0 的槽位读手柄绑定，结果热插拔换槽后
-- 绑定行为翻转，表现为地图键“被改绑”。
function M.gamepad_device(controller)
  local s = signed(controller)
  if s == nil or s < 0 then return nil end
  if slot_api() then return s + 1 end
  return controller
end
-- 玩家自己设备的查询槽位（键盘或手柄都适用）。
-- gtrep 里查「这个玩家的动作/按钮」一律用它，不要直接传 ControllerIndex。
function M.input_device(controller)
  local s = signed(controller)
  if slot_api() then
    if s == nil or s < 0 then return 0 end
    return s + 1
  end
  if s == nil then return 0 end
  return controller
end
-- 槽位是否为真实手柄。J510+ 手柄槽位是 0..3；0 号槽必须当手柄。
-- J460 的「键盘 = 0」与 0 号槽不可区分，作为已知取舍：未绑定时由原生 ACTION_MAP 兜底。
function M.is_gamepad(controller)
  local s = signed(controller)
  return s ~= nil and s >= 0
end
return M
