-- GoodTripPlus
-- 基于 Goodtrip MLX's Tweak（workshop 3749565569）修改的 minimap 传送模组。
--
-- 与 MLX's Tweak 的差别：
--   1. 修复了控制台 rewind 之后小地图掉落物图标全部消失的问题（scripts/gtp_rewindfix.lua）
--   2. 合并了 Lazy Delver 的隐藏房候选标记功能，并把标记对齐到 MinimapAPI 的真实布局
--      （scripts/gtp_delver.lua + scripts/delver/，MIT，见 scripts/delver/LICENSE-lazy-delver.txt）
--   3. 标记深牢 II 里那个炸掉固定掉愚者卡牌的特殊骷髅所在的房间（scripts/gtp_skullroom.lua）

require("scripts.gtrep")
require("scripts.gtp_rewindfix")
require("scripts.gtp_delver")
require("scripts.gtp_skullroom")
