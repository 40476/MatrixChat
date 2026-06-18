local modpath = minetest.get_modpath(minetest.get_current_modname())

-- Load settings directly from minetest.settings
local MATRIX_SERVER = minetest.settings:get("MATRIX_SERVER")
local MATRIX_ROOM = minetest.settings:get("MATRIX_ROOM")
local MATRIX_USERNAME = minetest.settings:get("MATRIX_USERNAME")
local MATRIX_PASSWORD = minetest.settings:get("MATRIX_PASSWORD")
local MATRIX_TOKEN = minetest.settings:get("MATRIX_TOKEN")
local MATRIX_USERID = minetest.settings:get("MATRIX_USERID")
local MATRIX_SERVERNAME = minetest.settings:get("MATRIX_SERVERNAME") or "usr40k.dev"

-- Ensure server URL doesn't have a trailing slash
if MATRIX_SERVER and MATRIX_SERVER:sub(-1) == "/" then
    MATRIX_SERVER = MATRIX_SERVER:sub(1, -2)
end

local http = minetest.request_http_api()
if http == nil then
    error("Please add matrix_bridge to secure.http_mods")
end

-- defines functions for matrix protocol
local MatrixChat = {
    server   = MATRIX_SERVER,
    username = MATRIX_USERNAME,
    password = MATRIX_PASSWORD,
    room     = MATRIX_ROOM,
    proxy    = MATRIX_HACK_PROXY,
    token    = MATRIX_TOKEN,
    userid   = MATRIX_USERID,
    since    = nil,
    eventid  = nil
}

function MatrixChat:minechat(data)
    if data == nil then return end
    if self.since == data.next_batch then return end
    if data["rooms"] == nil or data["rooms"]["join"] == nil then return end
    if data["rooms"]["join"][self.room] == nil then return end
    if data["rooms"]["join"][self.room]["timeline"] == nil then return end

    local events = data["rooms"]["join"][self.room]["timeline"]["events"]
    if events == nil then
        minetest.log("action", "matrix_bridge - found timeline but no events")
        return
    end

    minetest.log("action", "matrix_bridge - sync'd and found new messages")
    for i, event in ipairs(events) do
        if event.type == "m.room.message" and event.sender ~= self.userid then
            -- Structural fix: Fallback to string if body content is absent
            local body_content = (event.content and event.content.body) or "<non-text message>"
            local message = event.sender .. ": " .. body_content
            
            minetest.log("action", message)
            
            -- Prevent recursive chat reflection back loops
            local old_sendall = minetest.chat_send_all
            minetest.chat_send_all = function(text) minetest.log("action", "[Matrix Echo Bypassed]: " .. text) end
            minetest.chat_send_all(message)
            minetest.chat_send_all = old_sendall
        end
    end
end

-- GET /sync
function MatrixChat:get_sync_table(timeout)
    local params = {}
    if self.since ~= nil then table.insert(params, "since=" .. self.since) end
    if timeout ~= nil then table.insert(params, "timeout=" .. timeout) end
    
    local u = self.server .."/_matrix/client/r0/sync"
    if #params > 0 then u = u .. "?" .. table.concat(params, "&") end
    
    local h = {
        "Authorization: Bearer " .. (self.token or ""),
        "Accept-Encoding: identity",
        "Host: " .. MATRIX_SERVERNAME
    }
    return {url=u, method="GET", extra_headers=h}
end

function MatrixChat:sync(timeout)
    if self.token == nil or self.token == "" then return end
    
    local raw_req = MatrixChat:get_sync_table(timeout)
    local clean_req = {
        url = raw_req.url,
        method = "GET",
        extra_headers = raw_req.extra_headers
    }
    
    http.fetch(clean_req, function(res)
        if res == nil then 
            minetest.log("error", "matrix_bridge - sync response is nil")
        elseif res.code == 200 then
            local response = minetest.parse_json(res.data)
            if response ~= nil then
                MatrixChat:minechat(response)
                MatrixChat.since = response.next_batch
            end
        end
    end)
end

-- POST /login
function MatrixChat:login()
    -- Bypass authentication step if token was directly provided via settings
    if self.token and self.token ~= "" then
        minetest.log("action", "matrix_bridge - Logged in via static settings token")
        MatrixChat:sync()
        MatrixChat:send("*** Server connected to the matrix via static configuration token")
        return
    end

    local u = self.server .."/_matrix/client/r0/login"
    local d = minetest.write_json{
        type="m.login.password",
        password=self.password,
        identifier={
            type="m.id.user",
            user=self.username
        }
    }
    local h = {
        "Content-Type: application/json",
        "Accept-Encoding: identity",
        "Host: " .. MATRIX_SERVERNAME
    }
    http.fetch({url=u, method="POST", extra_headers=h, data=d}, function(res)
        if res.code == 200 then
            local data = minetest.parse_json(res.data)
            if data.access_token ~= nil and data.user_id ~= nil then
                self.token  = data.access_token
                self.userid = data.user_id
                MatrixChat:sync()
                minetest.log("action", "Matrix authenticated")
                MatrixChat:send("*** Server connected to the matrix")
            else
                minetest.log("error", "Matrix login failed")
            end
        else
            minetest.log("error", "Matrix login failed with code " .. tostring(res.code))
        end
    end)
end

-- PUT /rooms/{roomId}/send/{eventType}/{txnId}
function MatrixChat:send(msg)
    if self.token == nil or self.token == "" then return end
    local txid = tostring(os.time()) .. "_" .. tostring(math.random(100, 999))
    local u = self.server .."/_matrix/client/r0/rooms/".. self.room .."/send/m.room.message/" .. txid
    local h = {
        "Content-Type: application/json",
        "Authorization: Bearer " .. self.token,
        "Accept-Encoding: identity",
        "Host: " .. MATRIX_SERVERNAME
    }
    local d = minetest.write_json({msgtype="m.text", body=msg})
    local req
    if self.proxy then
        req = {url=u, method="POST", extra_headers=h, post_data=d}
    else
        req = {url=u, method="PUT", extra_headers=h, data=d}
    end
    http.fetch(req, function(res)
        if res.code == 200 then
            local data = minetest.parse_json(res.data)
            if data then self.eventid = data["event_id"] end
        end
    end)
end

-- POST /logout/all
function MatrixChat:logout()
    if not self.token or self.token == "" then return end
    local u = self.server .."/logout/all"
    local h = {
        "Authorization: Bearer " .. self.token,
        "Accept-Encoding: identity",
        "Host: " .. MATRIX_SERVERNAME
    }
    http.fetch({url=u, method="POST", extra_headers=h}, function(res) end)
    minetest.log("action", "matrix_bridge - signing out.")
end

function MatrixChat:get_access_url()
    local params = {}
    if self.since ~= nil then table.insert(params, "since=" .. self.since) end
    table.insert(params, "access_token=" .. (self.token or ""))
    local u = self.server .. "/_matrix/client/r0/sync?" .. table.concat(params, "&")
    print(u)
end

-- FIXED LONG-POLLING ENGINE WRAPPER
local INTERVAL = 30
local HANDLE  = nil

minetest.register_globalstep(function(dtime)
    if MatrixChat.token == nil or MatrixChat.token == "" or #minetest.get_connected_players() == 0 then
        return
    end
    
    if HANDLE == nil then
        local raw_request = MatrixChat:get_sync_table(INTERVAL * 1000)
        
        -- FIX: Build an exact structural request object so cURL doesn't translate timeout into POST parameters
        local request = {
            url = raw_request.url,
            method = "GET",
            extra_headers = raw_request.extra_headers
        }
        
        HANDLE = http.fetch_async(request)
    else
        local result = http.fetch_async_get(HANDLE)
        if result and result.completed then
            if result.code == 200 then
                local activity = minetest.parse_json(result.data)
                if activity ~= nil then
                    MatrixChat:minechat(activity)
                    MatrixChat.since = activity.next_batch
                end
            end
            HANDLE = nil
        end
    end
end)

minetest.register_privilege("matrix", {
    description = "Manage matrix bridge session",
    give_to_singleplayer = true,
    give_to_admin = true
})

minetest.register_chatcommand("matrix", {
    privs = { matrix = true },
    func = function(name, param)
        if param == "sync" then
            MatrixChat:sync()
            return true, "[matrix_bridge] command: sync"
        elseif param == "logout" then
            MatrixChat:logout()
            return true, "[matrix_bridge] command: log out"
        elseif param == "login" then
            MatrixChat:login()
            return true, "[matrix_bridge] command: log in"
        elseif param == "print" then
            MatrixChat:get_access_url()
            return true, "[matrix_bridge] printed url to server console"
        end
    end
})

minetest.register_on_shutdown(function()
    MatrixChat:logout()
end)

minetest.register_on_joinplayer(function(player)
    local name = player:get_player_name()
    MatrixChat:send("*** " .. name .. " joined the game")
end)

minetest.register_on_leaveplayer(function(player, timed_out)
    local name = player:get_player_name()
    MatrixChat:send("*** " .. name .. " left the game" .. (timed_out and " (Timed out)" or ""))
end)

local stripall
do
    local string_gsub, string_char = string.gsub, string.char
    local stripcolor = minetest.get_color_escape_sequence('#ffffff')
    stripcolor = string_gsub(stripcolor, "%W", "%%%1")
    stripcolor = string_gsub(stripcolor, "ffffff", "%%x+")

    local striptrans = minetest.get_translator("12345")("67890")
    striptrans = string_gsub(striptrans, "%W", "%%%1")
    striptrans = string_gsub(striptrans, "12345", "%%S-")
    striptrans = string_gsub(striptrans, "67890", "(%.-)")

    local stripesc = "%" .. string_char(27) .. "%S"

    function stripall(s)
        s = string_gsub(s, stripcolor, "")
        s = string_gsub(s, striptrans, "%1")
        s = string_gsub(s, stripesc, "")
        return s
    end
end

do
    local old_sendall = minetest.chat_send_all
    function minetest.chat_send_all(text, ...)
        local t = stripall(text)
        MatrixChat:send(t)
        return old_sendall(text, ...)
    end
end

minetest.register_on_chat_message(function(name, message)
    if message:sub(1, 1) == "/" or message:sub(1, 5) == "[off]" or (not minetest.check_player_privs(name, {shout=true})) then
        return
    end
    local nl = message:find("\n", 1, true)
    if nl then message = message:sub(1, nl - 1) end
    message = stripall(message)
    MatrixChat:send("<" .. name .. "> " .. message)
end)

minetest.register_on_mods_loaded(function() MatrixChat:login() end)