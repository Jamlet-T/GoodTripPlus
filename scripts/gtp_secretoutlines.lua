-- Doorway display contributed from Secret Candidate Outlines. Candidate data,
-- collision checks and map refreshes remain owned by GoodTripPlus/Lazy Delver.
return function(gt)
  local C = require("scripts.delver.const")
  local map = require("scripts.delver.map")
  local state = require("scripts.delver.state")
  local room_check = require("scripts.delver.room")
  local render = require("scripts.delver.render")
  local visibility = require("scripts.gtp_delvervisibility")
  local game = Game()

  local markers = {}
  local pending_stomps = {}
  local dog_tooth_observations = {}
  local observed_candidates, last_observed_room
  local stomp_variants = {
    [EffectVariant.MONSTROS_TOOTH] = true,
    [EffectVariant.MOM_FOOT_STOMP] = true,
  }

  local red_key_color = Color(1, 1, 1, 0.9)
  red_key_color:SetColorize(3.2, 0.1, 0.1, 1)
  local hidden_red_key_color = Color(1, 1, 1, 0)

  local function enabled()
    return gt:get_config_bool("ShowSecretMarkers", true)
      and gt:get_config_bool("ShowSecretDoorOutlines", true)
  end

  local function recolor_enabled()
    return enabled() and gt:get_config_bool("RecolorRedKeyOutlines", true)
  end

  local function remove_markers()
    for slot, entity in pairs(markers) do
      if entity and entity:Exists() then entity:Remove() end
      markers[slot] = nil
    end
  end

  local function real_room_revealed(candidate, room_list)
    if candidate.lid == nil then return false end
    local lid = candidate.lid
    if state.get_dimension() == C.DIMENSION.MIRROR then
      local source = map.rooms[lid]
      if source and source.mirror_lid then lid = source.mirror_lid end
    end
    return visibility.flags(room_list:Get(lid), state.get_dimension()) ~= 0
  end

  local function resolved_secret_type(kind, room_list)
    -- A revealed real room removes speculative locations of that type, but
    -- its unopened doorway remains useful for bomb placement.
    for _, candidate in pairs(map.candidates) do
      if candidate.secret_type == kind and candidate.lid ~= nil
        and not real_room_revealed(candidate, room_list) then
        return false
      end
    end
    return true
  end

  local function fully_checked(candidate)
    for _, entry in ipairs(candidate.entries) do
      if not entry.checked then return false end
    end
    return true
  end

  local function has_collectible(collectible)
    for index = 0, game:GetNumPlayers() - 1 do
      if Isaac.GetPlayer(index):HasCollectible(collectible) then return true end
    end
    return false
  end

  local function actual_secret_next_to(lid)
    for _, candidate in pairs(map.candidates) do
      local kind = candidate.secret_type
      if candidate.lid ~= nil
        and (kind == C.SECRET_TYPE.REGULAR or kind == C.SECRET_TYPE.SUPER) then
        for _, entry in ipairs(candidate.entries) do
          if entry.source_lid == lid then return true end
        end
      end
    end
    return false
  end

  local function observe_dog_tooth(level)
    -- A rebuilt floor replaces this table. Never reuse clues across layouts.
    if observed_candidates ~= map.candidates then
      observed_candidates = map.candidates
      dog_tooth_observations = {}
      last_observed_room = nil
    end
    local descriptor = level:GetCurrentRoomDesc()
    local current = descriptor and map.rooms[descriptor.ListIndex]
    if not current or last_observed_room == current.lid then return end
    last_observed_room = current.lid

    -- Dog Tooth signals on room entry. Picking it up mid-room is not evidence
    -- until the player leaves and comes back.
    if has_collectible(CollectibleType.COLLECTIBLE_DOG_TOOTH) then
      dog_tooth_observations[current.lid] = actual_secret_next_to(current.lid)
    end
  end

  local function disproved_by_dog_tooth(candidate)
    if candidate.secret_type == C.SECRET_TYPE.ULTRA then return false end
    for _, entry in ipairs(candidate.entries) do
      if dog_tooth_observations[entry.source_lid] == false then
        return true
      end
    end
    return false
  end

  local function permitted_entrance(room, slot)
    if not room:IsDoorSlotAllowed(slot) then return false end
    local door = room:GetDoor(slot)
    if not door then return true end
    if door:IsOpen() then return false end
    local kind = door.TargetRoomType
    return kind == C.SECRET_TYPE.REGULAR
      or kind == C.SECRET_TYPE.SUPER
      or kind == C.SECRET_TYPE.ULTRA
  end

  local function preference(kind, verified)
    local type_rank = 1
    if kind == C.SECRET_TYPE.REGULAR then
      type_rank = 3
    elseif kind == C.SECRET_TYPE.SUPER then
      type_rank = 2
    end
    return (verified and 10 or 0) + type_rank
  end

  local function collect_entrances(level, room)
    local descriptor = level:GetCurrentRoomDesc()
    local current = descriptor and map.rooms[descriptor.ListIndex]
    if not current then return {} end

    local result, resolved = {}, {}
    local room_list = level:GetRooms()
    local yo_listen = has_collectible(CollectibleType.COLLECTIBLE_YO_LISTEN)
    for _, candidate in pairs(map.candidates) do
      local kind = candidate.secret_type
      if resolved[kind] == nil then
        resolved[kind] = resolved_secret_type(kind, room_list)
      end
      local color = C.MARKER.COLORS[kind]
      local ultra_hidden = kind == C.SECRET_TYPE.ULTRA
        and not state.can_see_red()
      local real = candidate.lid ~= nil
      if color and (real or not resolved[kind]) and not ultra_hidden
        and not disproved_by_dog_tooth(candidate)
        and (not yo_listen or kind == C.SECRET_TYPE.ULTRA or real)
        and (real or candidate.marker_status ~= C.MARKER.STATUS.FOUND) then
        local verified = fully_checked(candidate)
          or (real and (real_room_revealed(candidate, room_list)
            or candidate.marker_status == C.MARKER.STATUS.FOUND))
        local rank = preference(kind, verified)
        for _, entry in ipairs(candidate.entries) do
          local slot = entry.doorslot
          if entry.source_lid == current.lid and slot ~= nil
            and permitted_entrance(room, slot)
            and (not result[slot] or rank > result[slot].rank) then
            result[slot] = { rgb = color, verified = verified, rank = rank }
          end
        end
      end
    end
    return result
  end

  local function doorway_pose(room, slot)
    local side = slot % 4
    local shift
    if side == DoorSlot.LEFT0 then
      shift = Vector(24, 0)
    elseif side == DoorSlot.UP0 then
      shift = Vector(0, 24)
    elseif side == DoorSlot.RIGHT0 then
      shift = Vector(-24, 0)
    else
      shift = Vector(0, -24)
    end
    return room:GetDoorSlotPosition(slot) + shift, side * 90 - 90
  end

  local function red_key_flash_phase()
    -- At 30 updates per second each color occupies half of a one-second cycle.
    return math.floor(game:GetFrameCount() / 15) % 2 == 0
  end

  local function marker_color(rgb, verified, hidden)
    local opacity = 1
    if not verified then
      local phase = game:GetFrameCount() * (2 * math.pi / 30)
      opacity = 0.66 + 0.16 * math.sin(phase)
    end
    if hidden then opacity = 0 end
    local value = Color(1, 1, 1, opacity)
    -- The stock doorway sprite is reddish; Colorize replaces its hue.
    value:SetColorize(rgb[1] * 3, rgb[2] * 3, rgb[3] * 3, 1)
    return value
  end

  local function recolor_red_key_outline(_, effect)
    local data = effect:GetData()
    if data.gtp_secret_outline_owned then return end
    if not recolor_enabled() then
      if data.gtp_original_outline_color then
        effect:GetSprite().Color = data.gtp_original_outline_color
        data.gtp_original_outline_color = nil
      end
      return
    end
    if not data.gtp_original_outline_color then
      data.gtp_original_outline_color = effect:GetSprite().Color
    end
    local overlap = false
    for _, marker in pairs(markers) do
      if marker and marker:Exists()
        and (marker.Position - effect.Position):Length() < 40 then
        overlap = true
        break
      end
    end
    effect:GetSprite().Color = overlap and not red_key_flash_phase()
      and hidden_red_key_color or red_key_color
  end

  local function update_markers()
    local level = game:GetLevel()
    if not level or state.is_ignored() or state.is_off_grid() then
      remove_markers()
      return
    end
    -- Maintain entry evidence even if the doorway setting is temporarily off.
    observe_dog_tooth(level)
    local map_cursed = (level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST) ~= 0
    if not enabled() or (map_cursed
      and not gt:get_config_bool("DoorOutlinesDuringCurse", true)) then
      remove_markers()
      return
    end

    render.update()
    local room = game:GetRoom()
    local selected = collect_entrances(level, room)
    local red_key_outlines = {}
    if recolor_enabled() then
      for _, effect in ipairs(Isaac.GetRoomEntities()) do
        if effect.Type == EntityType.ENTITY_EFFECT
          and effect.Variant == EffectVariant.DOOR_OUTLINE
          and not effect:GetData().gtp_secret_outline_owned then
          red_key_outlines[#red_key_outlines + 1] = effect
        end
      end
    end

    for slot, entity in pairs(markers) do
      if not selected[slot] or not entity:Exists() then
        if entity:Exists() then entity:Remove() end
        markers[slot] = nil
      end
    end
    for slot, data in pairs(selected) do
      local entity = markers[slot]
      if not entity then
        local position, angle = doorway_pose(room, slot)
        entity = Isaac.Spawn(EntityType.ENTITY_EFFECT,
          EffectVariant.DOOR_OUTLINE, 0, position, Vector(0, 0), nil)
        entity:GetData().gtp_secret_outline_owned = true
        entity.SpriteRotation = angle
        markers[slot] = entity
      end
      local overlap = false
      for _, outline in ipairs(red_key_outlines) do
        if (entity.Position - outline.Position):Length() < 40 then
          overlap = true
          break
        end
      end
      entity:GetSprite().Color = marker_color(data.rgb, data.verified,
        overlap and red_key_flash_phase())
    end
  end

  local function remember_stomp(_, effect)
    local descriptor = game:GetLevel():GetCurrentRoomDesc()
    if not descriptor then return end
    pending_stomps[effect.InitSeed] = {
      room_index = descriptor.ListIndex,
      position = effect.Position,
      updates = 0,
    }
  end

  local function follow_stomp(_, effect)
    local pending = pending_stomps[effect.InitSeed]
    if not pending then return end
    pending.position = effect.Position
    pending.updates = pending.updates + 1
  end

  local function finish_stomp(_, entity)
    if entity.Type ~= EntityType.ENTITY_EFFECT
      or not stomp_variants[entity.Variant] then return end
    local pending = pending_stomps[entity.InitSeed]
    pending_stomps[entity.InitSeed] = nil
    if not pending or pending.updates == 0 then return end
    if not gt:get_config_bool("ShowSecretMarkers", true) then return end
    local descriptor = game:GetLevel():GetCurrentRoomDesc()
    if not descriptor or descriptor.ListIndex ~= pending.room_index then return end
    if state.is_ignored() then return end
    -- Reuse Delver's wall-impact rule; it only excludes fake regular/super
    -- candidates near the impact, and never deletes a real secret room.
    room_check.bomb_check({ Position = pending.position })
    render.refresh()
  end

  gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    pending_stomps = {}
    last_observed_room = nil
    remove_markers()
  end)
  gt:AddCallback(ModCallbacks.MC_POST_UPDATE, update_markers)
  gt:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE,
    recolor_red_key_outline, EffectVariant.DOOR_OUTLINE)
  for variant in pairs(stomp_variants) do
    gt:AddCallback(ModCallbacks.MC_POST_EFFECT_INIT, remember_stomp, variant)
    gt:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, follow_stomp, variant)
  end
  gt:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE,
    finish_stomp, EntityType.ENTITY_EFFECT)
  gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
    pending_stomps = {}
    dog_tooth_observations = {}
    observed_candidates = nil
    last_observed_room = nil
    remove_markers()
  end)
  gt:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, remove_markers)
end
