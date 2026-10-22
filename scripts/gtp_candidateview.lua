-- Display preference only: never delete a candidate or mutate learned evidence.
local C=require('scripts.delver.const')
local M={}
function M.select(candidate,show_single,clue_kind)
  if clue_kind then return clue_kind,false end
  local kind=candidate.secret_type
  local ambiguous=candidate.ambiguous or false
  if show_single or candidate.lid~=nil then return kind,ambiguous end
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
