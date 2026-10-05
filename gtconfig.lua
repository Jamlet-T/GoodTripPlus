-- GoodTripPlus - 静态默认值覆盖（优先级低于游戏内 Mod Config Menu）
-- 这里的每一项都可以被 MCM 里的设置覆盖（有对应菜单项的话）。
-- 例外：FastTransition / HighlightCursorRoom 自 2026-10-04 起**不进 MCM 菜单**，
-- 只能在本文件里覆盖（两者默认常开）。
-- 传送准入逻辑为 GoodTrip [Fixed] 的忠实移植，选项与 Fixed 同名同默认值
-- （唯一例外：传送范围把 Fixed 的 AllowNeighborRoom + AllowAnyRoom 两项合并成
--   一个三选一的 TravelMode，默认值等价于 Fixed 的原默认组合）。
gt.FastRestartEnable = true
gt.TeleportAnimation = false

-- 调试模式（诊断 / 开发用，默认关）。**所有调试信息的总闸**：关着时屏幕不画浮层、
-- log 里也不写诊断行（「地图键 + F4」手动入口同样按不动）。两个入口任一为真即开：
--   · 游戏内 Mod Config Menu 的「调试模式」项（推荐，改了立刻生效）；
--   · 本行改成 true —— 文件级强制开。**它优先于 MCM**（与其他选项相反）：
--     MCM 注册时会把默认 false 写进 Config，若不优先则改本文件会没反应。
-- 开启后：按住地图键自动弹诊断浮层、解锁「地图键 + F4」手动 dump、
-- 绕过保护性禁传（道具入口 / 奖励房门）、跳过传送动画。
gt.DebugMod = false

-- 高亮光标下可传送的房间（不进 MCM 菜单，仅本文件可覆盖）
gt.HighlightCursorRoom = true

-- 迷失诅咒下是否禁用传送：**已不再由本文件控制**（2026-10-05 用户要求）。
-- 改为跟随 MinimapAPI 的 OverrideLost（其 MCM 里的 "Display During Curse"，默认关）：
--   · MinimapAPI 在迷失诅咒下照常显示地图 → 传送照常开放；
--   · 地图被诅咒藏起来（默认） → 传送一并停用。
-- 也就是「能不能传」与「看不看得见图」保持一致，不再有我们自己的开关。
-- 这是对 Fixed 的 FollowCurseOfLost 的第 3 处语义偏离（前两处：隐藏房 7/8/29 白名单、回溯线 Mom 房）。

-- 传送范围（合并了 Fixed 的 AllowNeighborRoom + AllowAnyRoom）
--   1 = 任意房间   （等价 Fixed: AllowAnyRoom = true）
--   2 = 相邻房间   （等价 Fixed 默认: AllowNeighborRoom = true、AllowAnyRoom = false）
--   3 = 已探索房间 （等价 Fixed: AllowNeighborRoom = false、AllowAnyRoom = false）
gt.TravelMode = 2

-- 只能传送到经已清房间逐门连通的房间（Fixed: FairTripPath）
gt.FairTripPath = true

-- 传送后站在走路会进来的门口（Fixed: ArriveAtDoor）
-- 默认改为开：偏离 Fixed 的默认关（2026-10-04 用户决定）
gt.ArriveAtDoor = true

-- 按距离公平增加游戏时间（Fixed: FairTripTime）
gt.FairTripTime = false

-- 跳过传送动画（Fixed: FastTransition；不进 MCM 菜单，仅本文件可覆盖。
-- 注意：默认值 true 是对 Fixed 的一处偏离，Fixed 默认为 false）
gt.FastTransition = true

-- 隐藏房候选标记（合并自 Lazy Delver）
gt.ShowSecretMarkers = true

-- 深牢 II 的「标记骷髅」房间标记（炸掉固定掉愚者卡牌的那个骷髅）
gt.FoolsSkullRoom = true

-- 地图边界高亮：按住地图键时，把贴着地图边界（13×13 最外圈）的房间、靠边的那条边画出来
gt.ShowMapBounds = true

-- 虚空层（The Void）标记精神错乱（Delirium）的 boss 房（超定位的显示功能，默认关）
gt.DeliriumRoom = false

-- 矿洞 II（Mines II / Ashpit）标记黄色轨道按钮所在的房间：
-- 踩下全层 3 个按钮才放行去刀片碎片 2 的轨道桥（腐妈支线必经）。
-- 房间一显示在地图上就标注；按钮已踩下的房间会自动撤掉图标。
gt.MineButtonRoom = true

-- 注：以下两条「保护性禁传」自 2026-10-03 起**常开、不提供开关**
--   · 当前房间里有「牌意解读 / 天堂阶梯」生成的入口（传送门 / 台阶）时禁传；
--   · 当前房间里存在「通往奖励房间的门」时禁传（恶魔房 / 天使房 / Boss Rush / 死寂；
--     独立模块 scripts/gtp_bosswindow.lua，按门的 TargetRoomType / TargetRoomIndex 判定）。
-- 两者都只在 `gt.DebugMod`（调试模式）下才被绕过。
