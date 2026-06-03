-- MatrixChat module for Minetest
local modpath = minetest.get_modpath(minetest.get_current_modname())
local storage = minetest.get_mod_storage()

MATRIX_SERVER = minetest.settings:get("MATRIX_SERVER")
MATRIX_ROOM = minetest.settings:get("MATRIX_ROOM")
MATRIX_USERNAME = minetest.settings:get("MATRIX_USERNAME")
MATRIX_PASSWORD = minetest.settings:get("MATRIX_PASSWORD")
-- New settings for direct token login
MATRIX_TOKEN = minetest.settings:get("MATRIX_TOKEN")
MATRIX_USERID = minetest.settings:get("MATRIX_USERID")

local http = minetest.request_http_api()
if not http then
    error("Please add matrix_bridge to secure.http_mods")
end

local function url_encode(str)
    if not str then return "" end
    str = str:gsub("\n", "\r\n")
    str = str:gsub("([^%w%-_%.%~])", function(c)
        return string.format("%%%02X", string.byte(c))
    end)
    return str
end

-- Ensure server URL doesn't have a trailing slash
if MATRIX_SERVER and MATRIX_SERVER:sub(-1) == "/" then
    MATRIX_SERVER = MATRIX_SERVER:sub(1, -2)
end

local MatrixChat = {
    server   = MATRIX_SERVER,
    username = MATRIX_USERNAME,
    password = MATRIX_PASSWORD,
    room     = MATRIX_ROOM,
    userid   = nil,
    token    = nil,
    since    = nil,
    eventid  = nil
}
matrix_bridge = {}

function matrix_bridge.send_as_server(message)
    MatrixChat:send("[Server]: " .. message)
end

function matrix_bridge.send_raw(message)
    MatrixChat:send(message)
end

-- ==========================================
-- Session Persistence Methods
-- ==========================================

function MatrixChat:load_session()
    self.token = storage:get_string("access_token")
    self.userid = storage:get_string("user_id")
    self.since = storage:get_string("since")

    -- Fallback to config settings if mod storage is empty
    if (not self.token or self.token == "") and MATRIX_TOKEN and MATRIX_TOKEN ~= "" then 
        self.token = MATRIX_TOKEN 
    end
    if (not self.userid or self.userid == "") and MATRIX_USERID and MATRIX_USERID ~= "" then 
        self.userid = MATRIX_USERID 
    end

    if self.since == "" then self.since = nil end
    
    return (self.token and self.token ~= "")
end

function MatrixChat:save_session()
    if self.token then storage:set_string("access_token", self.token) else storage:set_string("access_token", "") end
    if self.userid then storage:set_string("user_id", self.userid) else storage:set_string("user_id", "") end
    if self.since then storage:set_string("since", self.since) else storage:set_string("since", "") end
end

function MatrixChat:clear_session()
    storage:set_string("access_token", "")
    storage:set_string("user_id", "")
    storage:set_string("since", "")
    self.token = nil
    self.userid = nil
    self.since = nil
end

-- ==========================================
-- Core Matrix Functions
-- ==========================================

function MatrixChat:join_room()
    if not self.room or not self.token then return end
    
    local encoded_room = url_encode(self.room)
    local url = self.server .. "/_matrix/client/v3/join/" .. encoded_room
    
    http.fetch({
        url = url,
        method = "POST",
        extra_headers = {
            "Authorization: Bearer " .. self.token,
            "Content-Type: application/json"
        },
        post_data = "{}"
    }, function(res)
        if res.code == 200 then
            local data = minetest.parse_json(res.data)
            if data and data.room_id then
                self.room = data.room_id -- CRITICAL: Swaps alias for real ID
                minetest.log("action", "[matrix_bridge] Joined! Room ID is now: " .. self.room)
                matrix_bridge.send_as_server("Server is online!")
            end
        else
            minetest.log("error", "[matrix_bridge] Join failed: " .. res.code .. " " .. (res.data or ""))
        end
    end)
end

-- Parse incoming messages from Matrix
function MatrixChat:minechat(data)
    if not data or self.since == data.next_batch then return end
    local timeline = data.rooms and data.rooms.join and data.rooms.join[self.room] and data.rooms.join[self.room].timeline
    if not timeline or not timeline.events then
        return
    end
    minetest.log("action", "matrix_bridge - sync'd and found new messages")
    for _, event in ipairs(timeline.events) do
        if event.type == "m.room.message" and event.sender ~= self.userid then
            local message = event.sender .. ": " .. event.content.body
            if chat_channels then
                chat_channels.send("Matrix Bridge", "global", message)
            else
                minetest.chat_send_all(message)
            end
        end
    end
end

-- Build sync request
function MatrixChat:get_sync_table(timeout)
    local params = {}
    if self.since and self.since ~= "" then table.insert(params, "since=" .. url_encode(self.since)) end
    if timeout then table.insert(params, "timeout=" .. timeout) end
    
    -- REVERTED: Changed back to /v3/sync which is natively supported
    local url = self.server .. "/_matrix/client/v3/sync"
    if #params > 0 then url = url .. "?" .. table.concat(params, "&") end
    
    local headers = {
        "Authorization: Bearer " .. self.token,
        "Accept-Encoding: identity"
    }
    
    return {
        url = url, 
        method = "GET", -- Force GET explicitly
        extra_headers = headers
    }
end

-- Perform sync
function MatrixChat:sync(timeout)
    if not self.token then return end
    HANDLE = nil 
    
    http.fetch(self:get_sync_table(timeout), function(res)
        if not res then
            minetest.log("error", "matrix_bridge - sync response is nil")
        elseif res.code == 200 then
            local response = minetest.parse_json(res.data)
            if response then
                self:minechat(response)
                if response.next_batch then
                    self.since = response.next_batch
                    self:save_session()
                end
            end
        else
            minetest.log("error", "matrix_bridge - manual sync failed with code " .. res.code)
            -- Clear out corrupted sync token if the host flags it as bad
            if res.code == 400 or res.code == 405 then
                self.since = nil
                self:save_session()
            end
        end
    end)
end

-- Login to Matrix
function MatrixChat:login()
    if not self.server or self.server == "" then
        minetest.log("error", "matrix_bridge - MATRIX_SERVER is not defined in settings!")
        return
    end

    if self:load_session() then
        minetest.log("action", "matrix_bridge - Logged in using saved session/token")
        self:join_room()
        self:sync()
        return
    end

    if not self.username or self.username == "" or not self.password or self.password == "" then
        minetest.log("error", "matrix_bridge - No token available and missing username/password in settings.")
        return
    end

    local url = self.server .. "/_matrix/client/v3/login"
    local payload = {
        type = "m.login.password",
        identifier = {type = "m.id.user", user = self.username},
        password = self.password
    }
    local headers = {
        "Content-Type: application/json",
        "Accept-Encoding: identity"
    }
    http.fetch({
        url = url,
        method = "POST",
        extra_headers = headers,
        post_data = minetest.write_json(payload)
    }, function(res)
        if res.code == 200 then
            local data = minetest.parse_json(res.data)
            if data and data.access_token and data.user_id then
                self.token = data.access_token
                self.userid = data.user_id
                self:save_session() 
                minetest.log("action", "matrix_bridge - Matrix authenticated with password")
                self:join_room()
                self:sync()
            else
                minetest.log("error", "matrix_bridge - login response missing token or user_id")
            end
        else
            minetest.log("error", "matrix_bridge - login failed with code " .. res.code)
        end
    end)
end

-- Send message to Matrix room
function MatrixChat:send(msg)
    if not self.token then return end
    local txid = tostring(os.time()) .. "_" .. tostring(math.random(1000, 9999))
    local url = self.server .. "/_matrix/client/r0/rooms/" .. self.room .. "/send/m.room.message/" .. txid
    local headers = {
        "Authorization: Bearer " .. self.token,
        "Content-Type: application/json",
        "Accept-Encoding: identity"
    }
    local payload = {
        msgtype = "m.text",
        body = msg
    }
    local req = {
        url = url,
        method = "PUT",
        extra_headers = headers,
        data = minetest.write_json(payload)
    }
    http.fetch(req, function(res)
        if res.code == 200 then
            local data = minetest.parse_json(res.data)
            if data and data.event_id then
                self.eventid = data.event_id
                minetest.log("action", "matrix_bridge - sent message, event_id: " .. data.event_id)
            else
                minetest.log("error", "matrix_bridge - cannot parse send response")
            end
        elseif res.code == 403 then
            minetest.log("error", "matrix_bridge - forbidden: " .. res.data)
        elseif res.code == 401 then
            minetest.log("error", "matrix_bridge - not authorized to send messages")
        elseif res.code == 404 then
            minetest.log("error", "matrix_bridge - endpoint not found")
        else
            minetest.log("error", "matrix_bridge - send failed with code " .. res.code)
        end
    end)
end

-- Logout
function MatrixChat:logout()
    if not self.token then return end
    local url = self.server .. "/_matrix/client/v3/logout"
    local headers = {
        "Authorization: Bearer " .. self.token,
        "Accept-Encoding: identity"
    }
    http.fetch({url = url, method = "POST", extra_headers = headers}, function(_) end)
    self:clear_session() 
    minetest.log("action", "matrix_bridge - signed out and session cleared")
end

-- Utility: print sync URL
function MatrixChat:get_access_url()
    if not self.token then return end
    local params = {"access_token=" .. self.token}
    if self.since then table.insert(params, "since=" .. self.since) end
    local url = self.server .. "/_matrix/client/v3/sync?" .. table.concat(params, "&")
    print(url)
end

local clock = os.clock
function sleep(time)
    local startTime = clock()
    local endTime = startTime + time
    repeat
        startTime = clock()
    until (startTime >= endTime)
end

-- Global error handler
local function global_error_handler(err)
    local msg = "[Server]: Server is offline due to error: " .. tostring(err)
    minetest.log("error", msg)
    if MatrixChat and MatrixChat.send then
        MatrixChat:send(msg)
        sleep(2)
        MatrixChat:logout()
    end
end

-- Periodic sync
local INTERVAL = 30 
local HANDLE = nil
local sync_cooldown = 0

minetest.register_globalstep(function(dtime)
    if sync_cooldown > 0 then
        sync_cooldown = sync_cooldown - dtime
        return
    end

    if not MatrixChat.token or #minetest.get_connected_players() == 0 then 
        if HANDLE then HANDLE = nil end 
        return 
    end
    
    if HANDLE == nil then
        local request = MatrixChat:get_sync_table(INTERVAL * 1000)
        request.method = "GET" 
        HANDLE = http.fetch_async(request)
    else
        local result = http.fetch_async_get(HANDLE)
        
        if result and result.completed then
            HANDLE = nil 
            
            if result.code == 200 then
                local activity = minetest.parse_json(result.data)
                if activity then
                    MatrixChat:minechat(activity)
                    if activity.next_batch then
                        MatrixChat.since = activity.next_batch
                        MatrixChat:save_session()
                    end
                end
                sync_cooldown = 0 
            else
                minetest.log("error", "[matrix_bridge] background sync failed with code " .. tostring(result.code))
                
                -- Catch ALL major failure states (Timeouts, 404, 405) and drop into cooldown
                if result.code == 0 or result.code == 405 or result.code == 404 then
                    minetest.log("action", "[matrix_bridge] Sync issues hit. Resetting tracking and cooling down for 15 seconds...")
                    
                    -- Wipe out a potentially corrupted since token on validation/routing fault
                    if result.code == 405 then
                        MatrixChat.since = nil
                        MatrixChat:save_session()
                    end
                    
                    sync_cooldown = 15
                else
                    sync_cooldown = 5 
                end
            end
        end
    end
end)

-- Chat and player events
minetest.register_privilege("matrix", {
    description = "Manage matrix bridge session",
    give_to_singleplayer = true,
    give_to_admin = true
})

minetest.register_chatcommand("matrix", {
    privs = {matrix = true},
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
            return true, "[matrix_bridge] printed URL to server console"
        end
    end
})

-- Wrap mod init in xpcall
local function safe_mod_init()
    if rawget(_G, "chat_channels") == nil then
        minetest.register_on_chat_message(function(name, message)
            if message:sub(1, 1) == "/" or message:sub(1, 5) == "[off]" or not minetest.check_player_privs(name, {shout = true}) then
                return
            end
            local nl = message:find("\n", 1, true)
            if nl then message = message:sub(1, nl - 1) end
            MatrixChat:send("[" .. name .. "]: " .. message)
        end)
    end
    MatrixChat:login()
end

minetest.register_on_joinplayer(function(player, last_login)
    local name = player:get_player_name()
    MatrixChat:send("[Server]: " .. name .. " joined the game" .. (last_login and ", welcome back!" or " for the first time. Welcome and have a great stay!"))
end)

minetest.register_on_leaveplayer(function(player, timed_out)
    local name = player:get_player_name()
    MatrixChat:send("[Server]: " .. name .. " left the game" .. (timed_out and " (Timed out)" or ", see you again soon!"))
end)

minetest.register_chatcommand("restart", {
    params = "<message>",
    description = "Send a restart message and shut down the server",
    privs = {server = true},
    func = function(name, param)
        local msg = "[Server]: Server is restarting: " .. (param or "No reason given")
        MatrixChat:send(msg)
        sleep(1)
        MatrixChat:logout()
        sleep(1)
        minetest.request_shutdown("Server is restarting: " .. (param or "No reason given"))
        return true, "Restart initiated"
    end
})

minetest.register_on_mods_loaded(function()
    xpcall(safe_mod_init, global_error_handler)
end)
