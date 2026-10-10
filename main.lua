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
--      （scripts/gtp_bosswindow.lua，常开；登记 ① departure 段的规则实现）
--   7. 地图边界房间高亮：按住地图键时，把贴着 13×13 边界的房间外沿画出来
--      （scripts/gtp_mapbounds.lua，默认开启；素材 resources/gfx/goodtripplus/bounds.*）
--   8. 虚空层标记精神错乱的 boss 房（scripts/gtp_delirium.lua，默认关闭；
--      素材 resources/gfx/goodtripplus/Delirium.*）
--   9. 矿洞 II 标记黄色轨道按钮（Rail Plate）所在的房间：踩下全层 3 个按钮才
--      放行刀片碎片 2 的轨道桥；房间一显示在地图上就标注，按钮踩下后图标自动消失
--      （scripts/gtp_minebuttons.lua，默认开启；素材 resources/gfx/goodtripplus/MineButton.*）
--  10. 禁止传送进诅咒房（scripts/gtp_curseblock.lua，默认开启；恢复移植基底 MLX's Tweak
--      的 BlockCurseRoom 选项 —— 早期移植时漏掉，导致已探索的诅咒房能被直接传送进去）。
--      关掉该选项后诅咒房完全按普通房间处理（gtrep 的 check_neigh_connected 白名单同步放行）
--  11. 隐藏房候选门框（scripts/gtp_secretoutlines.lua）：白／金／红门框、狗牙与踩踏线索、
--      迷失诅咒下继续显示，以及与红钥匙门框重叠时交替显示。

require("scripts.gtrep")
require("scripts.gtp_combatmap")(gt, MinimapAPI)
require("scripts.gtp_distancefix")(MinimapAPI)
require("scripts.gtp_boundedshadow")(MinimapAPI)
-- 传送判定策略层（2026-10-06 起）：四段规则表 + check 入口 + 调试浮层。
-- 必须在 gtrep 之后 —— 它要拿 gtrep 定义的 gt 表与访问器。
require("scripts.gtp_travel")
-- 门图状态的序列化（纯函数；存档读写与时机在 gtrep 里）
require("scripts.gtp_persist")
require("scripts.gtp_store")(gt)
require("scripts.gtp_rewindfix")
require("scripts.gtp_triprewindprobe")(gt)
require("scripts.gtp_delver")
require("scripts.gtp_secretoutlines")(gt)
require("scripts.gtp_skullroom")
-- 传送判定的两个外挂规则模块：都在 gtp_travel 之后 —— 它们要调 gt:add_travel_rule 登记规则
-- （2026-10-06 起不再包装 gt.check_teleble）。规则在段内的位置由各自的 order 决定，
-- 所以这两个文件的加载顺序怎样都不影响判定顺序。
require("scripts.gtp_bosswindow")
require("scripts.gtp_curseblock")
require("scripts.gtp_mapbounds")
require("scripts.gtp_delirium")
require("scripts.gtp_minebuttons")
require("scripts.gtp_mapmemory")
