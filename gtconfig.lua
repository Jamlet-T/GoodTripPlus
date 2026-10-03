-- GoodTripPlus - 静态默认值覆盖（优先级低于游戏内 Mod Config Menu）
-- 这里的每一项都可以被 MCM 里的设置覆盖。
-- 传送准入逻辑为 GoodTrip [Fixed] 的忠实移植，选项与 Fixed 同名同默认值。
gt.FastRestartEnable = true
gt.TeleportAnimation = false
gt.DebugMod = false
gt.HighlightCursorRoom = true

-- 迷失诅咒下禁用传送（Fixed: FollowCurseOfLost）
gt.FollowCurseOfLost = true

-- 允许传送到已清可达房间旁未清的邻居房（Fixed: AllowNeighborRoom）
gt.AllowNeighborRoom = true

-- 允许传送到所有已显示房间（Fixed: AllowAnyRoom）
gt.AllowAnyRoom = false

-- 只能传送到经已清房间逐门连通的房间（Fixed: FairTripPath）
gt.FairTripPath = true

-- 传送后站在走路会进来的门口（Fixed: ArriveAtDoor）
gt.ArriveAtDoor = false

-- 按距离公平增加游戏时间（Fixed: FairTripTime）
gt.FairTripTime = false

-- 跳过传送动画（Fixed: FastTransition）
gt.FastTransition = false

-- 隐藏房候选标记（合并自 Lazy Delver）
gt.ShowSecretMarkers = true

-- 深牢 II 的「标记骷髅」房间标记（炸掉固定掉愚者卡牌的那个骷髅）
gt.FoolsSkullRoom = true

-- 当前房间里有「牌意解读 / 天堂阶梯」生成的入口（传送门 / 台阶）时禁止传送
-- （这两个入口一离开房间就消失，禁传送免得误触顶掉效果；房间里的入口没了自动解除）
gt.LockStartRoomItems = true
