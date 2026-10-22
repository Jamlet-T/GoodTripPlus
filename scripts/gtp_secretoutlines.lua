-- Doorway display contributed from Secret Candidate Outlines. Candidate data,
-- collision checks and map refreshes remain owned by GoodTripPlus/Lazy Delver.
return function(gt)
  local C = require("scripts.delver.const")
  local map = require("scripts.delver.map")
  local state = require("scripts.delver.state")
  local room_check = require("scripts.delver.room")
  local render = require("scripts.delver.render")
  local visibility = require("scripts.gtp_delvervisibility")
  local redsource = require("scripts.gtp_redsource")
  local candidate_view = require("scripts.gtp_candidateview")
  local game = Game()

  -- Render one fixed frame ourselves. The game's DOOR_OUTLINE effect owns its
  -- animation/lifetime, so a constant Color on that entity cannot stay steady.
  local outline_sprite = Sprite()
  outline_sprite:Load("gfx/1000.154_door outline.anm2", true)
  outline_sprite:SetFrame(outline_sprite:GetDefaultAnimation(), 1)
  -- This frame's source pixels are translucent. Repeated draws at the same
  -- position strengthen the doorway without changing its size or timing.
  local fixed_outline_passes = 5
  local ambiguous_outline_passes = 7
  local pending_stomps = {}
  local dog_tooth_observations = {}
  local observed_floor, last_observed_room
  local room_blast_pending, mama_mega_checked_map, mama_mega_checked_room
  local mama_state_sampled_map, mama_state_sampled_room, mama_mega_active
  local selected_entrances, selected_map, selected_room, selected_revision
  local selected_frame, selected_yo_listen, markers_visible
  local selected_show_single
  local last_red_outline_scan_frame, last_red_outline_scan_room
  local red_outline_slots = {}
  local yo_listen_frame, yo_listen_owned
  local stomp_variants = {
    [EffectVariant.MONSTROS_TOOTH] = true,
    [EffectVariant.MOM_FOOT_STOMP] = true,
  }
  local rock_wave_door_radius = 40
  local host_crackwaves = {}
  local wave_sources = {}
  local pending_suplex = {}
  local rock_source_entities = {}

  local function enabled()
    return gt:get_config_bool("ShowSecretMarkers", true)
      and gt:get_config_bool("ShowSecretDoorOutlines", true)
  end

  -- Delver intentionally ignores the Ascent/Home floor. Native Red Key
  -- outlines still exist there, so inspect held sources independently.
  -- gtp_redsource also covers Void (477) that has absorbed the Red Key (580),
  -- which no longer occupies an active slot.
  local function has_red_key_source()
    return redsource.has_source()
  end

  local function remove_markers()
    markers_visible = false
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

  local function has_yo_listen()
    local frame = game:GetFrameCount()
    if yo_listen_frame ~= frame then
      yo_listen_frame = frame
      yo_listen_owned = has_collectible(CollectibleType.COLLECTIBLE_YO_LISTEN)
    end
    return yo_listen_owned
  end

  local function actual_secret_next_to(lid)
    -- Dog Tooth is an explicit in-game clue, so the actual floor layout is
    -- read only when the item has sounded on entering this room.
    return map.truth_next_to(lid)
  end

  local function observe_dog_tooth(level)
    -- A rebuilt floor replaces this table. Never reuse clues across layouts.
    if observed_floor ~= map.floor_revision then
      observed_floor = map.floor_revision
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
            changed = map.exclude_candidate(cid) or changed
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

  local function candidate_allowed(candidate, yo_listen)
    return not disproved_by_dog_tooth(candidate)
      and (not yo_listen or candidate.secret_type == C.SECRET_TYPE.ULTRA
        or map.is_real(candidate.cid))
  end

  render.set_candidate_filter(function(candidate)
    -- Revealed real rooms intentionally lose their star but keep an unopened
    -- doorway. Other extra clues must agree with the doorway selection.
    return not enabled() or candidate_allowed(candidate, has_yo_listen())
  end)

  local function permitted_entrance(room, slot, secret_type)
    -- White/gold guesses follow visible walls, matching room.door_check.
    -- Keep the existing red-room doorway constraint for ultra entrances.
    if secret_type == C.SECRET_TYPE.ULTRA
      and not room:IsDoorSlotAllowed(slot) then return false end
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

    local result = {}
    local room_list = level:GetRooms()
    local yo_listen = has_yo_listen()
    local show_single = gt:get_config_bool("ShowSingleSecretCandidates", false)
    for _, candidate in pairs(map.candidates) do
      local kind = candidate.secret_type
      local clue_reveals = yo_listen and map.is_real(candidate.cid)
      local display_kind, ambiguous = candidate_view.select(candidate, show_single,
        clue_reveals and map.truth_type(candidate.cid) or nil)
      local color = C.MARKER.COLORS[display_kind]
      local ultra_hidden = kind == C.SECRET_TYPE.ULTRA
        and not state.can_see_red()
      local real = candidate.lid ~= nil or clue_reveals
      if color and not ultra_hidden
        and candidate_allowed(candidate, yo_listen)
        and (real or candidate.marker_status ~= C.MARKER.STATUS.FOUND) then
        local verified = fully_checked(candidate) or clue_reveals
          or (candidate.lid ~= nil and (real_room_revealed(candidate, room_list)
            or candidate.marker_status == C.MARKER.STATUS.FOUND))
        local rank = preference(display_kind, verified)
        for _, entry in ipairs(candidate.entries) do
          local slot = entry.doorslot
          if entry.source_lid == current.lid and slot ~= nil
            and permitted_entrance(room, slot, kind)
            and (not result[slot] or rank > result[slot].rank) then
            result[slot] = {
              rgb = color, verified = verified, rank = rank, secret_type = kind,
              ambiguous = ambiguous,
            }
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

  local function observe_red_key_outlines(level, room, room_index, frame)
    local descriptor = level:GetCurrentRoomDesc()
    if not has_red_key_source() and not map.is_red_room(descriptor) then
      red_outline_slots = {}
      last_red_outline_scan_frame = nil
      return
    end
    if last_red_outline_scan_room == room_index
      and last_red_outline_scan_frame
      and frame >= last_red_outline_scan_frame
      and frame - last_red_outline_scan_frame < 10 then return end
    last_red_outline_scan_room, last_red_outline_scan_frame = room_index, frame

    local slots = {}
    for _, effect in ipairs(Isaac.FindByType(EntityType.ENTITY_EFFECT,
      EffectVariant.DOOR_OUTLINE)) do
      if not effect:GetData().gtp_secret_outline_owned then
        local closest_slot, closest_distance
        for slot = 0, DoorSlot.NUM_DOOR_SLOTS - 1 do
          local slot_pos = room:GetDoorSlotPosition(slot)
          local marker_pos = doorway_pose(room, slot)
          local distance = math.min((effect.Position - slot_pos):Length(),
            (effect.Position - marker_pos):Length())
          if not closest_distance or distance < closest_distance then
            closest_slot, closest_distance = slot, distance
          end
        end
        if closest_slot and closest_distance <= 32 then
          slots[closest_slot] = true
        end
      end
    end
    red_outline_slots = slots
    if not next(slots) then return end

    -- Ascent/Home has no Delver candidate map. Keep the native red outlines
    -- available for drawing without touching stale candidate data.
    if state.is_ignored() or state.is_off_grid() then return end

    local current = descriptor and map.rooms[descriptor.ListIndex]
    if not current then return end

    local changed = false
    for cid, candidate in pairs(map.candidates) do
      if candidate.lid == nil
        and candidate.secret_type ~= C.SECRET_TYPE.ULTRA then
        for _, entry in ipairs(candidate.entries) do
          if entry.source_lid == current.lid
            and entry.doorslot ~= nil and slots[entry.doorslot] then
            changed = map.exclude_candidate(cid) or changed
          end
          if not map.candidates[cid] then break end
        end
      end
    end
    if changed then render.refresh() end
  end

  local function marker_color(rgb, ambiguous_opacity, ambiguous)
    -- A known single type stays fully visible; only two-type candidates pulse.
    local value = Color(1, 1, 1, ambiguous_opacity or 1)
    -- The stock doorway sprite is reddish; Colorize replaces its hue.
    -- Boost the changing color enough to remain visible while retaining its
    -- white-to-gold transition. Fixed colors keep their established strength.
    local strength = ambiguous and 1.5 or 3
    value:SetColorize(rgb[1] * strength, rgb[2] * strength,
      rgb[3] * strength, 1)
    return value
  end

  local function update_markers()
    local level = game:GetLevel()
    if not level then
      remove_markers()
      return
    end
    local descriptor = level:GetCurrentRoomDesc()
    local room_index = descriptor and descriptor.ListIndex
    if state.is_ignored() or state.is_off_grid() then
      remove_markers()
      observe_red_key_outlines(level, game:GetRoom(), room_index,
        game:GetFrameCount())
      return
    end
    if mama_state_sampled_map ~= map.candidates
      or mama_state_sampled_room ~= room_index then
      mama_state_sampled_map, mama_state_sampled_room = map.candidates, room_index
      mama_mega_active = level:GetStateFlag(LevelStateFlag.STATE_MAMA_MEGA_USED)
    end
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
    observe_red_key_outlines(level, game:GetRoom(), room_index,
      game:GetFrameCount())
    local map_cursed = (level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST) ~= 0
    if not enabled() or (map_cursed
      and not gt:get_config_bool("DoorOutlinesDuringCurse", true)) then
      remove_markers()
      return
    end

    render.update()
    local room = game:GetRoom()
    local revision = render.revision()
    local frame = game:GetFrameCount()
    local yo_listen = has_yo_listen()
    local show_single = gt:get_config_bool("ShowSingleSecretCandidates", false)
    local rebuild = not markers_visible or selected_map ~= map.candidates
      or selected_room ~= room_index or selected_revision ~= revision
      or selected_yo_listen ~= yo_listen
      or selected_show_single ~= show_single
      or frame - (selected_frame or 0) >= 30
    if not rebuild then
      for slot, data in pairs(selected_entrances) do
        if not permitted_entrance(room, slot, data.secret_type) then
          rebuild = true
          break
        end
      end
    end
    if rebuild then
      selected_entrances = collect_entrances(level, room)
      selected_map, selected_room = map.candidates, room_index
      selected_revision, selected_frame = revision, frame
      selected_yo_listen = yo_listen
      selected_show_single = show_single
    end
    markers_visible = true
  end

  local function draw_markers()
    -- Our MC_POST_RENDER callback can run after Mod Config Menu's overlay.
    -- Skip only the visual draw while its L-key menu is open; candidate
    -- evidence continues updating and the outlines return when it closes.
    if ModConfigMenu and ModConfigMenu.IsVisible then return end
    local level = game:GetLevel()
    if not level or not enabled() then return end
    local map_cursed = (level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST) ~= 0
    if map_cursed and not gt:get_config_bool("DoorOutlinesDuringCurse", true) then
      return
    end
    local draw_candidates = markers_visible and selected_entrances
      and not state.is_ignored() and not state.is_off_grid()
    if not draw_candidates and not next(red_outline_slots) then return end
    local room = game:GetRoom()
    local frame = game:GetFrameCount()
    local outline_opacity = math.max(0, math.min(100,
      tonumber(gt:get_config_bool("SecretDoorOutlineOpacity", 100)) or 100)) / 100
    -- MC_POST_RENDER draws on the final image. The mirror-world pass has
    -- already flipped the room, so our manually rendered sprites must use
    -- the same screen-space reflection rather than unmirrored world slots.
    local mirrored = room:IsMirrorWorld()
    local screen_width = mirrored and Isaac.GetScreenWidth() or nil
    local function draw_outline(slot, rgb, opacity, ambiguous, passes)
      local position, angle = doorway_pose(room, slot)
      outline_sprite.Color = marker_color(rgb, opacity, ambiguous)
      outline_sprite.Rotation = mirrored and -angle or angle
      -- The doorway frame is asymmetric. Rotation already swaps the left
      -- and right facing in the mirror; FlipX reverses it a second time.
      outline_sprite.FlipX = false
      local screen_position = Isaac.WorldToScreen(position)
      if mirrored then
        screen_position = Vector(screen_width - screen_position.X, screen_position.Y)
      end
      for _ = 1, passes do
        outline_sprite:Render(screen_position)
      end
    end
    if draw_candidates then
      for slot, data in pairs(selected_entrances) do
        if not red_outline_slots[slot]
          and permitted_entrance(room, slot, data.secret_type) then
          local rgb = data.rgb
          local ambiguous_opacity
          if data.ambiguous then
            rgb, ambiguous_opacity = C.MARKER.ambiguous_pulse(frame, 0.85)
          end
          local passes = data.ambiguous and ambiguous_outline_passes
            or fixed_outline_passes
          draw_outline(slot, rgb, (ambiguous_opacity or 1) * outline_opacity,
            data.ambiguous, passes)
        end
      end
    end
    -- Red Key outlines also occur inside rooms created by the Red Key. Those
    -- rooms are absent from the generated secret-candidate entry list, so
    -- paint directly over each visible native outline with the same red frame.
    for slot in pairs(red_outline_slots) do
      local door = room:GetDoor(slot)
      if not door or not door:IsOpen() then
        draw_outline(slot, C.MARKER.COLORS[C.SECRET_TYPE.ULTRA],
          nil, false, fixed_outline_passes)
      end
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

  local function rock_source_kind(entity)
    if is_roundy(entity) then return "roundy" end
    if is_adversary(entity) then return "adversary" end
    if is_bumbino(entity) then return "bumbino" end
    if is_moms_dead_hand(entity) then return "moms_dead_hand" end
    return extra_rock_source_kind(entity)
  end

  local function watch_rock_source(_, entity)
    if rock_source_kind(entity) then
      rock_source_entities[ent_key(entity)] = entity
    end
  end

  local function scan_room_rock_sources()
    rock_source_entities = {}
    for _, entity in ipairs(Isaac.GetRoomEntities()) do
      watch_rock_source(nil, entity)
    end
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
      for key, entity in pairs(rock_source_entities) do
        if not entity:Exists() then
          rock_source_entities[key] = nil
        else
          local distance = (entity.Position - effect.Position):Length()
          local nearby_kind = rock_source_kind(entity)
          if nearby_kind == "roundy" and distance <= 32
            and entity:GetSprite():IsPlaying("DigOut") then
            kind = "roundy"
            break
          elseif nearby_kind == "adversary" and distance <= 40 then
            kind = "adversary"
            break
          elseif nearby_kind == "bumbino" and distance <= 64 then
            kind = "bumbino"
            break
          elseif nearby_kind == "moms_dead_hand" and distance <= 48 then
            kind = "moms_dead_hand"
            break
          elseif nearby_kind
            and distance <= (nearby_kind == "bird_cage" and 48 or 72) then
            kind = nearby_kind
            break
          end
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
    if not next(wave_sources) then return end
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
    if not next(host_crackwaves) then return end
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
    last_red_outline_scan_frame = nil
    last_red_outline_scan_room = nil
    red_outline_slots = {}
    remove_markers()
    scan_room_rock_sources()
  end)
  for _, entity_type in ipairs({ EntityType.ENTITY_ROUNDY,
    EntityType.ENTITY_ADVERSARY, EntityType.ENTITY_BUMBINO,
    EntityType.ENTITY_MOMS_DEAD_HAND, EntityType.ENTITY_CAGE,
    EntityType.ENTITY_CHIMERA, EntityType.ENTITY_MEGA_FATTY,
    EntityType.ENTITY_POLYCEPHALUS }) do
    gt:AddCallback(ModCallbacks.MC_POST_NPC_INIT, watch_rock_source,
      entity_type)
  end
  gt:AddCallback(ModCallbacks.MC_FAMILIAR_INIT, watch_rock_source,
    FamiliarVariant.BIRD_CAGE)
  gt:AddCallback(ModCallbacks.MC_POST_UPDATE, update_markers)
  gt:AddCallback(ModCallbacks.MC_POST_RENDER, draw_markers)
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
    mama_state_sampled_map = nil
    mama_state_sampled_room = nil
    mama_mega_active = nil
    selected_entrances = nil
    selected_map = nil
    selected_room = nil
    selected_revision = nil
    selected_frame = nil
    selected_yo_listen = nil
    yo_listen_frame = nil
    yo_listen_owned = nil
    pending_stomps = {}
    host_crackwaves = {}
    wave_sources = {}
    pending_suplex = {}
    rock_source_entities = {}
    dog_tooth_observations = {}
    observed_floor = nil
    last_observed_room = nil
    last_red_outline_scan_frame = nil
    last_red_outline_scan_room = nil
    red_outline_slots = {}
    remove_markers()
  end)
  gt:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, remove_markers)
end
