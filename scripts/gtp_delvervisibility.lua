-- MinimapAPI 的有效标志与游戏描述符可以不同；读取当前维度同一描述符的显示状态。
local M = {}
local trace_disabled = false
function M.trace(message)
  if trace_disabled then return end
  local ok = pcall(function() Isaac.DebugString(message()) end)
  if not ok then
    trace_disabled = true
    pcall(function() Isaac.DebugString('[GTPdelver] visibility diagnostics disabled after failure') end)
  end
end
function M.flags(descriptor, dimension)
  local native = descriptor and descriptor.DisplayFlags or 0
  local api = MinimapAPI
  if not descriptor or not api or api.CurrentDimension ~= dimension
    or type(api.GetRoomByIdx) ~= 'function' then return native end
  local ok, value = pcall(function()
    local room = api:GetRoomByIdx(descriptor.SafeGridIndex)
    if not room or not room.Descriptor or type(room.GetDisplayFlags) ~= 'function' then return native end
    local same = room.Descriptor == descriptor
    if not same and GetPtrHash then same = GetPtrHash(room.Descriptor) == GetPtrHash(descriptor) end
    if not same then return native end
    local flags = room:GetDisplayFlags()
    return type(flags) == 'number' and (native | flags) or native
  end)
  return ok and value or native
end
return M
