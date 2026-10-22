-- Display preference only: never delete a candidate or mutate learned evidence.
local C=require('scripts.delver.const')
local M={}
-- Only remaining guesses compete for display priority. Real rooms (including
-- undiscovered ones) must never suppress the fallback or reveal their location.
-- Completed types have already been pruned by map.update_knowledge().
function M.fallback(candidates)
  local result={[C.SECRET_TYPE.REGULAR]=true,[C.SECRET_TYPE.ULTRA]=true}
  for _,candidate in pairs(candidates) do
    if candidate.lid==nil then
      local kind=candidate.secret_type
      if kind==C.SECRET_TYPE.REGULAR and (candidate.adjacent_sides or 0)>1 then
        result[kind]=false
      elseif kind==C.SECRET_TYPE.ULTRA and #(candidate.entries or {})>1 then
        result[kind]=false
      end
    end
  end
  return result
end
function M.select(candidate,show_single,clue_kind,fallback)
  if clue_kind then return clue_kind,false end
  local kind=candidate.secret_type
  local ambiguous=candidate.ambiguous or false
  if show_single or candidate.lid~=nil or (fallback and fallback[kind]) then return kind,ambiguous end
  if kind==C.SECRET_TYPE.REGULAR and candidate.adjacent_sides==1 then
    -- Disabling rare REGULAR guesses must not hide a valid SUPER guess.
    if ambiguous then return C.SECRET_TYPE.SUPER,false end
    return nil,false
  end
  if kind==C.SECRET_TYPE.ULTRA and #(candidate.entries or {})==1 then
    return nil,false
  end
  return kind,ambiguous
end
return M
