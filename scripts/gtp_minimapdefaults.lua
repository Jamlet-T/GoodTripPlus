-- 在 MinimapAPI.OnGameLoad 读取存档之前设置出厂值；已保存的配置随后照常覆盖。
-- 不持有第二份运行时高亮配置，也不在每次开局重设。
return function(api)
  if not api or not api.Config or api._gtpDefaultsInitialized then return end
  api._gtpDefaultsInitialized = true
  api.Config.HighlightStartRoom = true
end
