-- I can see forever / 探窟帽：排除当前房间相邻的普通/超级假候选。
-- 药丸读实时楼层效果，探窟帽读有效玩家实体的持有态；不缓存道具使用/拾取史。
local C=require('scripts.delver.const')
local function reveal_source(game,level)
  if type(level.GetCanSeeEverything)=='function' and level:GetCanSeeEverything() then
    return 'see-forever'
  end
  local hat=CollectibleType and CollectibleType.COLLECTIBLE_SPELUNKER_HAT
  if not hat then return nil end
  local count=game.GetNumPlayers and game:GetNumPlayers() or 1
  for index=0,count-1 do
    local player=Isaac.GetPlayer(index)
    if player and type(player.Exists)=='function' and player:Exists()
      and type(player.HasCollectible)=='function' and player:HasCollectible(hat) then
      return 'spelunker-hat'
    end
  end
end
return function(gt,state,map,render,enabled)
  local previous
  local function reset() previous=nil end
  gt:AddCallback(ModCallbacks.MC_POST_UPDATE,function()
    if not enabled() or state.is_ignored() then reset(); return end
    local game=Game()
    local level=game:GetLevel()
    local source=level and reveal_source(game,level)
    if not source then reset(); return end
    local descriptor=level:GetCurrentRoomDesc()
    if not descriptor or (descriptor.SafeGridIndex and descriptor.SafeGridIndex<0) then reset(); return end
    local current=map.rooms[descriptor.ListIndex]
    if not current then reset(); return end
    local dimension,revision=state.get_dimension(),render.revision()
    if previous and previous.candidates==map.candidates and previous.lid==current.lid
      and previous.dimension==dimension and previous.revision==revision
      and previous.floor==map.floor_revision then return end
    previous={candidates=map.candidates,lid=current.lid,dimension=dimension,
      revision=revision,floor=map.floor_revision}
    local removed=0
    for cid,candidate in pairs(map.candidates) do
      if candidate.lid==nil and (candidate.secret_type==C.SECRET_TYPE.REGULAR
        or candidate.secret_type==C.SECRET_TYPE.SUPER) then
        for _,entry in ipairs(candidate.entries) do
          if entry.source_lid==current.lid then
            if map.exclude_candidate(cid) then removed=removed+1 end
            break
          end
        end
      end
    end
    if removed>0 then
      render.refresh()
      pcall(function()
        Isaac.DebugString('[GTPdelver] '..source..' lid='..current.lid
          ..' dimension='..dimension..' excluded-fake='..removed)
      end)
    end
  end)
  gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED,reset)
  gt:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL,reset)
end
