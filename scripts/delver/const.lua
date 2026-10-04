---@module "scripts.delver.const"

local M = {}

-- GENERAL

---@enum LD_Dimension
M.DIMENSION = {
  MAIN   = 0,
  MIRROR = 1,
  OTHER  = 2,
}

---@enum LD_Dir
M.DIR = {
  LEFT  = DoorSlot.LEFT0,
  UP    = DoorSlot.UP0,
  RIGHT = DoorSlot.RIGHT0,
  DOWN  = DoorSlot.DOWN0,
}

---@enum LD_SecretType
M.SECRET_TYPE = {
  REGULAR = RoomType.ROOM_SECRET,
  SUPER = RoomType.ROOM_SUPERSECRET,
  ULTRA = RoomType.ROOM_ULTRASECRET,
}

-- MAP

M.MAP = {}

---@type integer
M.MAP.COLS = 13
---@type integer
M.MAP.ROWS = 13
---@type integer
M.MAP.SIZE = M.MAP.COLS * M.MAP.ROWS

-- CELL

M.CELL = {}

---@type table<LD_Dir, integer>
M.CELL.DIR_OFFSETS = {
  [M.DIR.LEFT]  = -1,
  [M.DIR.UP]    = -M.MAP.COLS,
  [M.DIR.RIGHT] = 1,
  [M.DIR.DOWN]  = M.MAP.COLS,
}

---@enum LD_CellCategory
M.CELL.CATEGORY = {
  NORMAL = 1,
  SPECIAL = 2,
  BOSS = 3,
  SECRET = 4,
}

---@type table<RoomType, LD_CellCategory>
M.CELL.ROOM_TYPE_TO_CATEGORY = {
  [RoomType.ROOM_DEFAULT]         = M.CELL.CATEGORY.NORMAL,
  [RoomType.ROOM_SHOP]            = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_ERROR]           = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_TREASURE]        = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_BOSS]            = M.CELL.CATEGORY.BOSS,
  [RoomType.ROOM_MINIBOSS]        = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_SECRET]          = M.CELL.CATEGORY.SECRET,
  [RoomType.ROOM_SUPERSECRET]     = M.CELL.CATEGORY.SECRET,
  [RoomType.ROOM_ARCADE]          = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_CURSE]           = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_CHALLENGE]       = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_LIBRARY]         = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_SACRIFICE]       = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_DEVIL]           = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_ANGEL]           = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_DUNGEON]         = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_BOSSRUSH]        = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_ISAACS]          = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_BARREN]          = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_CHEST]           = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_DICE]            = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_BLACK_MARKET]    = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_GREED_EXIT]      = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_PLANETARIUM]     = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_TELEPORTER]      = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_TELEPORTER_EXIT] = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_SECRET_EXIT]     = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_BLUE]            = M.CELL.CATEGORY.SPECIAL,
  [RoomType.ROOM_ULTRASECRET]     = M.CELL.CATEGORY.SECRET,
}

--- ROOM_ENTITY

M.ROOM_ENTITY = {}

---@type table<EntityType, boolean>
M.ROOM_ENTITY.IS_BLOCKED = {
  [EntityType.ENTITY_FIREPLACE]              = true,
  [EntityType.ENTITY_MOVABLE_TNT]            = true,
  [EntityType.ENTITY_STONEHEAD]              = true,
  [EntityType.ENTITY_GAPING_MAW]             = true,
  [EntityType.ENTITY_BROKEN_GAPING_MAW]      = true,
  [EntityType.ENTITY_CONSTANT_STONE_SHOOTER] = true,
  [EntityType.ENTITY_QUAKE_GRIMACE]          = true,
  [EntityType.ENTITY_BOMB_GRIMACE]           = true,
  [EntityType.ENTITY_BRIMSTONE_HEAD]         = true,
  [EntityType.ENTITY_STONE_EYE]              = true,
}

--- GRID_ENTITY

M.GRID_ENTITY = {}

---@type table<GridEntityType, boolean>
M.GRID_ENTITY.NOT_BLOCKED = {
  [GridEntityType.GRID_NULL]       = true,
  [GridEntityType.GRID_DECORATION] = true,
  [GridEntityType.GRID_SPIDERWEB]  = true,
}

--- MARKER

M.MARKER = {}

---@enum LD_MarkerStatus
M.MARKER.STATUS = {
  HIDDEN = 0,
  DIM    = 1,
  BRIGHT = 2,
  FOUND  = 3,
}
---@type table<LD_MarkerStatus, number>
M.MARKER.ALPHA = {
  [M.MARKER.STATUS.HIDDEN] = 0.0,
  [M.MARKER.STATUS.DIM]    = 0.36,
  [M.MARKER.STATUS.BRIGHT] = 1.0,
  [M.MARKER.STATUS.FOUND]  = 0.0,
}
---@type table<LD_SecretType, number[]>
M.MARKER.COLORS = {
  [M.SECRET_TYPE.REGULAR] = { 1.0, 1.0, 1.0 },
  [M.SECRET_TYPE.SUPER]   = { 1.0, 0.84, 0.0 },
  [M.SECRET_TYPE.ULTRA]   = { 1.0, 0.0, 0.0 },
}

return M
