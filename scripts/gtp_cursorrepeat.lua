-- 单格移动的长按连续移动（纯状态机，可独立加载）。
-- 每个方向单独计时：按下边沿立刻走一格，按住后每 interval 帧再走一格。
-- 只负责“本帧该不该走”，格距、边界和输入来源仍由 gtrep 处理。
local CursorRepeat = {}
CursorRepeat.__index = CursorRepeat
function CursorRepeat.new()
  return setmetatable({next_frame = {}}, CursorRepeat)
end
function CursorRepeat:reset()
  self.next_frame = {}
end
-- edge = 本帧按下边沿；held = 方向仍被按住；interval = 帧数。
-- 返回本帧是否移动一格。长暂停后不补帧，最多只走一格。
function CursorRepeat:should_move(direction, frame, edge, held, interval)
  interval = math.max(1, math.floor(interval or 1))
  if edge then
    self.next_frame[direction] = frame + interval
    return true
  end
  if not held then
    self.next_frame[direction] = nil
    return false
  end
  local next_frame = self.next_frame[direction]
  if not next_frame then
    -- 地图打开时方向键已经按着（没有按下边沿）：从这一刻开始计间隔。
    self.next_frame[direction] = frame + interval
    return false
  end
  if frame >= next_frame then
    self.next_frame[direction] = frame + interval
    return true
  end
  return false
end
return CursorRepeat
