local json = {}

local escapeMap = {
  ['"'] = '\\"',
  ["\\"] = "\\\\",
  ["\b"] = "\\b",
  ["\f"] = "\\f",
  ["\n"] = "\\n",
  ["\r"] = "\\r",
  ["\t"] = "\\t",
}

local function quote(value)
  local text = tostring(value or "")
  text = text:gsub('[%z\1-\31\\"]', function(character)
    return escapeMap[character]
      or string.format("\\u%04x", character:byte())
  end)
  return '"' .. text .. '"'
end

local function optionalInteger(value)
  if value == nil then
    return "null"
  end
  return tostring(math.tointeger(value) or 0)
end

local function encode(snapshot, includeMetadata)
  local candidates = {}
  for index, candidate in ipairs(snapshot.candidates or {}) do
    candidates[index] = quote(candidate)
  end
  local fields = { '{"version":3,' }
  if includeMetadata then
    fields[#fields + 1] = '"sessionID":'
    fields[#fields + 1] = quote(snapshot.sessionID)
    fields[#fields + 1] = ',"sequence":'
    fields[#fields + 1] = optionalInteger(snapshot.sequence)
    fields[#fields + 1] = ',"heartbeat":'
    fields[#fields + 1] = snapshot.heartbeat and "true" or "false"
    fields[#fields + 1] = ","
  end
  fields[#fields + 1] = '"active":'
  fields[#fields + 1] = snapshot.active and "true" or "false"
  fields[#fields + 1] = ',"schemaID":'
  fields[#fields + 1] = snapshot.schemaID == nil
    and "null" or quote(snapshot.schemaID)
  fields[#fields + 1] = ',"selectedText":'
  fields[#fields + 1] = snapshot.selectedText == nil
    and "null" or quote(snapshot.selectedText)
  fields[#fields + 1] = ',"selectedIndex":'
  fields[#fields + 1] = optionalInteger(snapshot.selectedIndex)
  fields[#fields + 1] = ',"candidates":['
  fields[#fields + 1] = table.concat(candidates, ",")
  fields[#fields + 1] = "]}"
  return table.concat(fields)
end

function json.encodeState(snapshot)
  return encode(snapshot, false)
end

function json.encodeSnapshot(snapshot)
  return encode(snapshot, true)
end

return json
