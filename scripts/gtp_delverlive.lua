-- 同房间现场更新：揭露标志变化，以及真正撞网格的破墙泪弹/挥动中的铁镐。
-- HasTearFlags/CollidesWithGrid：IsaacDocs EntityTear/Entity；
-- GetIsSwinging/GetHitboxParentKnife/NOTCHED_AXE：REPENTOGON EntityKnife/KnifeVariant。
return function(gt, state, map, room, render, enabled)
  local visibility = require('scripts.gtp_delvervisibility')
  -- 实体 Variant 9 是铁镐；KnifeVariant 的命名枚举由 REPENTOGON 添加，原版不存在。
  local axe_variant = (KnifeVariant and KnifeVariant.NOTCHED_AXE) or 9
  pcall(function()
    Isaac.DebugString('[GTPdelver] live-probe rgon=' .. tostring(REPENTOGON ~= nil)
      .. ' axeVariant=' .. tostring(axe_variant))
  end)
  local previous_map, previous_dimension, flags, real_rooms = nil, nil, {}, {}
  local axe_probes = setmetatable({}, {__mode='k'})
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
  gt:AddCallback(ModCallbacks.MC_POST_TEAR_UPDATE, function(_, tear)
    if not enabled() or state.is_ignored() then return end
    if not tear:HasTearFlags(TearFlags.TEAR_ACID) and not tear:HasTearFlags(TearFlags.TEAR_ROCK) then return end
    if tear:CollidesWithGrid() then hit(tear, 'tear') end
  end)
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
