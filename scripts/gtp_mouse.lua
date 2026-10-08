-- 纯输入状态：持续采样按钮边沿，鼠标与键盘按最后一次操作切换。
local Mouse = {}
Mouse.__index = Mouse
function Mouse.new()
  return setmetatable({mode = 'keyboard', down = false}, Mouse)
end
function Mouse:reset()
  self.mode, self.x, self.y = 'keyboard', nil, nil
end
function Mouse:update(input)
  local previous = self.mode
  local moved = self.x ~= nil and
    (input.x ~= self.x or input.y ~= self.y)
  local clicked = input.down and not self.down
  self.x, self.y, self.down = input.x, input.y, input.down
  if not input.active then
    self.mode = 'keyboard'
    return false, false
  end
  if input.keyboard then
    self.mode = 'keyboard'
  elseif moved or clicked then
    self.mode = 'mouse'
  end
  return self.mode == 'mouse', clicked and self.mode == 'mouse',
    previous ~= 'keyboard' and self.mode == 'keyboard'
end
return Mouse
