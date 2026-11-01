-- Run from a plugin/Studio tool in an isolated Play client, with the source ModuleScripts in `root` and a
-- scratch local bridge's {url, key, http_url?} in `pipe`. No account calls or uploads; closes only this test's socket.
return function(root, pipe)
	local Client, Keys, Fallback = require(root.Client), require(root.Keys), require(root.Fallback)
	local plugin = { GetSetting = function(_, key)
		return if key == "Autopilot_pipe" then pipe else nil
	end }
	local sent, releases = {}, 0
	local send, releaseAll = Keys.send, Fallback.releaseAll
	Keys.send = function(spec, pressed, value)
		table.insert(sent, { name = spec.name, pressed = pressed })
		return send(spec, pressed, value)
	end
	Fallback.releaseAll = function()
		releases += 1
		return releaseAll()
	end
	local client
	local ok, result = pcall(function()
		client = Client.start(plugin)
		local host = _G.AutopilotHost
		local deadline = os.clock() + 6
		repeat task.wait(.1) until host.link and host.link.connected or os.clock() > deadline
		assert(host.link and host.link.connected, "pipe did not connect")
		assert(host.link.client, "this case requires the native WebSocket transport")
		host:_onFrame({ to = "client", type = "attach" })
		local held, err = host.ops.key({ key = "W", mode = "hold", lease = 10 })
		assert(held, tostring(err))
		-- Exercise fallback even when the OS delivered the key; it must stop on the same disconnect.
		Fallback.down(Keys.spec("W"))
		Keys.moveMouse(Vector2.new(2, 0))
		local beforeMouse = game.UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
		host.link.want = false
		host.link.client:Close() -- actual transport event, not Host:_detach() called by the test
		deadline = os.clock() + 3
		repeat task.wait() until not host.attached or os.clock() > deadline
		task.wait(.15)
		local keyReleased = false
		for _, event in ipairs(sent) do
			if event.name == "W" and not event.pressed then keyReleased = true end
		end
		local afterMouse = game.UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2)
		local humanoid = game.Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
		assert(not host.attached and keyReleased and releases > 0, "disconnect cleanup missing")
		assert(humanoid.MoveDirection.Magnitude < .01, "fallback movement stuck")
		assert(not afterMouse, "camera mouse button stuck")
		return { detached = true, keyReleaseSent = keyReleased, fallbackReleases = releases,
			move = humanoid.MoveDirection.Magnitude, mouseBefore = beforeMouse, mouseAfter = afterMouse }
	end)
	if client then client.stop() end
	Keys.send, Fallback.releaseAll = send, releaseAll
	assert(ok, result)
	return result
end
