package.path = package.path
  .. ";Tools/RimeCandidateLab/rime/lua/?.lua"
  .. ";Tools/RimeCandidateLab/rime/lua/?/init.lua"

yield = coroutine.yield

local bridge = require("glint.candidate_bridge")

local translation = {
  iter = function()
    local index = 0
    local candidates = { "你好", "妳好", "拟好" }
    return function()
      index = index + 1
      if candidates[index] then
        return { text = candidates[index] }
      end
    end
  end,
}

local seen = {}
local worker = coroutine.create(function()
  return bridge.func(translation, {})
end)

repeat
  local ok, candidate = coroutine.resume(worker)
  assert(ok, candidate)
  if type(candidate) == "table" then
    seen[#seen + 1] = candidate.text
  end
until coroutine.status(worker) == "dead"

assert(coroutine.status(worker) == "dead")
assert(table.concat(seen, ",") == "你好,妳好,拟好")

print("glint_filter_test: ok")
