--[[--
HTTP client for the NewTwos public API.

Base URL: https://www.twosapp.com/api/v1
Auth: Bearer token (API key created in NewTwos Settings -> API Keys).
@module koplugin.twos.twosapi
--]]--

local http        = require("socket.http")
local ltn12       = require("ltn12")
local rapidjson   = require("rapidjson")
local socket      = require("socket")
local socket_url  = require("socket.url")
local socketutil  = require("socketutil")
local _           = require("gettext")

local TwosAPI = {}
TwosAPI.base_url = "https://www.twosapp.com/api/v1"

function TwosAPI:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.rate_limited = false
    return o
end

--- Perform an API request.
-- @param method string ("GET" or "POST")
-- @param path string starting with "/" (e.g. "/lists")
-- @param query table|nil of query params
-- @param body table|nil (will be JSON-encoded)
-- @return ok boolean, result table|nil, err string|nil
function TwosAPI:request(method, path, query, body)
    local url = self.base_url .. path
    if query then
        local parts = {}
        for k, v in pairs(query) do
            parts[#parts + 1] = socket_url.escape(k) .. "=" .. socket_url.escape(tostring(v))
        end
        if #parts > 0 then
            url = url .. "?" .. table.concat(parts, "&")
        end
    end

    local body_json
    if body ~= nil then
        body_json = rapidjson.encode(body)
        if not body_json then
            return false, nil, "failed to encode request body"
        end
    end

    local headers = {
        ["Content-Type"] = "application/json",
    }
    if self.api_key and self.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. self.api_key
    end
    if body_json then
        headers["Content-Length"] = tostring(#body_json)
    end

    local sink = {}
    socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request{
        url     = url,
        method  = method,
        sink    = ltn12.sink.table(sink),
        source  = body_json and ltn12.source.string(body_json) or nil,
        headers = headers,
    })
    socketutil:reset_timeout()

    -- Network failure: http.request returns nil, err; after skip, code holds err.
    if resp_headers == nil then
        return false, nil, code or "network unreachable"
    end

    if code == 401 then
        return false, nil, _("invalid or missing API key")
    elseif code == 403 then
        return false, nil, _("API key lacks required scope (enable write:lists, write:things, search, read:lists)")
    elseif code == 429 then
        self.rate_limited = true
        return false, nil, _("rate limit exceeded (1000/hour) - please wait and retry")
    elseif code < 200 or code >= 300 then
        return false, nil, status or ("HTTP " .. tostring(code))
    end

    local response_text = table.concat(sink)
    if response_text == "" then
        return true, nil, nil
    end

    local res, derr = rapidjson.decode(response_text)
    if not res then
        return false, nil, "failed to decode response: " .. (derr or "?")
    end
    return true, res, nil
end

--- Validate the API key by hitting GET /tags.
-- @return ok boolean, info number|string (tag count on success, error on failure)
function TwosAPI:testConnection()
    local ok, res, err = self:request("GET", "/tags")
    if not ok then return false, err end
    local count = (res and res.tags) and #res.tags or 0
    return true, count
end

--- Find a list by exact (case-insensitive) title match.
-- Note: /search caps at 50 lists and is not a complete enumeration.
-- @return list_id string|nil, err string|nil
function TwosAPI:findListByTitle(title)
    local ok, res, err = self:request("GET", "/search", { query = title })
    if not ok then return nil, err end
    if res and res.lists then
        local lower = title:lower()
        for __, list in ipairs(res.lists) do
            if list.title and list.title:lower() == lower then
                return list.id
            end
        end
    end
    return nil
end

--- Find a list by exact title, paging through every list.
-- Complete enumeration (50 per page); used as a fallback when the
-- capped /search endpoint misses an existing list.
-- @return list_id string|nil, err string|nil
function TwosAPI:findListByPaging(title)
    local lower = title:lower()
    local page = 0
    while page < 100 do -- hard cap: 100 pages * 50 lists
        local ok, res, err = self:request("GET", "/lists", { page = page })
        if not ok then return nil, err end
        local lists = (res and res.lists) or {}
        for __, list in ipairs(lists) do
            if list.title and list.title:lower() == lower then
                return list.id
            end
        end
        if not res or not res.has_more or #lists == 0 then break end
        page = page + 1
    end
    return nil
end

--- Create a new list.
-- @return list_id string|nil, err string|nil
function TwosAPI:createList(title, emoji)
    local body = { title = title }
    if emoji and emoji ~= "" then
        body.emoji = emoji
    end
    local ok, res, err = self:request("POST", "/lists", nil, body)
    if not ok then return nil, err end
    if res and res.list and res.list.id then
        return res.list.id
    end
    return nil, "no list id in response"
end

--- Find an existing list by title, or create it if missing.
-- /search is tried first (fast), then every list is paged through
-- before creating, so a capped search can never produce a duplicate list.
-- @return list_id string|nil, err string|nil
function TwosAPI:findOrCreateList(title, emoji)
    local id, err = self:findListByTitle(title)
    if id then return id end
    if err then return nil, err end
    id, err = self:findListByPaging(title)
    if id then return id end
    if err then return nil, err end
    return self:createList(title, emoji)
end

--- Bulk-create things in a list (chunked at 500 items per call).
-- @param list_id string
-- @param items array of thing objects
-- @param skip_duplicates boolean
-- @return ok boolean, created number, skipped number, err string|nil
function TwosAPI:bulkCreateThings(list_id, items, skip_duplicates)
    local created, skipped = 0, 0
    local chunk_size = 500
    for i = 1, #items, chunk_size do
        local chunk = {}
        for j = i, math.min(i + chunk_size - 1, #items) do
            chunk[#chunk + 1] = items[j]
        end
        local body = {
            list_id         = list_id,
            items           = chunk,
            skip_duplicates = skip_duplicates,
        }
        local ok, res, err = self:request("POST", "/things/bulk", nil, body)
        if not ok then
            return false, created, skipped, err
        end
        if res then
            created = created + (res.created or 0)
            skipped = skipped + (res.skipped or 0)
        end
    end
    return true, created, skipped
end

return TwosAPI
