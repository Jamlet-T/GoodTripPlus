-- 控制台只接受 ASCII；动态房名/错误中的非 ASCII 字节转义，原文仍可写入日志。
local M={}
function M.ascii(text)
  return (tostring(text):gsub('[\128-\255]',function(c) return string.format('\\x%02X',c:byte()) end))
end
function M.write(text)
  Isaac.ConsoleOutput(M.ascii(text))
end
return M
