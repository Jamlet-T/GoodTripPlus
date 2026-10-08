---@module "scripts.delver.log"

local C = require("scripts.delver.const")
local geo = require("scripts.delver.geometry")

local M = {}


---@type table<LD_SecretType, table<boolean, string>>
local FAKE_SYM = {
  [C.SECRET_TYPE.REGULAR] = { [true] = " R ", [false] = " r " },
  [C.SECRET_TYPE.SUPER]   = { [true] = " S ", [false] = " s " },
  [C.SECRET_TYPE.ULTRA]   = { [true] = " U ", [false] = " u " },
}
---@type table<LD_SecretType, string>
local SECRET_SYM = {
  [C.SECRET_TYPE.REGULAR] = "<R>",
  [C.SECRET_TYPE.SUPER]   = "<S>",
  [C.SECRET_TYPE.ULTRA]   = "<U>",
}
---@type table<LD_CellCategory, string>
local OTHER_SYM = {
  [C.CELL.CATEGORY.BOSS]    = "B",
  [C.CELL.CATEGORY.NORMAL]  = "N",
  [C.CELL.CATEGORY.SPECIAL] = "C",
  -- SECRET 是必需的：const.lua 把 ROOM_SECRET / ROOM_SUPERSECRET 归到这一档，
  -- 而这里原先没有它 —— 于是打印任何「格子里有隐藏房」的房间都会 nil 拼接崩。
  [C.CELL.CATEGORY.SECRET]  = "S",
}

---@type table<LevelStage, table<StageType, string>>
local STAGE_NAME = {
  [LevelStage.STAGE1_1] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Basement 1",
    [StageType.STAGETYPE_WOTL]         = "Cellar 1",
    [StageType.STAGETYPE_AFTERBIRTH]   = "Burning Basement 1",
    [StageType.STAGETYPE_REPENTANCE]   = "Downpour 1",
    [StageType.STAGETYPE_REPENTANCE_B] = "Dross 1",
  },
  [LevelStage.STAGE1_2] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Basement 2",
    [StageType.STAGETYPE_WOTL]         = "Cellar 2",
    [StageType.STAGETYPE_AFTERBIRTH]   = "Burning Basement 2",
    [StageType.STAGETYPE_REPENTANCE]   = "Downpour 2",
    [StageType.STAGETYPE_REPENTANCE_B] = "Dross 2",
  },
  [LevelStage.STAGE2_1] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Caves 1",
    [StageType.STAGETYPE_WOTL]         = "Catacombs 1",
    [StageType.STAGETYPE_AFTERBIRTH]   = "Flooded Caves 1",
    [StageType.STAGETYPE_REPENTANCE]   = "Mines 1",
    [StageType.STAGETYPE_REPENTANCE_B] = "Ashpit 1",
  },
  [LevelStage.STAGE2_2] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Caves 2",
    [StageType.STAGETYPE_WOTL]         = "Catacombs 2",
    [StageType.STAGETYPE_AFTERBIRTH]   = "Flooded Caves 2",
    [StageType.STAGETYPE_REPENTANCE]   = "Mines 2",
    [StageType.STAGETYPE_REPENTANCE_B] = "Ashpit 2",
  },
  [LevelStage.STAGE3_1] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Depths 1",
    [StageType.STAGETYPE_WOTL]         = "Necropolis 1",
    [StageType.STAGETYPE_AFTERBIRTH]   = "Dank Depths 1",
    [StageType.STAGETYPE_REPENTANCE]   = "Mausoleum 1",
    [StageType.STAGETYPE_REPENTANCE_B] = "Gehenna 1",
  },
  [LevelStage.STAGE3_2] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Depths 2",
    [StageType.STAGETYPE_WOTL]         = "Necropolis 2",
    [StageType.STAGETYPE_AFTERBIRTH]   = "Dank Depths 2",
    [StageType.STAGETYPE_REPENTANCE]   = "Mausoleum 2",
    [StageType.STAGETYPE_REPENTANCE_B] = "Gehenna 2",
  },
  [LevelStage.STAGE4_1] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Womb 1",
    [StageType.STAGETYPE_WOTL]         = "Utero 1",
    [StageType.STAGETYPE_AFTERBIRTH]   = "Scarred Womb 1",
    [StageType.STAGETYPE_REPENTANCE]   = "Corpse 1",
  },
  [LevelStage.STAGE4_2] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Womb 2",
    [StageType.STAGETYPE_WOTL]         = "Utero 2",
    [StageType.STAGETYPE_AFTERBIRTH]   = "Scarred Womb 2",
    [StageType.STAGETYPE_REPENTANCE]   = "Corpse 2",
  },
  [LevelStage.STAGE4_3] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Blue Womb",
  },
  [LevelStage.STAGE5] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Sheol",
    [StageType.STAGETYPE_WOTL]         = "Cathedral",
  },
  [LevelStage.STAGE6] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Dark Room",
    [StageType.STAGETYPE_WOTL]         = "The Chest",
  },
  [LevelStage.STAGE7] = {
    [StageType.STAGETYPE_ORIGINAL]     = "The Void",
  },
  [LevelStage.STAGE8] = {
    [StageType.STAGETYPE_ORIGINAL]     = "Home",
  },
}


---@param s string
function M.info(s)
  -- print(s)
  -- Isaac.DebugString(s)
end
---@param s string
function M.error(s)
  print("[ERROR] " .. s)
  Isaac.DebugString("[ERROR] " .. s)
end

---@class LD_Log
---@field _lines string[]
local Log = {}
Log.__index = Log

---@param lines string[]
---@return LD_Log
function Log:new(lines)
  return setmetatable({ _lines = lines }, self)
end

function Log:info()
  for _, line in ipairs(self._lines) do
    M.info(line)
  end
end

function Log:error()
  for _, line in ipairs(self._lines) do
    M.error(line)
  end
end


function M.new_level(stage, stage_type)
  local stage_name = STAGE_NAME[stage] and STAGE_NAME[stage][stage_type] or
    ("undefined stage " .. tostring(stage) .. " (type: " .. tostring(stage_type) .. ")")
  return Log:new({ "<=== New Level: " .. stage_name .. " ===>" })
end

---@param cid LD_Cid
---@return string
local function to_point(cid)
  return "(" .. cid // C.MAP.COLS .. ", " .. cid % C.MAP.COLS .. ")"
end

---@param cid LD_Cid
---@param map LD_Map
---@return string
local function to_sym(cid, map)
  local cell = map.cells[cid]
  local cand = map.candidates[cid]
  if not cell and not cand then
    return " . "
  end

  if cand then
    if cand.lid then
      return SECRET_SYM[cand.secret_type]
    else
      local checked = true
      for _, entry in ipairs(cand.entries) do
        checked = checked and entry.checked
      end
      return FAKE_SYM[cand.secret_type][checked]
    end
  end

  local offsets = geo.SHAPE_OFFSETS[map.rooms[cell.lid].shape]
  local is_multi = (#offsets > 1)
  local lb, rb = "[", "]"
  if is_multi then
    lb, rb = "{", "}"
  end

  -- 未知分类兜底成 "?"：宁可日志难看一行，也绝不能因为少一个符号就把整个回调带崩。
  -- 2026-10-06 实测：SECRET 没进 OTHER_SYM，矿道里撞上 "get doorslot failed" 那条
  -- 错误分支要打印候选房，直接崩成 "Error in PostRoomLoad call: ... log.lua:180"。
  local sym = OTHER_SYM[cell.category] or "?"
  return lb .. sym .. rb
end


---@param lid LD_Lid
---@param map LD_Map
---@return LD_Log
function M.print_room(lid, map)
  local room = map.rooms[lid]
  if not room then return Log:new({}) end

  local cids = room.cids

  assert(cids[1] ~= nil)
  local sym = to_sym(cids[1], map)

  local parts = {}
  for _, cid in pairs(cids) do
    parts[#parts + 1] = to_point(cid)
  end
  local cells = " " .. table.concat(parts, " ")

  local line = sym .. " room " .. lid ..
              ", type: " .. room.type ..
              ", cells:" .. cells
  return Log:new({ line })
end

---@param map LD_Map
---@return LD_Log
function M.print_map(map)
  local lines = {}

  for lid = 0, #map.rooms do
    if map.rooms[lid].lid == lid then
      local out = M.print_room(lid, map)
      for _, line in ipairs(out._lines) do
        lines[#lines + 1] = line
      end
    end
  end

  for cid, cand in pairs(map.candidates) do
    if not cand.lid then
      lines[#lines + 1] =
        to_sym(cid, map) .. " candidate in cell " .. to_point(cid)
    end
  end

  lines[#lines + 1] = ""
  return Log:new(lines)
end

---@param map LD_Map
---@return LD_Log
function M.draw_map(map)
  local lines = {}

  local header = "       "
  for col = 0, C.MAP.COLS - 1 do
    header = header .. string.format("%2d ", col)
  end
  lines[#lines + 1] = header

  for row = 0, C.MAP.ROWS - 1 do
    local line = string.format("Row %2d:", row)
    for col = 0, C.MAP.COLS - 1 do
      local cid = row * C.MAP.COLS + col
      line = line .. to_sym(cid, map)
    end
    lines[#lines + 1] = line
  end

  lines[#lines + 1] = ""
  return Log:new(lines)
end

return M
