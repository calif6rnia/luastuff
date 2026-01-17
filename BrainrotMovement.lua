--[[
	BrainrotMovement.lua
	Manages movement and animations for brainrot models on a plot.
	This module keeps per-model state and updates the model overtime.
]]

-- Services
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local AnimationService = require(game:GetService("ServerScriptService").Server.Services.AnimationService)
local BrainrotMovement = {}

--[[
	Movement constants:
	- LERP_SPEED: speed of the lerp
	- EPS: Minimum distance for movement completion
	- MIN/MAX_SPEED: Minimum and max speed for clamping
]]
local LERP_SPEED = 8
local EPS = 0.05
local MIN_SPEED = 8
local MAX_SPEED = 20
BrainrotMovement.Brainrots = {}

--[[ Build static ignore list on start  for faster collision checks (won't update). ]]
local function buildIgnoreList()
	local ignore = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	return ignore
end

--[[ Clamp position to plot bounds with optional margin. ]]
local function clampPlot(plotPart, position, margin)
	margin = margin or 2
	local cframe = plotPart.CFrame
	local pos = cframe:PointToObjectSpace(position)

	local x = (plotPart.Size.X / 2) - margin
	local z = (plotPart.Size.Z / 2) - margin

	local clamped = Vector3.new(
		math.clamp(pos.X, -x, x),
		pos.Y,
		math.clamp(pos.Z, -z, z)
	)

	return cframe:PointToWorldSpace(clamped)
end

--[[ Get/create run animation: prefer AnimationService NPC clip, fallback to model's run animations. ]]
local function getTrack(state)
	if state.runTrack then
		return state.runTrack
	end

	local animator = state.animator
	if not animator then
		return nil
	end

	local runTrack

	if AnimationService then
		runTrack = AnimationService.GetNPCAnimation(animator, "Run", state.model.Name)
	end

	if not runTrack then
		local anim = state.model:FindFirstChild("Run")
			or state.model:FindFirstChild("run")
			or state.model:FindFirstChild("RunAnim")

		if anim then
			runTrack = animator:LoadAnimation(anim)
		end
	end

	state.runTrack = runTrack
	return runTrack
end

--[[ Move to target: clamp pos to plot, compute speed from distance/duration, start run animation if needed, actual movement occurs in updateBrainrot. ]]
function BrainrotMovement.MoveTo(brainrotModel, targetPosition, duration)
	if not brainrotModel then
		return
	end

	local state = BrainrotMovement.Brainrots[brainrotModel]
	if not state then
		return
	end

	if not state.PrimaryPart or not state.plot then
		return
	end

	-- Ensure target is within plot boundaries
	targetPosition = clampPlot(state.plot, targetPosition)
	local dir = targetPosition - state.PrimaryPart.Position
	local distance = dir.Magnitude

	-- Early exit if already at target
	if distance <= EPS then
		state.targetPosition = targetPosition
		state.duration = 0
		state.speed = 0
		state.moving = false
		return
	end

	dir = dir.Unit
	local dur = math.max(duration or 1, 0.01)
	local speed = distance / dur
	speed = math.clamp(speed, MIN_SPEED, MAX_SPEED)

	-- Update movement state
	state.targetPosition = targetPosition
	state.duration = dur
	state.speed = speed
	state.moving = true
	state.isAvoiding = false
	state.obstacleCheckTimer = 0
	state.lastDir = dir

	local runTrack = getTrack(state)
	if runTrack and not runTrack.IsPlaying then
		runTrack:Play()
	end
end

--[[ Register brainrot: stores model, plot bounds, animation and movement state, and sets up tracking for cleanup. ]]
function BrainrotMovement.Add(brainrotModel, plotPart)
	if not brainrotModel or not brainrotModel.PrimaryPart or not plotPart then
		return
	end

	if BrainrotMovement.Brainrots[brainrotModel] then
		return
	end

	local state = {
		model = brainrotModel,
		PrimaryPart = brainrotModel.PrimaryPart,
		AlignPosition = brainrotModel:FindFirstChild("AlignPosition"),
		AlignOrientation = brainrotModel:FindFirstChild("AlignOrientation"),
		plot = plotPart,
		animator = (brainrotModel:FindFirstChild("AnimationController")
			and brainrotModel.AnimationController:FindFirstChild("Animator"))
			or nil,
		runTrack = nil,
		targetPosition = nil,
		speed = 0,
		duration = 0,
		moving = false,
		isAvoiding = false,
		avoidTarget = nil,
		avoidTimer = 0,
		obstacleCheckTimer = 0,
		ignore = buildIgnoreList(),
		lastDir = Vector3.new(0, 0, 1),
	}

	BrainrotMovement.Brainrots[brainrotModel] = state

	-- Automatic cleanup when model is removed
	local conn
	conn = brainrotModel.AncestryChanged:Connect(function(_, parent)
		if not parent then
			conn:Disconnect()
			BrainrotMovement.Remove(brainrotModel)
		end
	end)
end

--[[ Remove brainrot from movement: stop animations, remove from tracking. ]]
function BrainrotMovement.Remove(brainrotModel)
	local state = BrainrotMovement.Brainrots[brainrotModel]
	if not state then
		return
	end

	local runTrack = state.runTrack
	if runTrack and runTrack.IsPlaying then
		runTrack:Stop()
	end

	BrainrotMovement.Brainrots[brainrotModel] = nil
end

--[[ brainrot updater: keeps model inside plot, moves to target, manages animations, and uses AlignConstraints for smooth physics. ]]
local function updateBrainrot(state, dt)
	if not state or not state.PrimaryPart or not state.plot then
		return
	end

	local pos = state.PrimaryPart.Position
	local clamped = clampPlot(state.plot, pos)

	-- plot correction
	if (pos - clamped).Magnitude > 0.2 then
		if state.AlignPosition then
			state.AlignPosition.Position = clamped
		else
			state.PrimaryPart.CFrame = CFrame.new(clamped, clamped + state.PrimaryPart.CFrame.LookVector)
		end
		pos = clamped
	end

	-- Handle idle state (no movement)
	if not state.moving or not state.targetPosition then
		if state.AlignOrientation then
			local desiredCf = CFrame.lookAt(pos, pos + state.lastDir)
			state.AlignOrientation.CFrame = state.AlignOrientation.CFrame:Lerp(desiredCf, math.clamp(LERP_SPEED * dt, 0, 1))
		end

		local runTrack = getTrack(state)
		if runTrack and runTrack.IsPlaying then
			runTrack:Stop()
		end

		return
	end

	local targ = state.targetPosition - pos
	local dist = targ.Magnitude

	-- Manage run animation based on movement state
	local runTrack = getTrack(state)
	if not runTrack then
		warn("Failed to get run animation")
	elseif not runTrack.IsPlaying and dist > EPS then
		runTrack:Play()
	end

	-- Check if reached destination
	if dist <= EPS then
		state.moving = false
		state.speed = 0
		if runTrack and runTrack.IsPlaying then
			runTrack:Stop()
		end
		return
	end

	local dir = targ.Unit
	state.lastDir = dir

	local moveAmount = dir * (state.speed * dt)
	if moveAmount.Magnitude > dist then
		moveAmount = dir * dist
	end

	local newPos = clampPlot(state.plot, pos + moveAmount)

	-- Update position using AlignPosition if available, otherwise use CFrame
	if state.AlignPosition then
		state.AlignPosition.Position = newPos
	else
		state.PrimaryPart.CFrame = CFrame.new(newPos, newPos + dir)
	end

	-- Update rotation with smoothing
	if state.AlignOrientation then
		local desiredCf = CFrame.lookAt(newPos, newPos + dir)
		state.AlignOrientation.CFrame = state.AlignOrientation.CFrame:Lerp(desiredCf, math.clamp(LERP_SPEED * dt, 0, 1))
	else
		state.PrimaryPart.CFrame = CFrame.new(newPos, newPos + dir)
	end
end

--[[
	Main update loop - processes all active brainrots every frame.
	
	This Heartbeat connection ensures smooth, movement.
]]
RunService.Heartbeat:Connect(function(dt)
	for model, state in pairs(BrainrotMovement.Brainrots) do
		if not model or not model.Parent or not state.PrimaryPart or not state.plot then
			BrainrotMovement.Brainrots[model] = nil
		else
			updateBrainrot(state, dt)
		end
	end
end)

--[[
	Removes all brainrots from the system.
	
	Useful for cleanup during game
]]
function BrainrotMovement.ClearAll()
	for m, _ in pairs(BrainrotMovement.Brainrots) do
		BrainrotMovement.Remove(m)
	end
end

--[[
	Sets movement speed for a specific brainrot.
	
	The speed is clamped to prevent values outside the normal range
]]
function BrainrotMovement.SetSpeed(brainrotModel, newSpeed)
	if not brainrotModel then
		return
	end

	local state = BrainrotMovement.Brainrots[brainrotModel]
	if not state then
		return
	end

	state.speed = math.clamp(newSpeed, MIN_SPEED, MAX_SPEED)
end

--[[
	Pauses movement for a brainrot.
	
	Stops both movement and animation while keeping the current state
]]
function BrainrotMovement.Pause(brainrotModel)
	if not brainrotModel then
		return
	end

	local state = BrainrotMovement.Brainrots[brainrotModel]
	if not state then
		return
	end

	state.moving = false
	state.speed = 0

	local run = getTrack(state)
	if run then
		run:Stop()
	end
end

--[[
	Resumes movement for a paused brainrot.
	
	Assumes the brainrot already has a target position set.
	The animation is restarted to match the movement state.
]]
function BrainrotMovement.Resume(brainrotModel)
	if not brainrotModel then
		return
	end

	local state = BrainrotMovement.Brainrots[brainrotModel]
	if not state then
		return
	end

	state.moving = true

	local run = getTrack(state)
	if run then
		run:Play()
	end
end

return BrainrotMovement
