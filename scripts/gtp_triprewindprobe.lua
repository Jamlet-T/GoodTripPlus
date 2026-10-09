-- 传送 / rewind 自动取证。只观测，不写游戏快照或拦截原生 rewind。
-- Lua API 没有暴露 Game::SaveState；不能用 Mod:SaveData 冒充沙漏状态。
return function(gt)
  local enabled, started, trip, serial = true, false, nil, 0
  local function probe(fn)
    if not enabled then return end
    local ok = pcall(fn)
    if not ok then
      enabled = false
      pcall(Isaac.DebugString, '[GTPrewind] probe disabled after diagnostic error')
    end
  end
  local function context()
    local game = Game()
    local level = game:GetLevel()
    local desc = level:GetCurrentRoomDesc()
    return level:GetCurrentRoomIndex(), string.format(
      'room=%s safe=%s lid=%s dim=%s frame=%s time=%s',
      tostring(level:GetCurrentRoomIndex()), tostring(desc.SafeGridIndex),
      tostring(desc.ListIndex), tostring(gt:get_current_dimension()),
      tostring(game:GetFrameCount()), tostring(game.TimeCounter)), game:GetFrameCount()
  end
  local function write(event, detail)
    Isaac.DebugString('[GTPrewind] ' .. event .. ' ' .. detail)
  end
  local original = gt.teleport_to_grid_index
  function gt:teleport_to_grid_index(gid)
    probe(function()
      local origin, detail, frame = context()
      serial = serial + 1
      trip = {id=serial, from=origin, target=gid, last=origin, frame=frame, dispatching=true}
      write('begin', string.format('id=%s target=%s mode=%s %s',
        serial, tostring(gid), tostring(gt:get_teleport_transition()), detail))
    end)
    -- 不用 pcall 包住游戏操作，保留原始异常与所有返回值。
    local result = table.pack(original(self, gid))
    probe(function()
      if not trip then return end
      trip.dispatching = false
      local current, detail, frame = context()
      trip.last, trip.frame = current, frame
      write('dispatched', 'id=' .. trip.id .. ' ' .. detail)
    end)
    return table.unpack(result, 1, result.n)
  end
  gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    probe(function()
      if not trip then return end
      local current, detail, frame = context()
      local reloading = frame < trip.frame
      local phase = reloading and 'reload' or (trip.dispatching and 'dispatch' or 'arrival')
      write('new-room', 'id=' .. trip.id .. ' phase=' .. phase .. ' ' .. detail)
      if not reloading then trip.last, trip.frame = current, frame end
    end)
  end)
  gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(_, continued)
    probe(function()
      if started and trip then
        local _, detail = context()
        -- 名称刻意为 state-reload：continued 本身不能区分 rewind 与继续存档。
        write('state-reload', string.format('id=%s continued=%s from=%s target=%s last=%s %s',
          trip.id, tostring(continued), tostring(trip.from), tostring(trip.target),
          tostring(trip.last), detail))
      end
      started, trip = true, nil
    end)
  end)
  if ModCallbacks.MC_PRE_GAME_EXIT then
    gt:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function()
      started, trip = false, nil
    end)
  end
end
