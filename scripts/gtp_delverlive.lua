-- 同房间现场更新：揭露标志变化，以及命中门位的破墙泪弹/激光/挥动中的铁镐。
-- REPENTOGON 使用 MC_TEAR_GRID_COLLISION；原版回退到 CollidesWithGrid。
-- HasTearFlags/CollidesWithGrid：IsaacDocs EntityTear/Entity；
-- GetIsSwinging/GetHitboxParentKnife/NOTCHED_AXE：REPENTOGON EntityKnife/KnifeVariant。
return function(gt, state, map, room, render, enabled)
  local C = require('scripts.delver.const')
  local visibility = require('scripts.gtp_delvervisibility')
  -- 实体 Variant 9 是铁镐；KnifeVariant 的命名枚举由 REPENTOGON 添加，原版不存在。
  local axe_variant = (KnifeVariant and KnifeVariant.NOTCHED_AXE) or 9
  pcall(function()
    Isaac.DebugString('[GTPdelver] live-probe rgon=' .. tostring(REPENTOGON ~= nil)
      .. ' axeVariant=' .. tostring(axe_variant))
  end)
  local previous_map, previous_dimension, flags, real_rooms = nil, nil, {}, {}
  local axe_probes = setmetatable({}, {__mode='k'})
  local tear_candidate_map, tear_candidate_room, tear_candidate_revision
  local has_tear_candidate = false
  local breaking_source_frame, held_breaking_source
  local data_miner_used_here = false
  local breaking_tear_sources = {
    CollectibleType.COLLECTIBLE_SULFURIC_ACID,
    CollectibleType.COLLECTIBLE_TERRA,
    CollectibleType.COLLECTIBLE_FRUIT_CAKE,
  }
  gt:AddCallback(ModCallbacks.MC_POST_UPDATE, function()
    if not enabled() or state.is_ignored() then return end
    local dimension = state.get_dimension()
    local changed = false
    if previous_map ~= map.candidates or previous_dimension ~= dimension then
      previous_map, previous_dimension, flags = map.candidates, dimension, {}
      real_rooms = {}
      -- 候选表只在重建/切维度时扫描，正常更新只读真实隐藏房的描述符。
      for _, candidate in pairs(map.candidates) do
        local lid = candidate.lid
        if lid ~= nil then
          if dimension == 1 and map.rooms[lid] then lid = map.rooms[lid].mirror_lid or lid end
          real_rooms[#real_rooms+1] = lid
        end
      end
      changed = true
    end
    if #real_rooms > 0 then
      local descriptors = Game():GetLevel():GetRooms()
      for _, lid in ipairs(real_rooms) do
        local descriptor = descriptors:Get(lid)
        local value = visibility.flags(descriptor, dimension)
        if flags[lid] ~= value then
          local previous = flags[lid]
          flags[lid], changed = value, true
          if previous ~= nil then visibility.trace(function()
            return '[GTPdelver] visibility lid=' .. lid .. ' dimension=' .. dimension
              .. ' old=' .. previous .. ' effective=' .. value
              .. ' native=' .. tostring(descriptor and descriptor.DisplayFlags)
              .. ' refresh=true'
          end) end
        end
      end
    end
    if changed then render.refresh() end
  end)

  local function hit(entity, kind)
    -- 网格中心到边缘为 20 游戏单位；加上实体实际尺寸，仅处理命中门位的一小片区域。
    if room.wall_hit_check(entity.Position, (entity.Size or 0) + 20) then
      render.refresh()
      pcall(function()
        Isaac.DebugString('[GTPdelver] wall-hit kind=' .. kind
          .. ' x=' .. tostring(entity.Position.X) .. ' y=' .. tostring(entity.Position.Y)
          .. ' excluded-fake=true')
      end)
    end
  end
  local function has_fake_candidate_here()
    local descriptor = Game():GetLevel():GetCurrentRoomDesc()
    local current = descriptor and map.rooms[descriptor.ListIndex]
    local lid = current and current.lid
    local revision = render.revision()
    if tear_candidate_map ~= map.candidates or tear_candidate_room ~= lid
      or tear_candidate_revision ~= revision then
      tear_candidate_map, tear_candidate_room = map.candidates, lid
      tear_candidate_revision, has_tear_candidate = revision, false
      if lid then
        for _, candidate in pairs(map.candidates) do
          if candidate.lid == nil
            and candidate.secret_type ~= C.SECRET_TYPE.ULTRA then
            for _, entry in ipairs(candidate.entries) do
              if entry.source_lid == lid and entry.doorslot ~= nil then
                has_tear_candidate = true
                break
              end
            end
          end
          if has_tear_candidate then break end
        end
      end
    end
    return has_tear_candidate
  end

  local function has_breaking_tear_source()
    if data_miner_used_here then return true end
    local game = Game()
    local frame = game:GetFrameCount()
    if breaking_source_frame ~= frame then
      breaking_source_frame, held_breaking_source = frame, false
      for index = 0, game:GetNumPlayers() - 1 do
        local player = Isaac.GetPlayer(index)
        if player and player:Exists() then
          for _, item in ipairs(breaking_tear_sources) do
            if player:HasCollectible(item) then
              held_breaking_source = true
              break
            end
          end
        end
        if held_breaking_source then break end
      end
    end
    return held_breaking_source
  end

  local function inspect_breaking_tears()
    return enabled() and not state.is_ignored()
      and has_breaking_tear_source() and has_fake_candidate_here()
  end

  gt:AddCallback(ModCallbacks.MC_USE_ITEM, function(_, item)
    if item == CollectibleType.COLLECTIBLE_DATAMINER then
      data_miner_used_here = true
    end
  end, CollectibleType.COLLECTIBLE_DATAMINER)
  gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    data_miner_used_here = false
    breaking_source_frame = nil
    tear_candidate_room = nil
  end)
  gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function()
    data_miner_used_here = false
    breaking_source_frame = nil
    tear_candidate_room = nil
  end)

  local function breakable_tear_hit(tear)
    if not inspect_breaking_tears() then return end
    if tear:HasTearFlags(TearFlags.TEAR_ACID)
      or tear:HasTearFlags(TearFlags.TEAR_ROCK) then
      hit(tear, 'tear')
    end
  end

  -- 激光不会触发泪弹网格碰撞回调。直线光束用终点，圆环用圆周；
  -- 不能把激光的 Position 当作直线光束的墙面命中点。
  gt:AddCallback(ModCallbacks.MC_POST_LASER_UPDATE, function(_, laser)
    if not inspect_breaking_tears() then return end
    if not (laser:HasTearFlags(TearFlags.TEAR_ACID)
      or laser:HasTearFlags(TearFlags.TEAR_ROCK)) then return end

    local radius = 20 + math.min(laser.Size or 0, 20)
    local position, ring_radius
    if laser:IsCircleLaser() then
      -- IsaacDocs 的 No Impact 仅指没有命中特效，不能推导为无碰撞。
      -- 子类型 4（如 Tech Zero）的破墙行为尚未真机确认，暂不据其删除候选。
      if laser.SubType == 4 then return end
      position, ring_radius = laser.Position, laser.Radius
      if not ring_radius or ring_radius <= 0 then return end
    else
      position = laser:GetEndPoint()
    end
    if position and room.wall_hit_check(position, radius, ring_radius, true) then
      render.refresh()
    end
  end)

  if REPENTOGON and ModCallbacks.MC_TEAR_GRID_COLLISION then
    -- REPENTOGON reports the actual grid impact, so no tear update polling.
    gt:AddCallback(ModCallbacks.MC_TEAR_GRID_COLLISION,
      function(_, tear) breakable_tear_hit(tear) end)
  else
    -- The base API has no tear/grid impact callback. Skip flag checks in rooms
    -- without a candidate or a source item, then retain the collision fallback.
    gt:AddCallback(ModCallbacks.MC_POST_TEAR_UPDATE, function(_, tear)
      if not inspect_breaking_tears() then return end
      if tear:HasTearFlags(TearFlags.TEAR_ACID)
        or tear:HasTearFlags(TearFlags.TEAR_ROCK) then
        if tear:CollidesWithGrid() then hit(tear, 'tear') end
      end
    end)
  end
  gt:AddCallback(ModCallbacks.MC_POST_KNIFE_UPDATE, function(_, knife)
    if not enabled() or state.is_ignored() then return end
    local parent = type(knife.GetHitboxParentKnife) == 'function' and knife:GetHitboxParentKnife() or nil
    local weapon = parent or knife
    if weapon.Variant ~= axe_variant then return end
    local swinging = type(weapon.GetIsSwinging) == 'function' and weapon:GetIsSwinging() or false
    local flying = type(weapon.IsFlying) == 'function' and weapon:IsFlying() or false
    -- 排障探针仅调试模式执行，普通游戏不构造字符串或访问日志去重表。
    if gt.is_debug and gt:is_debug() then pcall(function()
      local key = tostring(knife.Variant) .. '|' .. tostring(knife.SubType) .. '|'
        .. tostring(parent ~= nil) .. '|' .. tostring(swinging) .. '|' .. tostring(flying)
        .. '|' .. tostring(enabled()) .. '|' .. tostring(state.is_ignored())
      if axe_probes[knife] == key then return end
      axe_probes[knife] = key
      Isaac.DebugString('[GTPdelver] knife-probe variant=' .. tostring(knife.Variant)
        .. ' subtype=' .. tostring(knife.SubType) .. ' parentVariant=' .. tostring(weapon.Variant)
        .. ' hitbox=' .. tostring(parent ~= nil) .. ' swinging=' .. tostring(swinging)
        .. ' flying=' .. tostring(flying) .. ' rgon=' .. tostring(REPENTOGON ~= nil)
        .. ' enabled=' .. tostring(enabled()) .. ' ignored=' .. tostring(state.is_ignored())
        .. ' x=' .. tostring(knife.Position.X) .. ' y=' .. tostring(knife.Position.Y)
        .. ' size=' .. tostring(knife.Size))
    end) end
    -- 挥击命中盒是独立 Knife，Variant 不必等于铁镐；先找母体再识别武器。
    -- 命中盒由挥击产生，其自身位置/尺寸才是攻击区域；母体这一帧可能已结束挥动。
    local native_hitbox = knife.SubType == 4 -- 官方 KnifeSubType.CLUB_HITBOX
    if parent or swinging or flying or native_hitbox then
      hit(knife, parent and 'axe-hitbox' or 'axe')
    end
  end)
end
