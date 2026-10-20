-- 红钥匙类「能开红房」来源的实时判定，供隐藏房候选与候选门框共用。
--
-- 覆盖两种持有形态：
--   * 红钥匙（580）在主动槽、碎裂钥匙 / 该隐的魂石在卡牌槽；
--   * 虚空（477）吸收了红钥匙 —— 红钥匙本体已不在主动槽，但虚空获得其使用效果，
--     游戏仍会显示红门框、仍能开红房。
--
-- 虚空吸收列表的读取分两条路：
--   * REPENTOGON：EntityPlayer:VoidHasCollectible，与游戏自身判定同源（权威）；
--   * 原版：游戏不暴露该列表，改为在 MC_PRE_USE_ITEM(477) 时扫描房间里的道具底座
--     与「举在头顶待入包」的道具，MC_USE_ITEM(477) 确认后记到 player:GetData()。
--     记录随整局保留：写入 SaveData 的 'voided' 分区（gtp_store 会跨楼层携带），
--     继续游戏时恢复到新的玩家实体；新开一局（含重开）清空。
--     Genesis 会重置虚空吸收列表，因此使用 Genesis 时同步清除记录。
--     Abyss 被虚空触发时会销毁房间道具而不进虚空列表，同样跳过记录。
--     Glowing Hour Glass 回滚时按 voided items 的做法恢复进房时的备份。

local M = {}

local mod, pending, abyss_use = nil, {}, {}
local hourglass_reversing, hourglass_used = false, false

local function player_key(player)
  if GetPtrHash then return GetPtrHash(player) end
  return player and player.InitSeed
end

local function player_data(player)
  if not player or not player.GetData then return nil end
  local ok, data = pcall(function() return player:GetData() end)
  return ok and data or nil
end

local function tracked_red_key(player)
  local data = player_data(player)
  return data ~= nil and data.gtp_voided_red_key == true
end

local function set_tracked(player, value)
  local data = player_data(player)
  if data then data.gtp_voided_red_key = value or nil end
end

-- 持久化：'voided' 分区按玩家序号记录（逗号分隔），由 gtp_store 跨楼层保留，
-- 继续游戏时恢复，新开一局清空。与 voided items 的生命周期一致。
local function tracked_players()
  local ids = {}
  local game = Game()
  if not game then return '' end
  for index = 0, game:GetNumPlayers() - 1 do
    if tracked_red_key(Isaac.GetPlayer(index)) then
      ids[#ids + 1] = tostring(index)
    end
  end
  return table.concat(ids, ',')
end

local function persist_tracked()
  if mod and mod.persist_save_section then
    pcall(mod.persist_save_section, mod, 'voided', tracked_players())
  end
end

local function restore_tracked()
  if not mod or not mod.persist_get_section then return end
  local ok, text = pcall(mod.persist_get_section, mod, 'voided')
  if not ok or type(text) ~= 'string' then return end
  for index in text:gmatch('%d+') do
    local player = Isaac.GetPlayer(tonumber(index))
    if player then set_tracked(player, true) end
  end
end

local function queued_red_key(player)
  local queued = player.QueuedItem
  return queued ~= nil and queued.Item ~= nil
    and queued.Item.ID == CollectibleType.COLLECTIBLE_RED_KEY
end

-- 虚空会吸收房间内所有非商店道具底座；商店道具要先买下（举在头顶）才会被吸收。
local function room_has_red_key()
  for _, entity in ipairs(Isaac.FindByType(EntityType.ENTITY_PICKUP,
    PickupVariant.PICKUP_COLLECTIBLE)) do
    local pickup = entity:ToPickup()
    if pickup and pickup.SubType == CollectibleType.COLLECTIBLE_RED_KEY
      and not pickup:IsShopItem() then
      return true
    end
  end
  return false
end

--- 注册原版跟踪回调；由 main.lua 在装配阶段调用一次。
function M.register(gt)
  mod = gt

  gt:AddCallback(ModCallbacks.MC_PRE_USE_ITEM, function(_, item, _, player)
    if item ~= CollectibleType.COLLECTIBLE_VOID or not player then return end
    local key = player_key(player)
    abyss_use[key] = nil
    pending[key] = (queued_red_key(player) or room_has_red_key()) or nil
  end, CollectibleType.COLLECTIBLE_VOID)

  gt:AddCallback(ModCallbacks.MC_USE_ITEM, function(_, item, _, player, use_flags)
    if not player then return end
    local key = player_key(player)
    if item == CollectibleType.COLLECTIBLE_VOID then
      if pending[key] and not abyss_use[key] then
        local data = player_data(player)
        if data and not data.gtp_voided_red_key then
          data.gtp_voided_red_key = true
          persist_tracked()
        end
      end
      pending[key], abyss_use[key] = nil, nil
    elseif item == CollectibleType.COLLECTIBLE_ABYSS
      and use_flags and UseFlag and UseFlag.USE_VOID
      and (use_flags & UseFlag.USE_VOID) ~= 0 then
      abyss_use[key] = true
    elseif item == CollectibleType.COLLECTIBLE_GENESIS then
      local data = player_data(player)
      if data and data.gtp_voided_red_key then
        data.gtp_voided_red_key = nil
        persist_tracked()
      end
    elseif item == CollectibleType.COLLECTIBLE_GLOWING_HOUR_GLASS then
      if hourglass_reversing then hourglass_used = true end
      hourglass_reversing = false
    end
  end)

  -- Glowing Hour Glass 回滚：与 voided items 一致，进房备份，回到房间时恢复。
  gt:AddCallback(ModCallbacks.MC_PRE_USE_ITEM, function(_, item, _, player, _, slot)
    if item ~= CollectibleType.COLLECTIBLE_GLOWING_HOUR_GLASS or not player then
      return
    end
    local reversing = true
    if slot ~= nil and slot ~= -1 and player.GetActiveCharge then
      reversing = player:GetActiveCharge(slot) <= 0
    end
    hourglass_reversing = reversing
  end, CollectibleType.COLLECTIBLE_GLOWING_HOUR_GLASS)

  gt:AddCallback(ModCallbacks.MC_POST_NEW_ROOM, function()
    local game = Game()
    if not game then return end
    for index = 0, game:GetNumPlayers() - 1 do
      local data = player_data(Isaac.GetPlayer(index))
      if data then
        if hourglass_used then
          data.gtp_voided_red_key = data.gtp_voided_red_key_backup or nil
        else
          data.gtp_voided_red_key_backup = data.gtp_voided_red_key == true
        end
      end
    end
    if hourglass_used then persist_tracked() end
    hourglass_used = false
  end)

  -- 存读档：继续游戏恢复整局记录；新开一局（含重开）清空。
  gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED, function(_, continued)
    if continued then
      restore_tracked()
      return
    end
    local game = Game()
    if game then
      for index = 0, game:GetNumPlayers() - 1 do
        set_tracked(Isaac.GetPlayer(index), false)
      end
    end
    persist_tracked()
  end)

  gt:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT, persist_tracked)
end

function M.has_source()
  local game = Game()
  if not game then return false end
  for index = 0, game:GetNumPlayers() - 1 do
    local player = Isaac.GetPlayer(index)
    -- 玩家实体可能尚未就绪（Exists 会原生崩溃兜底）。
    if player and (not player.Exists or player:Exists()) then
      for slot = 0, 3 do
        local item = player:GetActiveItem(slot)
        if item == CollectibleType.COLLECTIBLE_RED_KEY then
          return true
        end
        if item == CollectibleType.COLLECTIBLE_VOID then
          local native_checked = false
          if REPENTOGON and player.VoidHasCollectible then
            local ok, absorbed = pcall(function()
              return player:VoidHasCollectible(CollectibleType.COLLECTIBLE_RED_KEY)
            end)
            if ok then
              native_checked = true
              if absorbed then return true end
            end
          end
          -- 原生接口不存在或调用失败时，退回本局的自跟踪记录。
          if not native_checked and tracked_red_key(player) then
            return true
          end
        end
        local card = player:GetCard(slot)
        if card == Card.CARD_CRACKED_KEY or card == Card.CARD_SOUL_CAIN then
          return true
        end
      end
    end
  end
  return false
end

return M
