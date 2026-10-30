local json = require("glint.json")

local bridge = {}
local maximumCandidateCount = 20
local defaultPageSize = 5

local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function homeDirectory()
  return os.getenv("HOME") or "/tmp"
end

local function defaultDirectory()
  return homeDirectory()
    .. "/Library/Application Support/Glint/RimeCandidateSupport"
end

local function relayCommand()
  local relay = os.getenv("GLINT_RIME_BRIDGE_RELAY")
    or (defaultDirectory() .. "/RimeCandidateBridge")
  local socket = os.getenv("GLINT_RIME_BRIDGE_SOCKET")
    or (defaultDirectory() .. "/bridge.sock")
  return shellQuote(relay)
    .. " relay --socket "
    .. shellQuote(socket)
end

local function ensureRelay(env)
  if env.glintRelay then
    return true
  end
  local ok, relay = pcall(io.popen, relayCommand(), "w")
  if not ok or relay == nil then
    log.warning("glint.rime_bridge relay launch failed")
    return false
  end
  env.glintRelay = relay
  return true
end

local function schemaID(env)
  return env.engine.schema
    and env.engine.schema.schema_id or nil
end

local function sessionID(env)
  if env.glintSessionID then
    return env.glintSessionID
  end
  local source = table.concat({
    tostring(env.engine.context),
    tostring(env),
    tostring(os.time()),
    tostring(os.clock()),
  }, "|")
  local hash = 2166136261
  for index = 1, #source do
    hash = (hash ~ source:byte(index)) * 16777619
    hash = hash & 0xffffffff
  end
  env.glintSessionID = string.format("%08x", hash)
  return env.glintSessionID
end

local function candidateText(candidate)
  if candidate and candidate.text and candidate.text ~= "" then
    return candidate.text
  end
  return nil
end

local function pageSize(env)
  local schema = env.engine.schema
  local size = schema and schema.page_size or defaultPageSize
  if type(size) ~= "number" or size < 1 then
    return defaultPageSize
  end
  return math.min(math.floor(size), maximumCandidateCount)
end

local function selectedOnlyPayload(env, selectedText)
  return {
    active = selectedText ~= nil,
    schemaID = schemaID(env),
    selectedText = selectedText,
    selectedIndex = selectedText and 0 or nil,
    candidates = selectedText and { selectedText } or {},
  }
end

local function menuSnapshot(env)
  local context = env.engine.context
  local composition = context.composition
  if not context:is_composing() or composition:empty() then
    return {
      active = false,
      schemaID = schemaID(env),
      selectedText = nil,
      selectedIndex = nil,
      candidates = {},
    }
  end

  local segment = composition:back()
  local text = candidateText(segment:get_selected_candidate())
  if not text then
    return nil
  end
  local selected = segment.selected_index
  local size = pageSize(env)
  local pageStart = math.floor(selected / size) * size
  local localIndex = selected - pageStart
  local candidates = {}
  for offset = 0, size - 1 do
    local candidate = segment.menu:get_candidate_at(
      pageStart + offset
    )
    local candidateValue = candidateText(candidate)
    if not candidateValue then
      break
    end
    candidates[#candidates + 1] = candidateValue
  end
  if candidates[localIndex + 1] ~= text then
    return selectedOnlyPayload(env, text)
  end
  return {
    active = true,
    schemaID = schemaID(env),
    selectedText = text,
    selectedIndex = localIndex,
    candidates = candidates,
  }
end

local function emitPayload(env, snapshot)
  local signature = json.encodeState(snapshot)
  if signature == env.glintLastSignature then
    return
  end
  if not ensureRelay(env) then
    return
  end
  env.glintSequence = (env.glintSequence or 0) + 1
  local payload = {}
  for key, value in pairs(snapshot) do
    payload[key] = value
  end
  payload.sessionID = sessionID(env)
  payload.sequence = env.glintSequence
  payload.heartbeat = false
  local line = json.encodeSnapshot(payload)
  local ok, writeResult = pcall(function()
    return env.glintRelay:write(line, "\n")
  end)
  if not ok or writeResult == nil then
    log.warning("glint.rime_bridge relay write failed")
    pcall(function() env.glintRelay:close() end)
    env.glintRelay = nil
    return
  end
  pcall(function()
    env.glintRelay:flush()
  end)
  env.glintLastSignature = signature
end

local function emitSnapshot(env)
  local current = menuSnapshot(env)
  if current then
    emitPayload(env, current)
  end
end

local function connectNotifier(env, notifier, name)
  if not notifier then
    return
  end
  local ok, connection = pcall(function()
    return notifier:connect(function()
      emitSnapshot(env)
    end)
  end)
  if ok and connection then
    env[name] = connection
  end
end

function bridge.init(env)
  local context = env.engine.context
  connectNotifier(env, context.update_notifier, "glintUpdateConnection")
  connectNotifier(env, context.select_notifier, "glintSelectConnection")
  connectNotifier(env, context.commit_notifier, "glintCommitConnection")
  emitSnapshot(env)
end

function bridge.func(translation, env)
  for candidate in translation:iter() do
    yield(candidate)
  end
end

function bridge.fini(env)
  for _, name in ipairs({
    "glintUpdateConnection",
    "glintSelectConnection",
    "glintCommitConnection",
  }) do
    local connection = env[name]
    if connection then
      pcall(function() connection:disconnect() end)
      env[name] = nil
    end
  end
  if env.glintRelay then
    env.glintSequence = (env.glintSequence or 0) + 1
    local payload = {
      active = false,
      schemaID = nil,
      selectedText = nil,
      selectedIndex = nil,
      candidates = {},
      sessionID = sessionID(env),
      sequence = env.glintSequence,
      heartbeat = false,
    }
    pcall(function()
      env.glintRelay:write(json.encodeSnapshot(payload), "\n")
      env.glintRelay:flush()
      env.glintRelay:close()
    end)
    env.glintRelay = nil
  end
end

return bridge
