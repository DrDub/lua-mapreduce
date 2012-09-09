-------------------------------------------------------------------------------
--
-- @script: lua-mapreduce-client.lua
--
-- @author:  rjoshi
--
-- @copyright Joshi Ventures LLC � 2012

-- VERSION HISTORY:
-- 1.0 8/09/2012 - Initial release
--
-------------------------------------------------------------------------------
-- Purpose: It is a worker for mapreduce functionality.
-- It receives the task from service and process requested taks
-- either map or reduce
-------------------------------------------------------------------------------

--- depends on logging
require "logging.console"
--- utils.lua
require "utils"
--- requires serialize.lua
require "serialize"

--- declare a logger instance. You can change it to file or other supported
local logger = logging.console()
logger:setLevel (logging.WARN)
local socket = require("socket")
local tcp = assert(socket.tcp())
local mapfn
local co_mapfn
local reducefn
local co_reducefn
local taskfile_loaded

------------------------------------------------------------------------------
--- load task file
--- @param task file
------------------------------------------------------------------------------
local function load_taskfile(file)
	local f = assert(io.open(file, "r"))
    local content = f:read("*all")
    f:close()
	print(content)
	local source = assert(loadstring(content))
    return source
end
------------------------------------------------------------------------------
--- Send Map Result
-- @return content of the task file
------------------------------------------------------------------------------
local function client_send_map_result(key, k, v)
	 local t = {}
	 local kv = {}
	 t['k']=key
	 kv[k]=v
	 t["v"] = kv
	 local value = serialize(t)

	logger:debug("Sending map result: " .. value)
	local bytes_sent, status = tcp:send(value .. "\r\n")
	-- logger:debug("bytes sent: " .. bytes_sent .. ",  bytes expected:" .. string.len(msg))
	return status
end

------------------------------------------------------------------------------
--- Send Reduce Result
-- @return content of the task file
------------------------------------------------------------------------------
local function client_send_reduce_result(key, value)
    local t = {}
	 t['k']=key
	 t['v']=value
	 local msg = serialize(t)

    logger:debug("Sending reduce result:" .. msg)
	return tcp:send(msg .. "\r\n")

end

------------------------------------------------------------------------------
--- client_loop: client is connected to the server and processing messages
------------------------------------------------------------------------------
local function client_run_loop(host, port)
    local task_file_content, status
    repeat

		-- read command
		logger:debug("Waiting to receive taskfile from the server:" .. host .. ":" .. port)
		local data, status = tcp:receive("*l")
		if(status == "closed") then
				logger:error("Connection closed by foreign host.")
				return status;
		end
		logger:debug("Received data " .. data)
		local task_t = loadstring(data)()
		local command = task_t['c']
		local len = tonumber(task_t['l'])
		logger:debug("Received command:" .. command .. ",  payload length:" .. len)
		--local command = "map"
		if(command ~= "taskfile") then
			tcp:send("error:invalid command. expected taskfile. received:" .. command .. "\r\n")
		else
			 task_file_content, status = tcp:receive( len )
			if(status == "closed") then
				logger:error("Connection closed by foreign host while receiving task file")
				return status;
			end
			local bytes_sent, status = tcp:send("OK," .. len .. "\r\n")
			if(status == "closed") then
				logger:error("Connection closed by foreign host while sending OK response for taskfile content receipt")
				return status;
			end


			logger:debug("taskfile loaded successfully")
		end

	until task_file_content ~= nil

	task_file_loaded = assert(loadstring( task_file_content))()
	local mr_t = mapreducefn()
	mapfn = mr_t.mapfn
	reducefn = mr_t.reducefn

	while true do
		-- read command
		logger:debug("Waiting to receive task (map/reduce) from the server:" .. host .. ":" .. port)
		local data, status = tcp:receive("*l")
		if(status == "closed") then
				logger:error("Connection closed by foreign host.")
				return status;
		end
		logger:debug("Received data " .. data)
		local task_t = loadstring(data)()
		local command = task_t['c']
		local key = task_t['k']
		local len = tonumber(task_t['l'])
		--logger:debug("Received command:" .. command .. ", Key:" .. key .. ", payload length:" .. len)

		--local command = "map"
		if(command == "map") then

		    local map_data, status = tcp:receive( len )
			if(status == "closed") then
				logger:error("Connection closed by foreign host while receiving map content for key:" .. key)
				return status;
			end
			local bytes_sent, status = tcp:send("OK," .. len .. "\r\n")
			if(status == "closed") then
				logger:error("Connection closed by foreign host while sending OK response for map content receipt for key:" .. key)
				return status;
			end

            local map_data_t = loadstring(map_data)()
			local map_value = map_data_t[key]
			logger:debug("Received map data:" .. map_value)
			co_mapfn = coroutine.create(mapfn)
			repeat
				logger:debug("Calling mapfn...")
				local ok, k, v  = coroutine.resume(co_mapfn, key, map_value)
				if(k ~= nil and v ~= nil) then
					local s= client_send_map_result(key, k, v)
					if(status == "closed") then
						logger:error("Connection closed by foreign host while sending map result with key:" .. key .. ":" .. k)
						return status;
					end
				end
			until (ok ~= true  or k == nil or v == nil)
			logger:debug("Sending map completed status for key:" .. key)
			local bytes_sent, status = tcp:send("map:completed:" .. key .. "\r\n")
			if(status == "closed") then
				logger:error("Connection closed by foreign host while sending map:completed status for key:" .. key)
				return status;
			end

		elseif(command == "reduce") then
		  --  logger:debug("Receiving reduce task payload lenth:" .. len)
		    local value, status = tcp:receive(len)
			 local r_v = loadstring(value)()
			 co_reducefn = coroutine.create(reducefn)
			 repeat
				local ok, k, v  = coroutine.resume(co_reducefn, key, r_v)
				if(k ~= nil and v ~= nil) then
					local s= client_send_reduce_result(k, v)
					if(status == "closed") then
						logger:error("Connection closed by foreign host while sending reduce:completed status for key:" .. key)
					return status;
					end
				end
			until (ok ~= true  or k == nil or v == nil)

			local bytes_sent, status = tcp:send("reduce:completed:" .. key .. "\r\n")
			if(status == "closed") then
				logger:error("Connection closed by foreign host while sending reduce:completed status for key:" .. key)
				return status;
			end
		end
		socket.select(nil, nil, 1)
	end
end

------------------------------------------------------------------------------
--- Validate arguments
-- @return host, port and task_file
------------------------------------------------------------------------------
local function client_Validate_args()
   local usage = "Usage lua-mapreduce-client.lua  -s host  -p port [-l loglevel]  "
   local opts = getopt( arg, "hpsl" )

	if(opts["h"] ~= nil) then
		print(usage)
		return;
	end
	-- get host
	local host = opts["s"]
	if(host == nil) then host = "127.0.0.1" end

	-- get port
	local port = opts["p"]
	if( port == nil ) then port = "10000" end

	local loglevel = opts["l"]
	if(loglevel == nil) then
		loglevel = "warn"
	elseif(loglevel ~= "debug" and loglevel ~= "info" and loglevel ~= "warn" and loglevel ~= "error") then
		print("Error: Invalid loglevel: " .. loglevel .. ". Valid options are debug, info, warn or error")
		return;
	end

   return host, port, loglevel

end

------------------------------------------------------------------------------
--- main function (entry point)
-- @return content of the task file
------------------------------------------------------------------------------
function client_main()

    local host, port, loglevel = client_Validate_args()
	if(host == nil or port == nil or loglevel == nil) then
		return;
	end

	set_loglevel(logger, loglevel)

    tcp:setoption('tcp-nodelay', true)

	local reconnect = true
    while true do
		-- set timeout to non-blocking
		if(reconnect) then

			repeat
			    tcp:settimeout(1)
				logger:debug("Connecting to server:" .. host .. ":" .. port)
				local c, status = tcp:connect(host, port);
				if(c == nil) then
				    logger:debug("Failed to connect. status:" .. status)
					tcp:close()
					tcp = assert(socket.tcp())
					socket.select(nil, nil, 5)
				else
					logger:info("Connected to server:" .. host .. ":" .. port)
				end
			until c ~= nil

		end

		reconnect = false;
	    --reset timeout to nil (blocking)
		tcp:settimeout(nil)
		local cl = os.clock()
		local status = client_run_loop(host, port)
		print("Total time to process" .. os.clock() -cl)
		if(status == "closed") then
			reconnect = true;
		end
	end
end

client_main()
