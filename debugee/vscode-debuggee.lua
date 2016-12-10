local socket = require 'socket'
local json

-------------------------------------------------------------------------------
local DO_TEST = false

-------------------------------------------------------------------------------
-- chunkname 매칭 {{{
local function getMatchCount(a, b)
	local n = math.min(#a, #b)
	for i = 0, n - 1 do
		if a[#a - i] == b[#b - i] then
			-- pass
		else
			return i
		end
	end
	return n
end
if DO_TEST then
	assert(getMatchCount({'a','b','c'}, {'a','b','c'}) == 3)
	assert(getMatchCount({'b','c'}, {'a','b','c'}) == 2)
	assert(getMatchCount({'a','b','c'}, {'b','c'}) == 2)
	assert(getMatchCount({}, {'a','b','c'}) == 0)
	assert(getMatchCount({'a','b','c'}, {}) == 0)
	assert(getMatchCount({'a','b','c'}, {'a','b','c','d'}) == 0)
end

local function splitChunkName(s)
	if string.sub(s, 1, 1) == '@' then
		s = string.sub(s, 2)
	end

	local a = {}
	for word in string.gmatch(s, '[^/\\]+') do
		a[#a + 1] = string.lower(word)
	end
	return a
end
if DO_TEST then
	local a = splitChunkName('@.\\vscode-debuggee.lua')  
	assert(#a == 2)
	assert(a[1] == '.')
	assert(a[2] == 'vscode-debuggee.lua')

	local a = splitChunkName('@C:\\dev\\VSCodeLuaDebug\\debuggee/lua\\socket.lua')  
	assert(#a == 6)
	assert(a[1] == 'c:')
	assert(a[2] == 'dev')
	assert(a[3] == 'vscodeluadebug')
	assert(a[4] == 'debuggee')
	assert(a[5] == 'lua')
	assert(a[6] == 'socket.lua')

	local a = splitChunkName('@main.lua')  
	assert(#a == 1)
	assert(a[1] == 'main.lua')
end
-- chunkname 매칭 }}}

-- 패스 조작 {{{
local Path = {}

function Path.isAbsolute(a)
	local firstChar = string.sub(a, 1, 1)
	if firstChar == '/' or
	   firstChar == '\\' then
		return true
	end

	if string.match(a, '^%a%:[/\\]') then
		return true
	end

	return false
end

function Path.concat(a, b)
	-- a를 노멀라이즈
	local lastChar = string.sub(a, #a, #a)
	if (lastChar == '/' or lastChar == '\\') then
		-- pass 
	else
		a = a .. '\\'
	end

	-- b를 노멀라이즈
	if string.match(b, '^%.%\\') then
		b = string.sub(b, 3)
	end 

	return a .. b
end

function Path.toAbsolute(base, sub)
	if Path.isAbsolute(sub) then
		return sub
	else
		return Path.concat(base, sub) 
	end
end

if DO_TEST then
	assert(Path.isAbsolute('c:\\asdf\\afsd'))
	assert(Path.isAbsolute('c:/asdf/afsd'))
	assert(Path.concat('c:\\asdf', 'fdsf') == 'c:\\asdf\\fdsf')
	assert(Path.concat('c:\\asdf', '.\\fdsf') == 'c:\\asdf\\fdsf')
end
-- 패스 조작 }}}

-- 순정 모드 {{{
local function createHaltBreaker()
	local sethook = debug.sethook;
	debug.sethook = nil;

	-- chunkname 매칭 {
	local loadedChunkNameMap = {}
	for chunkname, _ in pairs(debug.getchunknames()) do
		loadedChunkNameMap[chunkname] = splitChunkName(chunkname)
	end

	local function findMostSimilarChunkName(path)
		local splitedReqPath = splitChunkName(path)
		local maxMatchCount = 0
		local foundChunkName = nil 
		for chunkName, splitted in pairs(loadedChunkNameMap) do
			local count = getMatchCount(splitedReqPath, splitted)
			if (count > maxMatchCount) then
				maxMatchCount = count
				foundChunkName = chunkName 
			end
		end
		return foundChunkName
	end
	-- chunkname 매칭 }

	return {
		setBreakpoints = function(path, lines)
			local foundChunkName = findMostSimilarChunkName(path)
			local verifiedLines = {}

			if foundChunkName then
				debug.clearhalt(foundChunkName)
				for _, ln in ipairs(lines) do
					if (debug.sethalt(foundChunkName, ln)) then
						verifiedLines[#verifiedLines + 1] = ln
					end
				end
			end

			return verifiedLines
		end,

		setLineBreak = function(callback)
			if callback then
				sethook(callback, 'l')
			else
				sethook()
			end
		end,

		-- 실험적으로 알아낸 값들-_-ㅅㅂ
		stackOffset =
		{
			enterDebugLoop = 6,
			halt = 6,
			step = 4,
			stepDebugLoop = 6
		}
	} 
end

local function createPureBreaker()
	local lineBreakCallback = nil
	local breakpointsPerPath = {}
	local chunknameToPathCache = {}

	local function chunkNameToPath(chunkname)
		local cached = chunknameToPathCache[chunkname] 
		if cached then
			return cached
		end

		local splitedReqPath = splitChunkName(chunkname)
		local maxMatchCount = 0
		local foundPath = nil 
		for path, _ in pairs(breakpointsPerPath) do
			local splitted = splitChunkName(path)
			local count = getMatchCount(splitedReqPath, splitted)
			if (count > maxMatchCount) then
				maxMatchCount = count
				foundPath = path 
			end
		end

		if foundPath then
 			chunknameToPathCache[chunkname] = foundPath			
		end
		return foundPath
	end

	local sethook = debug.sethook 
	local entered = false
	local function hookfunc()
		if entered then return false end
		entered = true

		if lineBreakCallback then
			lineBreakCallback()
		end

		local info = debug.getinfo(2, 'Sl')
		if info then
			local path = chunkNameToPath(info.source)
			local bpSet = breakpointsPerPath[path] 
			if bpSet and bpSet[info.currentline] then
				_G.__halt__()
			end
		end

		entered = false		 
	end
	debug.sethook(hookfunc, 'l')
	debug.sethook = nil;

	return {
		setBreakpoints = function(path, lines)
			local t = {}
			for _, v in ipairs(lines) do
				t[v] = true
			end
			breakpointsPerPath[path] = t
			return lines 
		end,

		setLineBreak = function(callback)
			lineBreakCallback = callback
		end,

		-- 실험적으로 알아낸 값들-_-ㅅㅂ
		stackOffset =
		{
			enterDebugLoop = 6,
			halt = 7,
			step = 4,
			stepDebugLoop = 7
		}
	}
end

-- 순정 모드 }}}

-------------------------------------------------------------------------------
local debuggee = {}
local handlers = {}
local sock
local sourceBasePath = '.'
local storedVariables = {}
local nextVarRef = 1
local baseDepth
local breaker

-------------------------------------------------------------------------------
-- 네트워크 유틸리티 {{{
local function sendFully(str)
	local first = 1
	while first <= #str do
		local sent = sock:send(str, first)
		if sent > 0 then
			first = first + sent;
		else
			error('sock:send() returned < 0')
		end
	end
end

-- 센드는 블럭이어도 됨.
local function sendMessage(msg)
	local body = json.encode(msg)
	--print('SENDING:  ' .. body)	
	sendFully('#' .. #body .. '\n' .. body)
end

-- 리시브는 블럭이 아니어야 할 거 같은데... 음... 블럭이어도 괜찮나?
local function recvMessage()
	local header = sock:receive('*l')
	if (header == nil) then
		error('disconnected')
	end
	if (string.sub(header, 1, 1) ~= '#') then
		error('헤더 이상함:' .. header)
	end

	local bodySize = tonumber(header:sub(2))
	local body = sock:receive(bodySize)

	return json.decode(body)
end
-- 네트워크 유틸리티 }}}

-------------------------------------------------------------------------------
local function debugLoop()
	storedVariables = {}
	nextVarRef = 1
	while true do
		local msg = recvMessage()
		--print('RECEIVED: ' .. json.encode(msg))
		
		local fn = handlers[msg.command]
		if fn then
			local rv = fn(msg)

			-- continue인데 break하는 게 역설적으로 느껴지지만
			-- 디버그 루프를 탈출(break)해야 정상 실행 흐름을 계속(continue)할 수 있지..
			if (rv == 'CONTINUE') then
				break;
			end
		else
			--print('UNKNOWN DEBUG COMMAND: ' .. tostring(msg.command))
		end
	end
	storedVariables = {}
	nextVarRef = 1
end

-------------------------------------------------------------------------------
function debuggee.start(jsonLib, config)
	json = jsonLib
	assert(jsonLib)
	
	config = config or {}
	config.connectTimeout = config.connectTimeout or 5.0
	config.controllerHost = config.controllerHost or 'localhost'
	config.controllerPort = config.controllerPort or 56789

	local breakerType
	if debug.sethalt then
		breaker = createHaltBreaker()
		breakerType = 'halt'
	else
		breaker = createPureBreaker()
		breakerType = 'pure'
	end

	local err
	sock, err = socket.tcp()
	if not sock then error(err) end
	if sock.settimeout then sock:settimeout(config.connectTimeout) end
	local res, err = sock:connect(config.controllerHost, tostring(config.controllerPort))
	if not res then
		sock:close()
		sock = nil
		return false, breakerType
	end

	if sock.settimeout then sock:settimeout() end
	sock:setoption('tcp-nodelay', true)

	local initMessage = recvMessage()
	assert(initMessage.command == 'welcome')
	sourceBasePath = initMessage.sourceBasePath

	debugLoop()
	return true, breakerType
end

-------------------------------------------------------------------------------
local function sendSuccess(req, body)
	sendMessage({
		command = req.command,
		success = true,
		request_seq = req.seq,
		type = "response",
		body = body
	})	
end

-------------------------------------------------------------------------------
local function sendEvent(eventName, body)
	sendMessage({
		event = eventName,
		type = "event",
		body = body
	})	
end

-------------------------------------------------------------------------------
local function startDebugLoop()
	local threadId = 0
	if coroutine.running() then
		-- 'thread: 011DD5B0'
		--  12345678^
		local threadIdHex = string.sub(tostring(coroutine.running()), 9) 
		threadId = tonumber(threadIdHex, 16)
	end

	sendEvent(
		'stopped',
		{
			reason = 'breakpoint',
			threadId = threadId,
			allThreadsStopped = true
		})

	local status, err = pcall(debugLoop)
	if not status then
		--print('★★★★★★')
		--print(err)
		--print('★★★★★★')
	end
end

-------------------------------------------------------------------------------
_G.__halt__ = function()
	baseDepth = breaker.stackOffset.halt
	startDebugLoop()
end

-------------------------------------------------------------------------------
function debuggee.enterDebugLoop(depth, what)
	if sock == nil then
		return false
	end

	if what then
		sendEvent(
			'output',
			{
				category = 'stderr',
				output = what,
			})
	end

	baseDepth = (depth or 0) + breaker.stackOffset.enterDebugLoop
	startDebugLoop()
	return true
end

-------------------------------------------------------------------------------
-- ★★★ https://github.com/Microsoft/vscode/blob/a3e2b3d975dcaf85ca4f40486008ce52b31dbdec/src/vs/workbench/parts/debug/common/debugProtocol.d.ts
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
function handlers.setBreakpoints(req)
	local bpLines = {}
	for _, bp in ipairs(req.arguments.breakpoints) do
		bpLines[#bpLines + 1] = bp.line
	end

	local verifiedLines = breaker.setBreakpoints(
		req.arguments.source.path,
		bpLines)

	local breakpoints = {}
	for i, v in ipairs(verifiedLines) do
		breakpoints[#breakpoints + 1] = {
			verified = true,
			line = v
		}
	end

	sendSuccess(req, {
		breakpoints = breakpoints
	})
end

-------------------------------------------------------------------------------
function handlers.configurationDone(req)
	sendSuccess(req, {})
	return 'CONTINUE'
end

-------------------------------------------------------------------------------
function handlers.threads(req)
	-- TODO: 일단 메인 스레드만. 지금은 모든 코루틴을 순회할 방법이 없다.
	local mainThread = {
		id = 0,
		name = "main"
	}

	sendSuccess(req, {
		threads = { mainThread }
	})
end

-------------------------------------------------------------------------------
function handlers.stackTrace(req)
	assert(req.arguments.threadId == 0)

	local stackFrames = {} 
	local firstFrame = (req.arguments.startFrame or 0) + baseDepth
	local lastFrame = (req.arguments.levels and (req.arguments.levels ~= 0))
		and (firstFrame + req.arguments.levels - 1)
		or (9999)

	for i = firstFrame, lastFrame do
		local info = debug.getinfo(i, 'lnS')
		if (info == nil) then break end
		--print(json.encode(info))

		local src = info.source
		if string.sub(src, 1, 1) == '@' then
			src = string.sub(src, 2) -- 앞의 '@' 떼어내기
		end

		local sframe = {
			name = (info.name or '?') .. ' (' .. (info.namewhat or '?') .. ')',
			source = {
				name = nil,
				path = Path.toAbsolute(sourceBasePath, src)
			},
			column = 1,
			line = info.currentline or 1,
			id = i,
		}
		stackFrames[#stackFrames + 1] = sframe
	end

	sendSuccess(req, {
		stackFrames = stackFrames
	})
end

-------------------------------------------------------------------------------
local scopeTypes = {
	Locals = 1,
	Upvalues = 2,
	Globals = 3,
}
function handlers.scopes(req)
	local depth = req.arguments.frameId
	
	local scopes = {}
	local function addScope(name)
		scopes[#scopes + 1] = {
			name = name,
			expensive = false,
			variablesReference = depth * 1000000 + scopeTypes[name]
		}		
	end

	addScope('Locals')
	addScope('Upvalues')
	addScope('Globals')

	sendSuccess(req, {
		scopes = scopes
	})
end

-------------------------------------------------------------------------------
function handlers.variables(req)
	local varRef = req.arguments.variablesReference
	local variables = {}
	local function addVar(name, value, noQuote)
		local ty = type(value)
		local item = {
			name = tostring(name),
			type = ty
		}

		if (ty == 'string' and (not noQuote)) then
			item.value = '"' .. value .. '"'
		else
			item.value = tostring(value)
		end

		if (ty == 'table') or
		   (ty == 'function') then
			storedVariables[nextVarRef] = value
			item.variablesReference = nextVarRef
			nextVarRef = nextVarRef + 1
		else
			item.variablesReference = -1
		end

		variables[#variables + 1] = item
	end

	if (varRef >= 1000000) then
		-- 스코프임.
		local depth = math.floor(varRef / 1000000)
		local scopeType = varRef % 1000000
		if scopeType == scopeTypes.Locals then
			for i = 1, 9999 do
				local name, value = debug.getlocal(depth, i)
				if name == nil then break end
				addVar(name, value)
			end
		elseif scopeType == scopeTypes.Upvalues then
			local info = debug.getinfo(depth, 'f')
			if info and info.func then
				for i = 1, 9999 do
					local name, value = debug.getupvalue(info.func, i)
					if name == nil then break end
					addVar(name, value)
				end
			end
		elseif scopeType == scopeTypes.Globals then
			for name, value in pairs(_G) do
				addVar(name, value)
			end
			table.sort(variables, function(a, b) return a.name < b.name end)
		end 
	else
		-- 펼치기임.
		local var = storedVariables[varRef]
		if type(var) == 'table' then
			for k, v in pairs(var) do
				addVar(k, v)
			end
			table.sort(variables, function(a, b) return a.name < b.name end)
		elseif type(var) == 'function' then
			local info = debug.getinfo(var, 'S')
			addVar('(source)', tostring(info.short_src), true)
			addVar('(line)', info.linedefined)

			for i = 1, 9999 do
				local name, value = debug.getupvalue(var, i)
				if name == nil then break end
				addVar(name, value)
			end
		end

		local mt = getmetatable(var)
		if mt then
			addVar("(metatable)", mt)
		end
	end

	sendSuccess(req, {
		variables = variables
	})
end

-------------------------------------------------------------------------------
function handlers.continue(req)
	sendSuccess(req, {})
	return 'CONTINUE'
end

-------------------------------------------------------------------------------
local function stackHeight()
	for i = 1, 9999999 do
		if (debug.getinfo(i, '') == nil) then
			return i
		end
	end
end

-------------------------------------------------------------------------------
local stepTargetHeight = nil
local function step()
	if (stepTargetHeight == nil) or (stackHeight() <= stepTargetHeight) then
		breaker.setLineBreak(nil)
		baseDepth = breaker.stackOffset.stepDebugLoop
		startDebugLoop()
	end
end

-------------------------------------------------------------------------------
function handlers.next(req)
	stepTargetHeight = stackHeight() - breaker.stackOffset.step
	breaker.setLineBreak(step)
	return 'CONTINUE'
end

-------------------------------------------------------------------------------
function handlers.stepIn(req)
	stepTargetHeight = nil
	breaker.setLineBreak(step)
	return 'CONTINUE'
end

-------------------------------------------------------------------------------
function handlers.stepOut(req)
	stepTargetHeight = stackHeight() - (breaker.stackOffset.step + 1)
	breaker.setLineBreak(step)
	return 'CONTINUE'
end

-------------------------------------------------------------------------------
return debuggee
