-- 门图、图标与候选知识共用一次 SaveData，分区更新不能覆盖其它分区。
return function(gt)
  -- 跨楼层仍要随整局保留的分区（如虚空吸收记录）；其余分区只属于当前层。
  local RUN_SECTIONS = { voided = true }
  local cached, identity
  function gt:persist_read_record()
    local current=gt:level_identity()
    if identity~=current then
      local loaded=gt:HasData() and gt.persist_parse(gt:LoadData()) or nil
      identity,cached=current,loaded
      if cached and cached.identity~=current then
        if gt.legacy_level_identity and cached.identity==gt:legacy_level_identity() then cached.identity=current
        else cached=nil end
      end
      pcall(function()
        Isaac.DebugString('[GTPpersist] floor-load current='..tostring(current)
          ..' matched='..tostring(cached~=nil))
      end)
    end
    return cached
  end
  function gt:persist_write_record(record)
    local current=gt:level_identity()
    assert(record.identity==current,'refuse stale floor save')
    local old=gt:persist_read_record()
    record.link,record.swept=record.link or {},record.swept or {}
    record.bare_out,record.bare_in,record.pre=record.bare_out or {},record.bare_in or {},record.pre or {}
    record.sections=record.sections or {}
    for key,value in pairs(old and old.sections or {}) do
      if record.sections[key]==nil then record.sections[key]=value end
    end
    if not old then
      -- 换层后旧记录的身份不再匹配，但 run 级分区必须延续到本层记录。
      local raw = gt:HasData() and gt.persist_parse(gt:LoadData()) or nil
      for key in pairs(RUN_SECTIONS) do
        if record.sections[key]==nil and raw and raw.sections
          and raw.sections[key]~=nil then
          record.sections[key]=raw.sections[key]
        end
      end
    end
    gt:SaveData(gt.persist_serialize(record))
    cached,identity=record,current
  end
  function gt:persist_get_section(key)
    local record=gt:persist_read_record()
    return record and record.sections and record.sections[key]
  end
  function gt:persist_save_section(key,value)
    local old=gt:persist_read_record()
    if old and old.sections and old.sections[key]==value then return true end
    local record={identity=gt:level_identity(),sections={}}
    for k,v in pairs(old or {}) do if k~='sections' then record[k]=v end end
    for k,v in pairs(old and old.sections or {}) do record.sections[k]=v end
    record.sections[key]=value
    local ok,err=pcall(gt.persist_write_record,gt,record)
    if not ok then pcall(Isaac.DebugString,'[GTPpersist] save failed: '..tostring(err)) end
    return ok
  end
  function gt:persist_new_run()
    cached=nil; identity=gt:level_identity()
    local text=gt.persist_serialize({identity=identity})
    gt:SaveData(text)
    cached=gt.persist_parse(text)
    if gt.reset_door_floor then gt:reset_door_floor() end
  end
end
