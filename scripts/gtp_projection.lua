-- 来源：gtrep.lua:944-979 的逐格投影；一次绘制/命中测试共用一份参数。
-- 闭包只在当前调用内使用，不跨帧缓存，配置、维度与镜像缩放仍实时生效。
return function(gt, api, vector)
  if not api then
    local x, y = gt:get_rtmap_info()
    return function(gid)
      return vector(x + gid % 13 * 17 + 8, y + math.floor(gid / 13) * 15 + 7)
    end
  end
  local offset = gt:get_minapi_offset_vec()
  local scale = api.GlobalScaleX or 1
  local maxx, miny = gt:get_minapi_map_anchor()
  local x, y, step
  if maxx and miny then
    x = offset.X - maxx * 17 + (scale >= 0 and 9 or -17)
    y = offset.Y - miny * 15 + 8
    step = scale * 17
  else
    local left, right = gt:get_corner_room(1), gt:get_corner_room(2)
    x = offset.X + (scale >= 0 and (-(right.X + 1) * 17 + 9) or (left.X * 17 - 17))
    y = offset.Y - left.Y * 15 + 8
    step = scale >= 0 and 17 or -17
  end
  return function(gid)
    return vector(x + gid % 13 * step, y + math.floor(gid / 13) * 15)
  end
end
