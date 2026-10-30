package.path = package.path
  .. ";Tools/RimeCandidateLab/rime/lua/?.lua"
  .. ";Tools/RimeCandidateLab/rime/lua/?/init.lua"

local json = require("glint.json")

local payload = json.encodeSnapshot({
  sessionID = "session-a",
  sequence = 7,
  heartbeat = false,
  active = true,
  schemaID = "luna_pinyin_simp",
  selectedText = "妳好",
  selectedIndex = 1,
  candidates = { "你好", "妳好", "逆号" },
})

assert(payload == table.concat({
  '{"version":3,"sessionID":"session-a","sequence":7,',
  '"heartbeat":false,"active":true,',
  '"schemaID":"luna_pinyin_simp",',
  '"selectedText":"妳好",',
  '"selectedIndex":1,',
  '"candidates":["你好","妳好","逆号"]}',
}), payload)

local escaped = json.encodeSnapshot({
  sessionID = "session-a",
  sequence = 8,
  heartbeat = true,
  active = true,
  schemaID = "a\"b\\c",
  selectedText = "line\nbreak",
  selectedIndex = 0,
  candidates = { "line\nbreak" },
})

assert(escaped:find('"schemaID":"a\\"b\\\\c"', 1, true))
assert(escaped:find('"line\\nbreak"', 1, true))
assert(escaped:find('"heartbeat":true', 1, true))

local inactive = json.encodeSnapshot({
  sessionID = "session-a",
  sequence = 9,
  heartbeat = false,
  active = false,
  schemaID = nil,
  selectedText = nil,
  selectedIndex = nil,
  candidates = {},
})

assert(inactive:find('"schemaID":null', 1, true))
assert(inactive:find('"selectedText":null', 1, true))
assert(inactive:find('"selectedIndex":null', 1, true))
assert(inactive:find('"candidates":[]', 1, true))

local state = json.encodeState({
  sessionID = "session-a",
  sequence = 10,
  heartbeat = true,
  active = true,
  schemaID = "luna_pinyin_simp",
  selectedText = "你好",
  selectedIndex = 0,
  candidates = { "你好" },
})

assert(not state:find('"sessionID"', 1, true))
assert(not state:find('"sequence"', 1, true))
assert(not state:find('"heartbeat"', 1, true))

print("glint_json_test: ok")
