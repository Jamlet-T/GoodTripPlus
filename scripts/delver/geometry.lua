---@module "scripts.delver.geometry"

local C = require("scripts.delver.const")

local M = {}

---@type table<LD_Dir, { R: integer, C: integer }>
M.DIR_DELTA = {
  [C.DIR.LEFT]  = { R =  0, C = -1 },
  [C.DIR.UP]    = { R = -1, C =  0 },
  [C.DIR.RIGHT] = { R =  0, C =  1 },
  [C.DIR.DOWN]  = { R =  1, C =  0 },
}

---@type table<RoomShape, integer[]>
-- ⚠️ 锚点是 RoomDescriptor.GridIndex（包围盒左上角），**不是** SafeGridIndex！
-- 对 ROOMSHAPE_LTL（缺左上角），SafeGridIndex = 包围盒左上 + 1（最靠左上的真实格），
-- 拿这张表去加 SafeGridIndex 会把整组格右移一列甚至跨行回绕（2026-10-04 在
-- gtp_mapbounds 踩过：L 形房贴边只画出一格的边界线）。正确用法见 delver/map.lua
-- （+ room_desc.GridIndex）；要「房间实际占哪些格」请改用 gtrep.lua 建的 grid_room。
M.SHAPE_OFFSETS = {
  [RoomShape.ROOMSHAPE_1x1] = { 0 },
  [RoomShape.ROOMSHAPE_IH]  = { 0 },
  [RoomShape.ROOMSHAPE_IV]  = { 0 },
  [RoomShape.ROOMSHAPE_1x2] = { 0, C.MAP.COLS },
  [RoomShape.ROOMSHAPE_IIV] = { 0, C.MAP.COLS },
  [RoomShape.ROOMSHAPE_2x1] = { 0, 1 },
  [RoomShape.ROOMSHAPE_IIH] = { 0, 1 },
  [RoomShape.ROOMSHAPE_2x2] = { 0, 1, C.MAP.COLS, C.MAP.COLS + 1 },
  [RoomShape.ROOMSHAPE_LTL] = { 1, C.MAP.COLS, C.MAP.COLS + 1 },
  [RoomShape.ROOMSHAPE_LTR] = { 0, C.MAP.COLS, C.MAP.COLS + 1 },
  [RoomShape.ROOMSHAPE_LBL] = { 0, 1, C.MAP.COLS + 1 },
  [RoomShape.ROOMSHAPE_LBR] = { 0, 1, C.MAP.COLS },
}

---@type table<RoomShape, table<DoorSlot, integer>>
local NEIGHBOR_OFFSET = {
  [RoomShape.ROOMSHAPE_1x1] = {
    [DoorSlot.LEFT0]  =  0 * C.MAP.COLS - 1,
    [DoorSlot.UP0]    = -1 * C.MAP.COLS,
    [DoorSlot.RIGHT0] =  0 * C.MAP.COLS + 1,
    [DoorSlot.DOWN0]  =  1 * C.MAP.COLS,
  },
  [RoomShape.ROOMSHAPE_IH] = {
    [DoorSlot.LEFT0]  = 0 * C.MAP.COLS - 1,
    [DoorSlot.RIGHT0] = 0 * C.MAP.COLS + 1,
  },
  [RoomShape.ROOMSHAPE_IV] = {
    [DoorSlot.UP0]    = -1 * C.MAP.COLS,
    [DoorSlot.DOWN0]  =  1 * C.MAP.COLS,
  },
  [RoomShape.ROOMSHAPE_1x2] = {
    [DoorSlot.LEFT0]  =  0 * C.MAP.COLS - 1,
    [DoorSlot.UP0]    = -1 * C.MAP.COLS,
    [DoorSlot.RIGHT0] =  0 * C.MAP.COLS + 1,
    [DoorSlot.DOWN0]  =  2 * C.MAP.COLS,
    [DoorSlot.LEFT1]  =  1 * C.MAP.COLS - 1,
    [DoorSlot.RIGHT1] =  1 * C.MAP.COLS + 1,
  },
  [RoomShape.ROOMSHAPE_IIV] = {
    [DoorSlot.UP0]    = -1 * C.MAP.COLS,
    [DoorSlot.DOWN0]  =  2 * C.MAP.COLS,
  },
  [RoomShape.ROOMSHAPE_2x1] = {
    [DoorSlot.LEFT0]  =  0 * C.MAP.COLS - 1,
    [DoorSlot.UP0]    = -1 * C.MAP.COLS,
    [DoorSlot.RIGHT0] =  0 * C.MAP.COLS + 2,
    [DoorSlot.DOWN0]  =  1 * C.MAP.COLS,
    [DoorSlot.UP1]    = -1 * C.MAP.COLS + 1,
    [DoorSlot.DOWN1]  =  1 * C.MAP.COLS + 1,
  },
  [RoomShape.ROOMSHAPE_IIH] = {
    [DoorSlot.LEFT0]  =  0 * C.MAP.COLS - 1,
    [DoorSlot.RIGHT0] =  0 * C.MAP.COLS + 2,
  },
  [RoomShape.ROOMSHAPE_2x2] = {
    [DoorSlot.LEFT0]  =  0 * C.MAP.COLS - 1,
    [DoorSlot.UP0]    = -1 * C.MAP.COLS,
    [DoorSlot.RIGHT0] =  0 * C.MAP.COLS + 2,
    [DoorSlot.DOWN0]  =  2 * C.MAP.COLS,
    [DoorSlot.LEFT1]  =  1 * C.MAP.COLS - 1,
    [DoorSlot.UP1]    = -1 * C.MAP.COLS + 1,
    [DoorSlot.RIGHT1] =  1 * C.MAP.COLS + 2,
    [DoorSlot.DOWN1]  =  2 * C.MAP.COLS + 1,
  },
  [RoomShape.ROOMSHAPE_LTL] = {
    [DoorSlot.LEFT0]  =  0 * C.MAP.COLS,
    [DoorSlot.UP0]    =  0 * C.MAP.COLS,
    [DoorSlot.RIGHT0] =  0 * C.MAP.COLS + 2,
    [DoorSlot.DOWN0]  =  2 * C.MAP.COLS,
    [DoorSlot.LEFT1]  =  1 * C.MAP.COLS - 1,
    [DoorSlot.UP1]    = -1 * C.MAP.COLS + 1,
    [DoorSlot.RIGHT1] =  1 * C.MAP.COLS + 2,
    [DoorSlot.DOWN1]  =  2 * C.MAP.COLS + 1,
  },
  [RoomShape.ROOMSHAPE_LTR] = {
    [DoorSlot.LEFT0]  =  0 * C.MAP.COLS - 1,
    [DoorSlot.UP0]    = -1 * C.MAP.COLS,
    [DoorSlot.RIGHT0] =  0 * C.MAP.COLS + 1,
    [DoorSlot.DOWN0]  =  2 * C.MAP.COLS,
    [DoorSlot.LEFT1]  =  1 * C.MAP.COLS - 1,
    [DoorSlot.UP1]    =  0 * C.MAP.COLS + 1,
    [DoorSlot.RIGHT1] =  1 * C.MAP.COLS + 2,
    [DoorSlot.DOWN1]  =  2 * C.MAP.COLS + 1,
  },
  [RoomShape.ROOMSHAPE_LBL] = {
    [DoorSlot.LEFT0]  =  0 * C.MAP.COLS - 1,
    [DoorSlot.UP0]    = -1 * C.MAP.COLS,
    [DoorSlot.RIGHT0] =  0 * C.MAP.COLS + 2,
    [DoorSlot.DOWN0]  =  1 * C.MAP.COLS,
    [DoorSlot.LEFT1]  =  1 * C.MAP.COLS,
    [DoorSlot.UP1]    = -1 * C.MAP.COLS + 1,
    [DoorSlot.RIGHT1] =  1 * C.MAP.COLS + 2,
    [DoorSlot.DOWN1]  =  2 * C.MAP.COLS + 1,
  },
  [RoomShape.ROOMSHAPE_LBR] = {
    [DoorSlot.LEFT0]  =  0 * C.MAP.COLS - 1,
    [DoorSlot.UP0]    = -1 * C.MAP.COLS,
    [DoorSlot.RIGHT0] =  0 * C.MAP.COLS + 2,
    [DoorSlot.DOWN0]  =  2 * C.MAP.COLS,
    [DoorSlot.LEFT1]  =  1 * C.MAP.COLS - 1,
    [DoorSlot.UP1]    = -1 * C.MAP.COLS + 1,
    [DoorSlot.RIGHT1] =  1 * C.MAP.COLS + 1,
    [DoorSlot.DOWN1]  =  1 * C.MAP.COLS + 1,
  },
}

---@param dir LD_Dir
---@param offset integer cid - tl_cid
---@param shape RoomShape
---@return DoorSlot?
function M.get_doorslot(dir, offset, shape)
  local values = NEIGHBOR_OFFSET[shape]
  if not values then return nil end
  for slot, value in pairs(values) do
    if dir == slot % 4 and offset == value then return slot end
  end
  return nil
end

---@param cid LD_Cid
---@return table<LD_Dir, LD_Cid>
function M.get_neighbors(cid)
  local neighbors = {}
  local col = cid % C.MAP.COLS
  if col > 0 then
    neighbors[C.DIR.LEFT] = cid + C.CELL.DIR_OFFSETS[C.DIR.LEFT]
  end
  if col < C.MAP.COLS - 1 then
    neighbors[C.DIR.RIGHT] = cid + C.CELL.DIR_OFFSETS[C.DIR.RIGHT]
  end
  if cid >= C.MAP.COLS then
    neighbors[C.DIR.UP] = cid + C.CELL.DIR_OFFSETS[C.DIR.UP]
  end
  if cid < C.MAP.SIZE - C.MAP.COLS then
    neighbors[C.DIR.DOWN] = cid + C.CELL.DIR_OFFSETS[C.DIR.DOWN]
  end

  return neighbors
end

return M
