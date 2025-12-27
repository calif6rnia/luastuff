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

-- Module imports
local AnimationService = require(game:GetService("ServerScriptService").Server.Services.AnimationService)

-- Module table
local BrainrotMovement = {}

-- constants
local LERP_SPEED = 8
local EPS = 0.05
local MIN_SPEED = 8
local MAX_SPEED = 20

-- Stores per-model state
BrainrotMovement.Brainrots = {}

--[[
	Builds a list of objects to ignore for collision checks.

	We get the current players at the start so movement logic doesn't accidentally try to path through them.
    This list is read only for the state and not intended to be kept perfectly with player joins.
]]
local function buildIgnoreList()
	local ignore = {}
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	return ignore
end

--[[
	The clamps the total area
]]
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

--[[
	Get and store the brainrot's run animation.
]]
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

	-- Fallback try common animation object names on the model
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

--[[
	Move the brainrot model toward a targetPosition over a duration.

	Clamps the target to the state's plot and computes a clamped speed between
	MIN_SPEED and MAX_SPEED. If distance is negligible, movement is canceled.
]]
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

	targetPosition = clampPlot(state.plot, targetPosition)
	local dir = targetPosition - state.PrimaryPart.Position
	local distance = dir.Magnitude

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

--[[
	Add a brainrot model to the movement system.

	This state stores data that is used
]]
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

	-- Remove from system when the model is removed from the game.
	local conn
	conn = brainrotModel.AncestryChanged:Connect(function(_, parent)
		if not parent then
			conn:Disconnect()
			BrainrotMovement.Remove(brainrotModel)
		end
	end)
end

--[[
	Remove a brainrot from the movement system and stop any running animation.
]]
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

--[[
	Update a single brainrot state for the current delta.

	This function clamps position to the plot, handles Align constraints when
	present, starts/stops the run animation as appropriate, and moves the NPC
	toward the targetPosition at the computed speed.
]]
local function updateBrainrot(state, dt)
	if not state or not state.PrimaryPart or not state.plot then
		return
	end

	local pos = state.PrimaryPart.Position
	local clamped = clampPlot(state.plot, pos)

	-- If the part drifted outside the plot, snap/align it back in.
	if (pos - clamped).Magnitude > 0.2 then
		if state.AlignPosition then
			state.AlignPosition.Position = clamped
		else
			state.PrimaryPart.CFrame = CFrame.new(clamped, clamped + state.PrimaryPart.CFrame.LookVector)
		end
		pos = clamped
	end

	-- If not currently moving, lerp orientation toward last known heading and
	-- ensure any run animation is stopped.
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

	local runTrack = getTrack(state)
	if not runTrack then
		-- Helpful warning to identify missing animations for the model.
		warn("Failed to resolve run animation for model: " .. tostring(state.model and state.model.Name))
	elseif not runTrack.IsPlaying and dist > EPS then
		runTrack:Play()
	end

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

	-- Position update using AlignPosition when available to keep the physics engine in sync, otherwise set the CFrame directly.
	if state.AlignPosition then
		state.AlignPosition.Position = newPos
	else
		state.PrimaryPart.CFrame = CFrame.new(newPos, newPos + dir)
	end

	-- Rotation, prefer AlignOrientation if present, otherwise set PrimaryPart CFrame.
	if state.AlignOrientation then
		local desiredCf = CFrame.lookAt(newPos, newPos + dir)
		state.AlignOrientation.CFrame = state.AlignOrientation.CFrame:Lerp(desiredCf, math.clamp(LERP_SPEED * dt, 0, 1))
	else
		state.PrimaryPart.CFrame = CFrame.new(newPos, newPos + dir)
	end
end

-- Heartbeat loop, iterate states, remove invalid entries, and update valid ones.
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
	Remove all managed brainrot models from the system.
]]
function BrainrotMovement.ClearAll()
	for m, _ in pairs(BrainrotMovement.Brainrots) do
		BrainrotMovement.Remove(m)
	end
end

--[[
	Set the movement speed for a specific brainrot. The value is clamped to the
	allowed speed range so callers don't accidentally disable movement by
	providing invalid numbers.
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
	Pause movement and stop the run animation for the given brainrot.
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
	Resume movement for a paused brainrot. This does not change speed; it only
	allows the updater to continue moving the model toward its target.
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
