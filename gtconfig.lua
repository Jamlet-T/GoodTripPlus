-- GoodTripPlus - 静态默认值覆盖（优先级低于游戏内 Mod Config Menu）
-- 这里的每一项都可以被 MCM 里的设置覆盖（有对应菜单项的话）。
-- 例外：HighlightCursorRoom 自 2026-10-04 起**不进 MCM 菜单**，只能在本文件里覆盖（默认常开）。
-- 传送准入逻辑为 GoodTrip [Fixed] 的忠实移植，选项与 Fixed 同名同默认值
-- （例外：① 传送范围把 Fixed 的 AllowNeighborRoom + AllowAnyRoom 两项合并成一个三选一的
--   TravelMode，默认值等价于 Fixed 的原默认组合；② 传送过场把 Fixed 的 TeleportAnimation +
--   FastTransition 两个布尔项合并成一个三选一 TeleportTransition，默认「淡入淡出」，
--   而 Fixed 默认是「淡入淡出关 + 快速过场关」= 淡入淡出，两边效果一致）。
gt.FastRestartEnable = true

-- 键盘传送光标每次按键移动一个 1x1 房间格距；关闭时按光标速度连续移动。
gt.CursorGridStep = false
-- 鼠标跟随光标与左键点击传送；关闭后仍可用键盘/手柄。
gt.MouseTeleport = true

-- 传送过场（落地时的表现）：1 = 立即出现 / 2 = 淡入淡出 / 3 = 传送动画（白闪）。
-- MCM 里对应「传送过场」项（装了 MCM 时以它为准）；这里只是没装 MCM 时的文件级默认。
-- 顺带决定传送冷却 tele_cd（1 / 10 / 45 帧）：过场越短，冷却越短。
gt.TeleportTransition = 2

-- 调试模式（**纯诊断开关**，默认关）。**所有调试输出的总闸**：关着时屏幕不画理由浮层、
-- log 里也不写诊断行（「地图键 + F4」手动入口同样按不动）。两个入口任一为真即开：
--   · 游戏内 Mod Config Menu 的「调试模式」项（推荐，改了立刻生效）；
--   · 本行改成 true —— 文件级强制开。**它优先于 MCM**（与其他选项相反）：
--     MCM 注册时会把默认 false 写进 Config，若不优先则改本文件会没反应。
-- 开启后只输出诊断：光标停在目标上自动落盘（`[GTPtrip]`）、解锁「地图键 + F4」手动 dump、
-- 屏幕上画**红色**的实时理由浮层。（黄底的那条「一次性 dump 浮层」15 秒才消失、只挡视线，
-- 2026-10-06 已删除 —— 同样的内容 log.txt 里读得到。）
-- ⚠️ 它**不改变任何传送判定或表现**（2026-10-06 用户拍板）—— 历史遗留的「debug 放行 /
--    跳过」已全部移除：不再绕过保护性禁传（道具入口 / 奖励房门 / 诅咒房）、不再强制
--    「立即出现」跳过过场、不再豁免诅咒房过路费、呼出光标的闸门也不再为它开绿灯。
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
--   1 = 任意房间   （随时呼出，绕过游戏限制，传送至任意地图可选房间）
--       任意时刻传送至任意房间，极大破坏游戏平衡，请谨慎启用
--   2 = 相邻房间   （等价 Fixed 默认: AllowNeighborRoom = true、AllowAnyRoom = false）
--   3 = 已探索房间 （等价 Fixed: AllowNeighborRoom = false、AllowAnyRoom = false）
gt.TravelMode = 2

-- 禁止传送进诅咒房（移植基底 MLX's Tweak 的同名选项 BlockCurseRoom，默认开）。
-- 诅咒房 = RoomType.ROOM_CURSE(10)，进出时会按门咬血的那种。
--   true（默认） = 任何传送范围档位都不允许把目标落在诅咒房上（「任意房间」档也拦）；
--   false        = 不拦，诅咒房按普通房间处理（含「相邻房间」档的未探索邻居豁免），
--                  但仍照旧在进出时扣血。
-- 消费点只有一个：scripts/gtp_curseblock.lua 登记的 ② target_entry 段规则
--   `target.curse_blocked`（原先配套的 gtrep 类型白名单已于 2026-10-06 整体删除）。
-- **任何设置都不能绕过**（调试模式自 2026-10-06 起只出诊断、不改变判定）。
-- 注：2026-10-05 恢复 —— 本 mod 早期移植时漏掉了 Fixed 的这条选项。
gt.BlockCurseRoom = true

-- 只能传送到经已清房间逐门连通的房间（Fixed: FairTripPath）
gt.FairTripPath = true

-- 传送后站在走路会进来的门口（Fixed: ArriveAtDoor）
-- 默认改为开：偏离 Fixed 的默认关（2026-10-04 用户决定）
gt.ArriveAtDoor = true

-- 按距离公平增加游戏时间（Fixed: FairTripTime）
gt.FairTripTime = false

-- 注：传送过场已合并为一个三选一项（见文件开头 gt.TeleportTransition），
-- 原来的两个布尔项 gt.TeleportAnimation / gt.FastTransition 自 2026-10-05 起不再读取。

-- 隐藏房候选标记（合并自 Lazy Delver）
gt.ShowSecretMarkers = true

-- 深牢 II 的「标记骷髅」房间标记（炸掉固定掉愚者卡牌的那个骷髅）
gt.FoolsSkullRoom = true

-- 地图边界高亮：按住地图键时，把贴着地图边界（13×13 最外圈）的房间、靠边的那条边画出来
gt.ShowMapBounds = true

-- 战斗隐藏仍由 MinimapAPI 的三档配置决定；开启后仅隐藏小地图，保留大地图。
gt.CombatKeepLargeMap = false

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
-- 两者常开且**不可绕过**（调试模式自 2026-10-06 起只出诊断、不参与判定）。
