-- Some visited empty rooms keep RoomDescriptor.Clear=false after their exit opens.
-- Treat them as cleared for this mod's map and travel rules without changing game state.
return function(gt, api)
  local cleared = {}

  function gt:room_is_clear(desc)
    return desc ~= nil and (desc.Clear == true or cleared[desc.ListIndex] == true)
  end

  local function refresh()
    local game = Game()
    local level = game:GetLevel()
    local desc = level:GetCurrentRoomDesc()
    local room = game:GetRoom()
    if not desc or not desc.Data or not room then return end

    local kind = desc.Data.Type
    local eligible = kind == RoomType.ROOM_DEFAULT
      or (kind == RoomType.ROOM_CHALLENGE and desc.ChallengeDone)
    -- Extra secret rooms (Fragmented Card / Luna) use the same guarded live
    -- evidence; never infer clear state from room type or trinket possession.
    local secret = kind == RoomType.ROOM_SECRET or kind == RoomType.ROOM_SUPERSECRET
      or kind == RoomType.ROOM_ULTRASECRET
    eligible = eligible or (secret and room:IsClear())
    local open_exit = false
    for slot = 0, 7 do
      local door = room:GetDoor(slot)
      if door and door:IsOpen() then open_exit = true; break end
    end
    if eligible and not desc.Clear and desc.VisitedCount > 0
        and room:GetFrameCount() > 1 and room:GetAliveEnemiesCount() == 0
        and open_exit then
      cleared[desc.ListIndex] = true
    end

    if api then
      local map = api:GetLevel(gt:get_current_dimension())
      for _, map_room in ipairs(map or {}) do
        local mapped_desc = map_room.Descriptor
        if mapped_desc and cleared[mapped_desc.ListIndex] then
          map_room.Clear = true
        end
      end
    end
  end

  gt:AddCallback(ModCallbacks.MC_POST_UPDATE, refresh)
  gt:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL, function() cleared = {} end)
end
