-- 仅在活动光标切换控制模式时取证；诊断故障绝不影响输入状态机。
local Probe = {}
Probe.__index = Probe
function Probe.new(write, context)
  return setmetatable({write=write, context=context}, Probe)
end
function Probe:update(state, input)
  local from, anchorX, anchorY, wasDown = state.mode, state.x, state.y, state.down
  local follow, clicked, switched = state:update(input)
  if not self.disabled then
    local ok = pcall(function()
      local prev = self.previous or input
      if input.active and from ~= state.mode then
        local x, y = input.motion_x or input.x, input.motion_y or input.y
        local dx, dy = x-(anchorX or x), y-(anchorY or y)
        self.write(string.format(
          '[GTPmouse] mode %s->%s key=%s prevkey=%s move=%s click=%s mouseEnabled=%s raw=%.3f,%.3f delta=%.3f,%.3f screen=%.3f,%.3f screenDelta=%.3f,%.3f %s',
          from, state.mode, tostring(input.keyboard or false), tostring(prev.keyboard or false),
          tostring(anchorX ~= nil and dx*dx+dy*dy >= 4), tostring(input.down and not wasDown),
          tostring(input.mouse_enabled ~= false),
          x, y, dx, dy, input.x, input.y, input.x-prev.x, input.y-prev.y, self.context()))
      end
      self.previous = input
    end)
    if not ok then
      self.disabled = true
      pcall(self.write, '[GTPmouse] mode probe disabled after diagnostic failure')
    end
  end
  return follow, clicked, switched
end
return Probe
