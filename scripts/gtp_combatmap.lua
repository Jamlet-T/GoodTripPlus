-- MinimapAPI 2.58 main.lua:239/465/2231：战斗隐藏读 GetConfig，大小图由 IsLarge 决定。
-- 只调整有效读取值，不改 Config/OverrideConfig，避免污染代理菜单和上游存档。
return function(gt, api)
  if not api or type(api.GetConfig) ~= 'function' or api._gtpCombatMapInstalled then return end
  api._gtpCombatMapInstalled = true
  local original = api.GetConfig
  function api:GetConfig(key, ...)
    local value = original(self, key, ...)
    if key ~= 'HideInCombat' or (value ~= 2 and value ~= 3)
      or not gt:get_config_bool('CombatKeepLargeMap', false)
      or (self.OverrideConfig and self.OverrideConfig[key] ~= nil)
      or type(self.IsLarge) ~= 'function' then
      return value
    end
    -- 上游 IsLarge 也读 GetConfig(DisplayMode)，该键直接走原方法，不会递归。
    local ok, large = pcall(self.IsLarge, self)
    if ok and large then return 1 end
    return value
  end
end
