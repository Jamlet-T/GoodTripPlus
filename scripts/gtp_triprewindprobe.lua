-- 传送 / rewind 自动取证。只观测，不写游戏快照或拦截原生 rewind。
-- Lua API 没有暴露 Game::SaveState；不能用 Mod:SaveData 冒充沙漏状态。
return function(gt)
  local enabled, started, trip, serial = true, false, nil, 0
  local last_pocket = nil -- 仅记录 API 事件，不能将它当作引擎内部保存标记
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
      'room=%s safe=%s lid=%s dim=%s frame=%s time=%s enter=%s leave=%s',
      tostring(level:GetCurrentRoomIndex()), tostring(desc.SafeGridIndex),
      tostring(desc.ListIndex), tostring(gt:get_current_dimension()),
      tostring(game:GetFrameCount()), tostring(game.TimeCounter),
      tostring(level.EnterDoor), tostring(level.LeaveDoor)), game:GetFrameCount()
  end
  local function write(event, detail)
    Isaac.DebugString('[GTPrewind] ' .. event .. ' ' .. detail)
  end
  local function pocket_detail()
    if not last_pocket then return ' pocket=none' end
    return string.format(' pocket=%s pocketId=%s pocketRoom=%s pocketFrame=%s',
      last_pocket.kind,last_pocket.id,last_pocket.room,last_pocket.frame)
  end
  local function pocket_callback(kind)
    return function(_, id, player, flags)
      probe(function()
        local origin, detail, frame = context()
        last_pocket = {kind=kind,id=id,room=origin,frame=frame}
        write('pocket-use', string.format('kind=%s id=%s flags=%s controller=%s %s',
          kind,tostring(id),tostring(flags),tostring(player and player.ControllerIndex),detail))
      end)
    end
  end
  if ModCallbacks.MC_USE_CARD then
    gt:AddCallback(ModCallbacks.MC_USE_CARD, pocket_callback('card'))
  end
  if ModCallbacks.MC_USE_PILL then
    gt:AddCallback(ModCallbacks.MC_USE_PILL, pocket_callback('pill'))
  end
  local original = gt.teleport_to_grid_index
  function gt:teleport_to_grid_index(gid)
    probe(function()
      local origin, detail, frame = context()
      serial = serial + 1
      trip = {id=serial, from=origin, target=gid, last=origin, frame=frame, dispatching=true}
      write('begin', string.format('id=%s target=%s mode=%s %s',
        serial, tostring(gid), tostring(gt:get_teleport_transition()), detail) .. pocket_detail())
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
      local current, detail, frame = context()
      if not trip then
        -- 开局后的用卡也需保留；过门信息只作为现场证据，不假定保存必然成功。
        if last_pocket then write('room-after-pocket',detail .. pocket_detail()) end
        return
      end
      local reloading = frame < trip.frame
      local phase = reloading and 'reload' or (trip.dispatching and 'dispatch' or 'arrival')
      write('new-room', 'id=' .. trip.id .. ' phase=' .. phase .. ' ' .. detail .. pocket_detail())
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
      started, trip, last_pocket = true, nil, nil
    end)
  end)
  if ModCallbacks.MC_PRE_GAME_EXIT then
    gt:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, function()
      started, trip, last_pocket = false, nil, nil
    end)
  end
end
