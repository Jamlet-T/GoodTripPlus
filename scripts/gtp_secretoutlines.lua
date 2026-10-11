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
  local room_blast_pending, mama_mega_checked_map, mama_mega_checked_room
  local stomp_variants = {
    [EffectVariant.MONSTROS_TOOTH] = true,
    [EffectVariant.MOM_FOOT_STOMP] = true,
  }
  local rock_wave_door_radius = 40
  local host_crackwaves = {}
  local wave_sources = {}
  local pending_suplex = {}

  local function enabled()
    return gt:get_config_bool("ShowSecretMarkers", true)
      and gt:get_config_bool("ShowSecretDoorOutlines", true)
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
      local p = Isaac.GetPlayer(index)
      -- 玩家实体可能尚未就绪（无实体时 HasCollectible 会原生崩溃），必须 Exists 兜底。
      if p and p:Exists() and p:HasCollectible(collectible) then return true end
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

  local function clear_room_blast_candidates(level)
    local descriptor = level:GetCurrentRoomDesc()
    local current = descriptor and map.rooms[descriptor.ListIndex]
    if not current then return nil end
    local changed = false
    for cid, candidate in pairs(map.candidates) do
      if candidate.lid == nil
        and (candidate.secret_type == C.SECRET_TYPE.REGULAR
          or candidate.secret_type == C.SECRET_TYPE.SUPER) then
        for _, entry in ipairs(candidate.entries) do
          if entry.source_lid == current.lid then
            map.candidates[cid] = nil
            changed = true
            break
          end
        end
      end
    end
    if changed then render.refresh() end
    return changed
  end

  local function remember_room_blast(_, item)
    if item ~= CollectibleType.COLLECTIBLE_MAMA_MEGA
      and item ~= CollectibleType.COLLECTIBLE_MEGA_BEAN then return end
    local descriptor = game:GetLevel():GetCurrentRoomDesc()
    room_blast_pending = descriptor and descriptor.ListIndex
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

  local function marker_color(rgb, verified)
    local opacity = 1
    if not verified then
      local phase = game:GetFrameCount() * (2 * math.pi / 30)
      opacity = 0.66 + 0.16 * math.sin(phase)
    end
    local value = Color(1, 1, 1, opacity)
    -- The stock doorway sprite is reddish; Colorize replaces its hue.
    value:SetColorize(rgb[1] * 3, rgb[2] * 3, rgb[3] * 3, 1)
    return value
  end

  local function update_markers()
    local level = game:GetLevel()
    if not level or state.is_ignored() or state.is_off_grid() then
      remove_markers()
      return
    end
    local descriptor = level:GetCurrentRoomDesc()
    local room_index = descriptor and descriptor.ListIndex
    local mama_mega_active = level:GetStateFlag(
      LevelStateFlag.STATE_MAMA_MEGA_USED)
    local needs_mama_check = mama_mega_active and
      (mama_mega_checked_map ~= map.candidates
        or mama_mega_checked_room ~= room_index)
    if room_index and (room_blast_pending == room_index or needs_mama_check) then
      if clear_room_blast_candidates(level) ~= nil then
        room_blast_pending = nil
        if mama_mega_active then
          mama_mega_checked_map = map.candidates
          mama_mega_checked_room = room_index
        end
      end
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
      entity:GetSprite().Color = marker_color(data.rgb, data.verified)
    end
  end

  -- 同一实体的三个回调（INIT / UPDATE / REMOVE）按对象身份配对。InitSeed 不保证唯一，
  -- 仓库其它处一律用 GetPtrHash 认实体身份（delver/map.lua、gtp_delvervisibility.lua）。
  local function ent_key(entity)
    if GetPtrHash then return GetPtrHash(entity) end
    return entity.InitSeed
  end

  local function remember_stomp(_, effect)
    local descriptor = game:GetLevel():GetCurrentRoomDesc()
    if not descriptor then return end
    pending_stomps[ent_key(effect)] = {
      room_index = descriptor.ListIndex,
      position = effect.Position,
      updates = 0,
    }
  end

  local function follow_stomp(_, effect)
    local pending = pending_stomps[ent_key(effect)]
    if not pending then return end
    pending.position = effect.Position
    pending.updates = pending.updates + 1
  end

  local function finish_stomp(_, entity)
    if entity.Type ~= EntityType.ENTITY_EFFECT
      or not stomp_variants[entity.Variant] then return end
    local key = ent_key(entity)
    local pending = pending_stomps[key]
    pending_stomps[key] = nil
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

  local function remember_wait_what(_, item, _, player)
    if item ~= CollectibleType.COLLECTIBLE_WAIT_WHAT then return end
    local frame = game:GetFrameCount()
    local position = player and player.Position or Isaac.GetPlayer(0).Position
    wave_sources["wait_what_" .. frame] = {
      started = frame,
      points = { { position = Vector(position.X, position.Y),
        frame = frame, origin = true } },
    }
  end

  local function remember_stompy_damage(_, entity)
    local player = entity:ToPlayer()
    if not player or not player:HasPlayerForm(PlayerForm.PLAYERFORM_STOMPY) then
      return
    end
    local frame = game:GetFrameCount()
    local position = player.Position
    wave_sources["stompy_" .. player.InitSeed .. "_" .. frame] = {
      started = frame,
      points = { { position = Vector(position.X, position.Y),
        frame = frame, origin = true } },
    }
  end

  local function remember_suplex(_, item, _, player)
    if item ~= CollectibleType.COLLECTIBLE_SUPLEX then return end
    player = player or Isaac.GetPlayer(0)
    pending_suplex[player.InitSeed] = {
      player = player, started = game:GetFrameCount(),
    }
  end

  local function is_wait_what_wisp(entity)
    return entity and entity.Type == EntityType.ENTITY_FAMILIAR
      and (entity.Variant == FamiliarVariant.WISP
        or entity.Variant == FamiliarVariant.ITEM_WISP)
      and entity.SubType == CollectibleType.COLLECTIBLE_WAIT_WHAT
  end

  local function remember_wait_what_wisp_death(_, entity)
    if not is_wait_what_wisp(entity) then return end
    local data = entity:GetData()
    if data.gtp_wait_what_wisp_remembered then return end
    data.gtp_wait_what_wisp_remembered = true
    local frame = game:GetFrameCount()
    wave_sources["wait_what_wisp_" .. entity.InitSeed] = {
      started = frame,
      points = { { position = Vector(entity.Position.X, entity.Position.Y),
        frame = frame, origin = true } },
    }
  end

  local function watch_wait_what_wisp(_, familiar)
    if is_wait_what_wisp(familiar) and familiar:HasMortalDamage() then
      remember_wait_what_wisp_death(nil, familiar)
    end
  end

  local function is_roundy(entity)
    return entity and entity.Type == EntityType.ENTITY_ROUNDY
      and entity.Variant == 0 and entity.SubType == 0
  end

  local function is_adversary(entity)
    return entity and entity.Type == EntityType.ENTITY_ADVERSARY
      and entity.Variant == 0 and entity.SubType == 0
  end

  local function is_bumbino(entity)
    return entity and entity.Type == EntityType.ENTITY_BUMBINO
      and entity.Variant == 0 and entity.SubType == 0
  end

  local function is_moms_dead_hand(entity)
    return entity and entity.Type == EntityType.ENTITY_MOMS_DEAD_HAND
      and entity.Variant == 0 and entity.SubType == 0
  end

  local extra_rock_sources = {
    [EntityType.ENTITY_FAMILIAR] = {
      [FamiliarVariant.BIRD_CAGE] = "bird_cage",
    },
    [EntityType.ENTITY_CAGE] = {
      [0] = { [0] = "cage", [1] = "cage_variant" },
    },
    [EntityType.ENTITY_CHIMERA] = { [0] = { [0] = "chimera" } },
    [EntityType.ENTITY_MEGA_FATTY] = {
      [0] = { [2] = "brown_mega_fatty" },
    },
    [EntityType.ENTITY_POLYCEPHALUS] = { [1] = { [0] = "pile" } },
  }

  local function extra_rock_source_kind(entity)
    if not entity then return nil end
    local variants = extra_rock_sources[entity.Type]
    local variant = variants and variants[entity.Variant]
    if entity.Type == EntityType.ENTITY_FAMILIAR then return variant end
    return variant and variant[entity.SubType]
  end

  local function remember_verified_shockwave(_, effect)
    local kind
    local extra_kind = extra_rock_source_kind(effect.SpawnerEntity)
      or extra_rock_source_kind(effect.Parent)
    if not extra_kind and effect.SpawnerType == EntityType.ENTITY_FAMILIAR
      and effect.SpawnerVariant == FamiliarVariant.BIRD_CAGE then
      extra_kind = "bird_cage"
    end
    if is_roundy(effect.SpawnerEntity) or is_roundy(effect.Parent)
      or (effect.SpawnerType == EntityType.ENTITY_ROUNDY
        and effect.SpawnerVariant == 0) then
      kind = "roundy"
    elseif is_adversary(effect.SpawnerEntity)
      or is_adversary(effect.Parent)
      or (effect.SpawnerType == EntityType.ENTITY_ADVERSARY
        and effect.SpawnerVariant == 0) then
      kind = "adversary"
    elseif is_bumbino(effect.SpawnerEntity)
      or is_bumbino(effect.Parent)
      or (effect.SpawnerType == EntityType.ENTITY_BUMBINO
        and effect.SpawnerVariant == 0) then
      kind = "bumbino"
    elseif is_moms_dead_hand(effect.SpawnerEntity)
      or is_moms_dead_hand(effect.Parent)
      or (effect.SpawnerType == EntityType.ENTITY_MOMS_DEAD_HAND
        and effect.SpawnerVariant == 0) then
      kind = "moms_dead_hand"
    elseif extra_kind then
      kind = extra_kind
    elseif is_wait_what_wisp(effect.SpawnerEntity)
      or is_wait_what_wisp(effect.Parent) then
      kind = "wait_what_wisp"
    end
    if not kind then
      -- Effects without spawner data need a matching nearby source.
      for _, entity in ipairs(Isaac.GetRoomEntities()) do
        local distance = (entity.Position - effect.Position):Length()
        local nearby_kind = extra_rock_source_kind(entity)
        if is_roundy(entity) and distance <= 32
          and entity:GetSprite():IsPlaying("DigOut") then
          kind = "roundy"
          break
        elseif is_adversary(entity) and distance <= 40 then
          kind = "adversary"
          break
        elseif is_bumbino(entity) and distance <= 64 then
          kind = "bumbino"
          break
        elseif is_moms_dead_hand(entity) and distance <= 48 then
          kind = "moms_dead_hand"
          break
        elseif nearby_kind
          and distance <= (nearby_kind == "bird_cage" and 48 or 72) then
          kind = nearby_kind
          break
        end
      end
    end
    local frame = game:GetFrameCount()
    if not kind then
      for seed, pending in pairs(pending_suplex) do
        if frame - pending.started > 180 then
          pending_suplex[seed] = nil
        elseif pending.player and pending.player:Exists()
          and (pending.player == effect.SpawnerEntity
            or pending.player == effect.Parent
            or (pending.player.Position - effect.Position):Length() <= 64) then
          kind = "suplex"
          pending_suplex[seed] = nil
          break
        end
      end
    end
    if not kind then return end
    wave_sources[kind .. "_" .. effect.InitSeed] = {
      started = frame,
      points = { { position = Vector(effect.Position.X, effect.Position.Y),
        frame = frame, origin = true } },
    }
  end

  local function check_rock_wave_front(_, effect)
    local data = effect:GetData()
    if data.gtp_rock_front_checked or data.gtp_host_rock_checked then return end
    local frame = game:GetFrameCount()
    local best_source, best_step
    for key, source in pairs(wave_sources) do
      if frame - source.started > 50 then
        wave_sources[key] = nil
      else
        for index = #source.points, 1, -1 do
          local point = source.points[index]
          if frame - point.frame > (point.origin and 12 or 5) then
            table.remove(source.points, index)
          else
            local step = (effect.Position - point.position):Length()
            if step >= 8 and step <= 64
              and (not best_step or step < best_step) then
              best_source, best_step = source, step
            end
          end
        end
      end
    end
    if not best_source then return end
    data.gtp_rock_front_checked = true
    best_source.points[#best_source.points + 1] = {
      position = Vector(effect.Position.X, effect.Position.Y), frame = frame,
    }
    if not gt:get_config_bool("ShowSecretMarkers", true)
      or state.is_ignored() then return end
    local hit_position = game:GetRoom():GetClampedPosition(effect.Position, 0)
    if room_check.wall_hit_check(hit_position, rock_wave_door_radius) then
      render.refresh()
    end
  end

  local function remember_host_crackwave(_, effect)
    if effect.SubType ~= 2 or host_crackwaves[effect.InitSeed] then return end
    local spawner = effect.SpawnerEntity
    if not spawner or spawner.Type ~= EntityType.ENTITY_HOST
      or spawner.Variant ~= 3 then return end
    local frame = game:GetFrameCount()
    host_crackwaves[effect.InitSeed] = {
      position = effect.Position,
      started = frame,
      last_frame = frame,
    }
  end

  local function check_host_rock_wave(_, effect)
    local data = effect:GetData()
    if data.gtp_host_rock_checked then return end
    local frame = game:GetFrameCount()
    local nearest_wave, nearest_step
    for seed, wave in pairs(host_crackwaves) do
      if frame - wave.started > 40 or frame - wave.last_frame > 4 then
        host_crackwaves[seed] = nil
      else
        local step = (effect.Position - wave.position):Length()
        if step >= 12 and step <= 48
          and (not nearest_step or step < nearest_step) then
          nearest_wave, nearest_step = wave, step
        end
      end
    end
    if not nearest_wave then return end
    data.gtp_host_rock_checked = true
    nearest_wave.position = effect.Position
    nearest_wave.last_frame = frame

    if not gt:get_config_bool("ShowSecretMarkers", true)
      or state.is_ignored() then return end
    local hit_position = game:GetRoom():GetClampedPosition(effect.Position, 0)
    if room_check.wall_hit_check(hit_position, rock_wave_door_radius) then
      render.refresh()
    end
  end

  gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    pending_suplex = {}
    room_blast_pending = nil
    pending_stomps = {}
    host_crackwaves = {}
    wave_sources = {}
    last_observed_room = nil
    remove_markers()
  end)
  gt:AddCallback(ModCallbacks.MC_POST_UPDATE, update_markers)
  for variant in pairs(stomp_variants) do
    gt:AddCallback(ModCallbacks.MC_POST_EFFECT_INIT, remember_stomp, variant)
    gt:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE, follow_stomp, variant)
  end
  gt:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE,
    remember_host_crackwave, EffectVariant.CRACKWAVE)
  gt:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE,
    check_host_rock_wave, EffectVariant.ROCK_EXPLOSION)
  gt:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE,
    check_rock_wave_front, EffectVariant.ROCK_EXPLOSION)
  for _, variant in ipairs({ EffectVariant.SHOCKWAVE,
    EffectVariant.SHOCKWAVE_DIRECTIONAL, EffectVariant.CRACKWAVE,
    EffectVariant.SHOCKWAVE_RANDOM, EffectVariant.BIG_CRACKWAVE }) do
    gt:AddCallback(ModCallbacks.MC_POST_EFFECT_INIT,
      remember_verified_shockwave, variant)
  end
  gt:AddCallback(ModCallbacks.MC_POST_EFFECT_UPDATE,
    check_rock_wave_front, EffectVariant.BIG_ROCK_EXPLOSION)
  gt:AddCallback(ModCallbacks.MC_USE_ITEM,
    remember_wait_what, CollectibleType.COLLECTIBLE_WAIT_WHAT)
  gt:AddCallback(ModCallbacks.MC_USE_ITEM,
    remember_suplex, CollectibleType.COLLECTIBLE_SUPLEX)
  gt:AddCallback(ModCallbacks.MC_USE_ITEM,
    remember_room_blast, CollectibleType.COLLECTIBLE_MAMA_MEGA)
  gt:AddCallback(ModCallbacks.MC_USE_ITEM,
    remember_room_blast, CollectibleType.COLLECTIBLE_MEGA_BEAN)
  gt:AddCallback(ModCallbacks.MC_ENTITY_TAKE_DMG, remember_stompy_damage,
    EntityType.ENTITY_PLAYER)
  gt:AddCallback(ModCallbacks.MC_POST_ENTITY_REMOVE,
    finish_stomp, EntityType.ENTITY_EFFECT)
  gt:AddCallback(ModCallbacks.MC_POST_ENTITY_KILL,
    remember_wait_what_wisp_death, EntityType.ENTITY_FAMILIAR)
  gt:AddCallback(ModCallbacks.MC_FAMILIAR_UPDATE,
    watch_wait_what_wisp, FamiliarVariant.WISP)
  gt:AddCallback(ModCallbacks.MC_FAMILIAR_UPDATE,
    watch_wait_what_wisp, FamiliarVariant.ITEM_WISP)
  gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
    room_blast_pending = nil
    mama_mega_checked_map = nil
    mama_mega_checked_room = nil
    pending_stomps = {}
    host_crackwaves = {}
    wave_sources = {}
    pending_suplex = {}
    dog_tooth_observations = {}
    observed_candidates = nil
    last_observed_room = nil
    remove_markers()
  end)
  gt:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, remove_markers)
end
