-- MatrixChat module for Minetest
local modpath = minetest.get_modpath(minetest.get_current_modname())
MATRIX_SERVER = minetest.settings:get("MATRIX_SERVER")
MATRIX_ROOM = minetest.settings:get("MATRIX_ROOM")
MATRIX_USERNAME = minetest.settings:get("MATRIX_USERNAME")
MATRIX_PASSWORD = minetest.settings:get("MATRIX_PASSWORD")

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

function matrix_bridge.send_to_room(message)
    -- Your existing Matrix bot logic here
    -- For example:
    MatrixChat:send("[Server]: " .. message)
end

function MatrixChat:join_room()
    if self.room:sub(1, 1) == "!" then
        -- It's a room ID, no need to join
        minetest.log("action", "matrix_bridge - using room ID: " .. self.room)
        return
    end

    -- It's an alias, join it
    local url = self.server .. "/_matrix/client/r0/join/" .. url_encode(self.room)
    local headers = {
        "Authorization: Bearer " .. self.token,
        "Content-Type: application/json",
        "Accept-Encoding: identity"
    }
    http.fetch({
        url = url,
        method = "POST",
        extra_headers = headers
    }, function(res)
        if res.code == 200 then
            local data = minetest.parse_json(res.data)
            if data and data.room_id then
                self.room = data.room_id
                minetest.log("action", "matrix_bridge - joined room via alias: " .. self.room)
                self:send("[Server]: Server is online")
            else
                minetest.log("error", "matrix_bridge - join succeeded but no room_id returned")
            end
        else
            minetest.log("error", "matrix_bridge - failed to join room: " .. res.data)
        end
    end)
end

-- Parse incoming messages from Matrix
function MatrixChat:minechat(data)
    if not data or self.since == data.next_batch then return end
    local timeline = data.rooms and data.rooms.join and data.rooms.join[self.room] and data.rooms.join[self.room].timeline
    if not timeline or not timeline.events then
        minetest.log("action", "matrix_bridge - no new events")
        return
    end
    minetest.log("action", "matrix_bridge - sync'd and found new messages")
    for _, event in ipairs(timeline.events) do
        if event.type == "m.room.message" and event.sender ~= self.userid then
            local message = event.sender .. ": " .. event.content.body
            minetest.chat_send_all(message)
        end
    end
end

-- Build sync request
function MatrixChat:get_sync_table(timeout)
    local params = {}
    if self.since then table.insert(params, "since=" .. self.since) end
    if timeout then table.insert(params, "timeout=" .. timeout) end
    local url = self.server .. "/_matrix/client/r0/sync"
    if #params > 0 then url = url .. "?" .. table.concat(params, "&") end
    local headers = {
        "Authorization: Bearer " .. self.token,
        "Accept-Encoding: identity"
    }
    return {url = url, method = "GET", extra_headers = headers}
end

-- Perform sync
function MatrixChat:sync(timeout)
    if not self.token then return end
    http.fetch(self:get_sync_table(timeout), function(res)
        if not res then
            minetest.log("error", "matrix_bridge - sync response is nil")
        elseif res.code == 200 then
            local response = minetest.parse_json(res.data)
            if response then
                self:minechat(response)
                self.since = response.next_batch
            end
     else
            minetest.log("error", "matrix_bridge - sync failed with code " .. res.code)
        end
    end)
end

-- Login to Matrix
function MatrixChat:login()
    local url = self.server .. "/_matrix/client/r0/login"
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
                minetest.log("action", "Matrix authenticated")
                self:join_room()  -- 👈 Add this line
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
    local txid = tostring(os.time())
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
    local url = self.server .. "/_matrix/client/r0/logout"
    local headers = {
        "Authorization: Bearer " .. self.token,
        "Accept-Encoding: identity"
    }
    http.fetch({url = url, method = "POST", extra_headers = headers}, function(_) end)
    minetest.log("action", "matrix_bridge - signed out")
end

-- Utility: print sync URL
function MatrixChat:get_access_url()
    local params = {"access_token=" .. self.token}
    if self.since then table.insert(params, "since=" .. self.since) end
    local url = self.server .. "/_matrix/client/r0/sync?" .. table.concat(params, "&")
    print(url)
end

local clock = os.clock
function sleep(time)
    startTime=clock()
    print("startTime:"..startTime)
    endTime=startTime+time
    print("endTime:"..endTime)
    repeat
        startTime=clock()
    until( startTime>=endTime )
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
local INTERVAL = 60
local HANDLE = nil
minetest.register_globalstep(function(dtime)
    if not MatrixChat.token or #minetest.get_connected_players() == 0 then return end
    if not HANDLE then
        local request = MatrixChat:get_sync_table(INTERVAL * 1000)
        request.timeout = INTERVAL
        HANDLE = http.fetch_async(request)
    else
        local result = http.fetch_async_get(HANDLE)
        if result.completed then
            if result.code == 200 then
                local activity = minetest.parse_json(result.data)
                if activity then
                    MatrixChat:minechat(activity)
                    MatrixChat.since = activity.next_batch
                end
            end
            HANDLE = nil
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

minetest.register_on_chat_message(function(name, message)
    if message:sub(1, 1) == "/" or message:sub(1, 5) == "[off]" or not minetest.check_player_privs(name, {shout = true}) then
        return
    end
    local nl = message:find("\n", 1, true)
    if nl then message = message:sub(1, nl - 1) end
    MatrixChat:send("[" .. name .. "]: " .. message)
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