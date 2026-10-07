---@module "scripts.delver.state"

local C = require("scripts.delver.const")
local log = require("scripts.delver.log")

local M = {}

---@type integer?
local seed = nil
---@type LevelStage?
local stage = nil
---@type StageType?
local stage_type = nil
local room_count = nil

local dimension = C.DIMENSION.MAIN
function M.get_dimension() return dimension end

local has_changed = true
function M.has_changed() return has_changed end
function M.done() has_changed = false end

local ignored = false
function M.is_ignored()
  return ignored or has_changed or dimension == C.DIMENSION.OTHER
end

local lost_cursed = false
function M.is_lost_cursed() return lost_cursed end
local off_grid    = false
function M.is_off_grid() return off_grid end


M.items = {
  active = {
    { mc = ModCallbacks.MC_USE_ITEM, type = CollectibleType.COLLECTIBLE_CRYSTAL_BALL,    clear = false },
    { mc = ModCallbacks.MC_USE_ITEM, type = CollectibleType.COLLECTIBLE_BOOK_OF_SECRETS, clear = false },
    { mc = ModCallbacks.MC_USE_ITEM, type = CollectibleType.COLLECTIBLE_DADS_KEY,        clear = true },
    { mc = ModCallbacks.MC_USE_ITEM, type = CollectibleType.COLLECTIBLE_RED_KEY,         clear = false },

    { mc = ModCallbacks.MC_USE_CARD, type = Card.CARD_SUN,             clear = false },
    { mc = ModCallbacks.MC_USE_CARD, type = Card.CARD_WORLD,           clear = false },
    { mc = ModCallbacks.MC_USE_CARD, type = Card.RUNE_ANSUZ,           clear = false },
    { mc = ModCallbacks.MC_USE_CARD, type = Card.CARD_GET_OUT_OF_JAIL, clear = true },
    { mc = ModCallbacks.MC_USE_CARD, type = Card.CARD_CRACKED_KEY,     clear = false },
    { mc = ModCallbacks.MC_USE_CARD, type = Card.CARD_SOUL_CAIN,       clear = true },

    { mc = ModCallbacks.MC_USE_PILL, type = PillEffect.PILLEFFECT_SEE_FOREVER, clear = false },
  },
  passive = {
    [CollectibleType.COLLECTIBLE_BLUE_MAP]      = { reveal = true,  possess = false },
    [CollectibleType.COLLECTIBLE_XRAY_VISION]   = { reveal = true,  possess = false },
    [CollectibleType.COLLECTIBLE_MIND]          = { reveal = true,  possess = false },
    [CollectibleType.COLLECTIBLE_DOG_TOOTH]     = { reveal = false, possess = false },
    [CollectibleType.COLLECTIBLE_YO_LISTEN]     = { reveal = false, possess = false },
    [CollectibleType.COLLECTIBLE_SPELUNKER_HAT] = { reveal = false, possess = false },
  },
  red = {
    [CollectibleType.COLLECTIBLE_RED_KEY] = { possess = false },
    [Card.CARD_CRACKED_KEY]               = { possess = false },
    [Card.CARD_SOUL_CAIN]                 = { possess = false },
  },
}


function M.can_see_entrance()
  local can_see = false
  for _, item in pairs(M.items.passive) do
    if not item.reveal and item.possess then
      can_see = true
      break
    end
  end
  return can_see or Game():GetLevel():GetCanSeeEverything()
end

function M.can_see_red()
  local can_see = false
  for _, param in pairs(M.items.red) do
    if param.possess then can_see = true end
  end
  return can_see
end

---@param level Level
local function get_current_dimension(level)
  local desc = level:GetCurrentRoomDesc()
  if not desc or not desc.Data then
    return C.DIMENSION.MAIN
  end
  for dim = 1, 2 do
    local dim_desc = level:GetRoomByIdx(desc.SafeGridIndex, dim)
    if dim_desc and dim_desc.Data and
       GetPtrHash(dim_desc) == GetPtrHash(desc) then
      if dim == 1 and stage == LevelStage.STAGE1_2 and
         (stage_type == StageType.STAGETYPE_REPENTANCE or
          stage_type == StageType.STAGETYPE_REPENTANCE_B) then
        return C.DIMENSION.MIRROR
      else
        return C.DIMENSION.OTHER
      end
    end
  end
  return C.DIMENSION.MAIN
end


---@param level Level
function M.update(level)
  stage = level:GetStage()
  seed = Game():GetSeeds():GetStageSeed(stage)
  stage_type = level:GetStageType()
  room_count = level:GetRooms().Size
  dimension = get_current_dimension(level)
  lost_cursed = level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST ~= 0
  off_grid = level:GetCurrentRoomDesc().GridIndex < 0
  for type, _ in pairs(M.items.passive) do
    M.items.passive[type].possess = false
  end

  log.new_level(stage, stage_type):info()

  if level:IsAscent() or
     level:GetStage() == LevelStage.STAGE8 or
     Game():IsGreedMode() then
    ignored = true
    log.info("This level was ignored.")
    return
  else
    ignored = false
  end
end

function M.check()
  if has_changed then return end

  local level = Game():GetLevel()
  local current_stage = level:GetStage()
  local current_stage_type = level:GetStageType()
  if Game():GetSeeds():GetStageSeed(current_stage) ~= seed then
    has_changed = true
  end

  if current_stage ~= stage or current_stage_type ~= stage_type then
    has_changed = true
  end
  -- 神庙逃亡 / 红房生成会改变同层房间列表，种子与 stage 都可能不变。
  if level:GetRooms().Size ~= room_count then
    has_changed = true
  end

  if not has_changed then
    local previous = dimension
    dimension = get_current_dimension(level)
    if previous ~= dimension then
      pcall(function()
        if gt and gt.is_debug and gt:is_debug() then
          Isaac.DebugString('[GTPdelver] dimension ' .. previous .. '->' .. dimension
            .. ' stage=' .. current_stage .. ' rooms=' .. room_count)
        end
      end)
    end
  end

  lost_cursed = level:GetCurses() & LevelCurse.CURSE_OF_THE_LOST ~= 0
  off_grid = level:GetCurrentRoomDesc().GridIndex < 0
end


return M
