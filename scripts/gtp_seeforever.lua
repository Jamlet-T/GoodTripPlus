-- I can see forever：按游戏实时楼层效果，排除经过房间的普通/超级假候选。
-- 不自行记药丸使用史；续档、rewind、换层均以 Level:GetCanSeeEverything 为准。
local C=require('scripts.delver.const')
return function(gt,state,map,render,enabled)
  local previous
  local function reset() previous=nil end
  gt:AddCallback(ModCallbacks.MC_POST_UPDATE,function()
    if not enabled() or state.is_ignored() then reset(); return end
    local level=Game():GetLevel()
    if not level or type(level.GetCanSeeEverything)~='function'
      or not level:GetCanSeeEverything() then reset(); return end
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
        Isaac.DebugString('[GTPdelver] see-forever lid='..current.lid
          ..' dimension='..dimension..' excluded-fake='..removed)
      end)
    end
  end)
  gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED,reset)
  gt:AddCallback(ModCallbacks.MC_POST_NEW_LEVEL,reset)
end
