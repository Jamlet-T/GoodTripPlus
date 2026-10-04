-- GoodTripPlus
-- 基于 Goodtrip MLX's Tweak（workshop 3749565569）修改的 minimap 传送模组。
-- 定位：MinimapAPI 的外置传送插件（2026-10-03 起），只搭 GoodTrip 的传送玩法。
--
-- 与 MLX's Tweak 的差别：
--   1. 修复了控制台 rewind 之后小地图掉落物图标全部消失的问题（scripts/gtp_rewindfix.lua）
--   2. 合并了 Lazy Delver 的隐藏房候选标记功能，并把标记对齐到 MinimapAPI 的真实布局
--      （scripts/gtp_delver.lua + scripts/delver/，MIT，见 scripts/delver/LICENSE-lazy-delver.txt）
--   3. 标记深牢 II 里那个炸掉固定掉愚者卡牌的特殊骷髅所在的房间（scripts/gtp_skullroom.lua）
--   4. （已移除）初始房高亮与战斗跟随逻辑：初始房高亮改用 MinimapAPI 自带的
--      HighlightStartRoom（原 gtp_combatmap.lua 的存在意义随之消失）；
--      其余自绘元素（光标/光标房高亮/标记）均有按键与清房门控，战斗中本就不绘制
--   5. （已移除）大地图黑边修复 gtp_mapoutline.lua——2026-10-03 定位收缩时删去，
--      遇黑边请关 MinimapAPI 菜单里的 "Show Room Outlines"
--   6. 当前房间里出现「通往奖励房间的门」（恶魔房 / 天使房 / Boss Rush / 死寂）时禁用传送
--      （scripts/gtp_bosswindow.lua，常开；包装 check_teleble 实现，不改 gtrep.lua）
--   7. 地图边界房间高亮：按住地图键时，把贴着 13×13 边界的房间外沿画出来
--      （scripts/gtp_mapbounds.lua，默认开启；素材 resources/gfx/goodtripplus/bounds.*）
--   8. 虚空层标记精神错乱的 boss 房（scripts/gtp_delirium.lua，默认关闭；
--      素材 resources/gfx/goodtripplus/Delirium.*）

require("scripts.gtrep")
require("scripts.gtp_rewindfix")
require("scripts.gtp_delver")
require("scripts.gtp_skullroom")
-- 必须放在 gtrep 之后：它包一层 gt.check_teleble
require("scripts.gtp_bosswindow")
require("scripts.gtp_mapbounds")
require("scripts.gtp_delirium")
