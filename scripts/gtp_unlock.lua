-- 直接相邻门的费用策略；不访问游戏 API、不把特殊闸门或隐藏墙当钥匙门。
local M={}
function M.cost(e)
  -- Redirect flags belong to the target descriptor, not the current inventory.
  -- An already unlocked Blue Key door must still be entered through the engine.
  if e.blue_redirect and not e.locked then return {kind='native',amount=0} end
  if e.open or not e.locked then return nil end
  if e.variant~=1 and e.variant~=2 then return nil end
  if e.blue_key then return {kind='key',amount=0} end
  if e.store_key and e.shop and not e.pay_to_play then return {kind='key',amount=0} end
  if e.variant==1 and e.arcade then return {kind='coin',amount=1} end
  if e.pay_to_play then return nil end -- 转换门的外观/费用尚未核实，不能误扣钥匙。
  if e.variant==1 then return {kind='key',amount=1} end
  if e.variant==2 then
    -- DoorState.STATE_ONE_CHAIN (基础 API)：双锁已解开一道。
    return {kind='key',amount=e.state==3 and 1 or 2}
  end
end
function M.affordable(cost,actor)
  if cost.amount==0 then return true end
  if cost.kind=='coin' then return (actor.coins or 0)>=cost.amount end
  return actor.golden==true or (actor.keys or 0)>=cost.amount
end
return M
