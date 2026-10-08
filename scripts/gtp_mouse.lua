-- 纯输入状态：按钮边沿与真实鼠标位移切换输入，不拿 HUD 投影变化判定移动。
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
  local x, y = input.motion_x or input.x, input.motion_y or input.y
  local dx, dy = x - (self.x or x), y - (self.y or y)
  -- 两个 render 像素的死区。键盘模式下保留锚点，慢速移动仍可累计越过死区；
  -- 不累计逐帧距离，避免静止鼠标的小幅往返抖动最终抢走控制。
  local moved = self.x ~= nil and dx * dx + dy * dy >= 4
  local clicked = input.down and not self.down
  self.down = input.down
  if self.x == nil or not input.active or input.mouse_enabled == false
    or input.keyboard or moved or clicked or self.mode == 'mouse' then
    self.x, self.y = x, y
  end
  if not input.active then
    self.mode = 'keyboard'
    return false, false
  end
  if input.mouse_enabled == false or input.keyboard then
    self.mode = 'keyboard'
  elseif moved or clicked then
    self.mode = 'mouse'
  end
  return self.mode == 'mouse', clicked and self.mode == 'mouse',
    previous ~= 'keyboard' and self.mode == 'keyboard'
end
return Mouse
