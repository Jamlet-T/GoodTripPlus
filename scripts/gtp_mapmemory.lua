local Memory=require('scripts.gtp_mapstate')
local map=require('scripts.delver.map')
local state=require('scripts.delver.state')
local render=require('scripts.delver.render')
local pending_icons,pending_delver
local active=false
local run_seed
local last_frame=-1
local last_error
local function guard(fn)
  local ok,err=pcall(fn)
  if not ok and last_error~=tostring(err) then
    last_error=tostring(err)
    pcall(Isaac.DebugString,'[GTPpersist] map memory failed: '..last_error)
  elseif ok then last_error=nil end
end
local function restore()
  if pending_icons then
    local levels=MinimapAPI and MinimapAPI.Levels
    local dim=gt:get_current_dimension()
    if not levels or not levels[dim] or #levels[dim]==0 then return false end
    local restored=Memory.icons_restore(pending_icons,levels,
      Game():GetLevel():GetCurrentRoomDesc().ListIndex,dim)
    pending_icons=nil
    pcall(Isaac.DebugString,'[GTPpersist] restored icon rooms='..restored)
  end
  if pending_delver then
    if state.is_ignored() then return false end
    local removed=Memory.delver_restore(pending_delver,map)
    pending_delver=nil; render.refresh()
    pcall(Isaac.DebugString,'[GTPpersist] restored excluded candidates='..removed)
  end
  return true
end
local function save()
  if not active then return end
  restore()
  if not pending_icons and MinimapAPI and MinimapAPI.Levels then
    gt:persist_save_section('icons',Memory.icons_capture(MinimapAPI.Levels))
  end
  if not pending_delver and not state.is_ignored() then
    gt:persist_save_section('delver',Memory.delver_capture(map))
  end
  gt:save_door_state()
end
function gt:delver_memory_before_reload()
  guard(function()
    if active and map.memory_identity==gt:level_identity() then
      gt:persist_save_section('delver',Memory.delver_capture(map))
    end
  end)
end
function gt:delver_memory_after_reload()
  map.memory_identity=gt:level_identity()
  guard(function()
    if active then
      local text=gt:persist_get_section('delver')
      if text then Memory.delver_restore(text,map); render.refresh() end
    end
  end)
end
gt:AddCallback(ModCallbacks.MC_POST_GAME_STARTED,function(_,continued)
  guard(function()
  local game=Game()
  local seed=game.GetSeeds and game:GetSeeds():GetStartSeed() or gt:level_identity()
  local rewind=not continued and active and run_seed==seed and game:GetFrameCount()>1
  run_seed=seed
  active=false; last_frame=-1
  if continued or rewind then
    pending_icons=gt:persist_get_section('icons')
    pending_delver=gt:persist_get_section('delver')
  else
    pending_icons,pending_delver=nil,nil
    gt:persist_new_run()
    map.reload()
  end
  active=true
  pcall(Isaac.DebugString,'[GTPpersist] game-start continued='..tostring(continued)..' rewind='..tostring(rewind))
  end)
end)
gt:AddCallback(ModCallbacks.MC_POST_UPDATE,function()
  if not active then return end
  guard(function()
  restore()
  local frame=Game():GetFrameCount()
  if frame-last_frame>=30 or frame<last_frame then last_frame=frame; save() end
  end)
end)
gt:AddCallback(ModCallbacks.MC_PRE_GAME_EXIT,function()
  guard(save); active=false
end)
