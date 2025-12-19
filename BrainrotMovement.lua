local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local AnimationService = require(game:GetService("ServerScriptService").Server.Services.AnimationService)
local BrainrotMovement = {}
local lerpspeed = 8
local eps = 0.05
local minspeed = 8
local maxspeed = 20

BrainrotMovement.Brainrots = {}

local function buildList()
	local ignore = {}
	for _, p in pairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	return ignore
end

local function clampPlot(plotPart, position, margin)
	margin = margin or 2
	local cframe = plotPart.CFrame
	local pos = cframe:PointToObjectSpace(position)
	local x = (plotPart.Size.X / 2) - margin
	local z = (plotPart.Size.Z / 2) - margin
	local clamped = Vector3.new(math.clamp(pos.X, -x, z), pos.Y, math.clamp(pos.Z, -z, z))
	return cframe:PointToWorldSpace(clamped)
end

local function getTrack(state)
	if state.runTrack then return state.runTrack end
	local animator = state.animator
	if not animator then return nil end

	local runTrack
	if AnimationService then
		runTrack = AnimationService.GetNPCAnimation(animator, "Run", state.model.Name)
	end

	-- kinda shitty fall back but it works
	if not runTrack then
		local anim = state.model:FindFirstChild("Run") or state.model:FindFirstChild("run") or state.model:FindFirstChild("RunAnim")
		if anim then
			runTrack = animator:LoadAnimation(anim)
		end
	end

	state.runTrack = runTrack
	return runTrack
end


function BrainrotMovement.MoveTo(brainrotModel, targetPosition, duration)
	if not brainrotModel then return end
	local state = BrainrotMovement.Brainrots[brainrotModel]
	if not state then return end
	if not state.PrimaryPart or not state.plot then return end
	targetPosition = clampPlot(state.plot, targetPosition)

	local dir = targetPosition - state.PrimaryPart.Position
	local distance = dir.Magnitude
	if distance <= eps then
		state.targetPosition = targetPosition
		state.duration = 0
		state.speed = 0
		state.moving = false
		return
	end

	dir = dir.Unit
	local dur = math.max(duration or 1, 0.01)
	local speed = distance / dur
	speed = math.clamp(speed, minspeed, maxspeed)
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

function BrainrotMovement.Add(brainrotModel, plotPart)
	if not brainrotModel or not brainrotModel.PrimaryPart or not plotPart then
		return
	end
	if BrainrotMovement.Brainrots[brainrotModel] then return end

	local state = {
		model = brainrotModel;
		PrimaryPart = brainrotModel.PrimaryPart;
		AlignPosition = brainrotModel:FindFirstChild("AlignPosition");
		AlignOrientation = brainrotModel:FindFirstChild("AlignOrientation");
		plot = plotPart;
		animator = (brainrotModel:FindFirstChild("AnimationController") and brainrotModel.AnimationController:FindFirstChild("Animator")) or nil;
		runTrack = nil;
		targetPosition = nil;
		speed = 0;
		duration = 0;
		moving = false;
		isAvoiding = false;
		avoidTarget = nil;
		avoidTimer = 0;
		obstacleCheckTimer = 0;
		ignore = buildList();
		lastDir = Vector3.new(0,0,1);
	}

	BrainrotMovement.Brainrots[brainrotModel] = state

	local conn
	conn = brainrotModel.AncestryChanged:Connect(function(_, parent)
		if not parent then
			conn:Disconnect()
			BrainrotMovement.Remove(brainrotModel)
		end
	end)
end

function BrainrotMovement.Remove(brainrotModel)
	local state = BrainrotMovement.Brainrots[brainrotModel]
	if not state then return end
	local runTrack = state.runTrack or (state.animator and state.animator:FindFirstChild("Run"))
	if runTrack and runTrack.IsPlaying then
		runTrack:Stop()
	end
	BrainrotMovement.Brainrots[brainrotModel] = nil
end

local function updateBrainrot(state, dt)
	if not state or not state.PrimaryPart or not state.plot then return end

	local pos = state.PrimaryPart.Position
	local clamped = clampPlot(state.plot, pos)

	if (pos - clamped).Magnitude > 0.2 then
		if state.AlignPosition then
			state.AlignPosition.Position = clamped
		else
			state.PrimaryPart.CFrame = CFrame.new(clamped, clamped + state.PrimaryPart.CFrame.LookVector)
		end
		pos = clamped
	end

	if not state.moving or not state.targetPosition then
		if state.AlignOrientation then
			local desiredCf = CFrame.lookAt(pos, pos + state.lastDir)
			state.AlignOrientation.CFrame = state.AlignOrientation.CFrame:Lerp(desiredCf, math.clamp(lerpspeed * dt, 0, 1))
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
		warn("bad")
	elseif not runTrack.IsPlaying and dist > eps then
		runTrack:Play()
	end

	if dist <= eps then
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

	-- position
	if state.AlignPosition then
		state.AlignPosition.Position = newPos
	else
		state.PrimaryPart.CFrame = CFrame.new(newPos, newPos + dir)
	end

	-- rotation
	if state.AlignOrientation then
		local desiredCf = CFrame.lookAt(newPos, newPos + dir)
		state.AlignOrientation.CFrame = state.AlignOrientation.CFrame:Lerp(desiredCf, math.clamp(lerpspeed * dt, 0, 1))
	else
		state.PrimaryPart.CFrame = CFrame.new(newPos, newPos + dir)
	end
end

RunService.Heartbeat:Connect(function(dt)
	for model, state in pairs(BrainrotMovement.Brainrots) do
		if not model or not model.Parent or not state.PrimaryPart or not state.plot then
			BrainrotMovement.Brainrots[model] = nil
		else
			updateBrainrot(state, dt)
		end
	end
end)


function BrainrotMovement.ClearAll()
	for m, _ in pairs(BrainrotMovement.Brainrots) do
		BrainrotMovement.Remove(m)
	end
end

function BrainrotMovement.SetSpeed(brainrotModel, newSpeed)
	if not brainrotModel then return end
	local state = BrainrotMovement.Brainrots[brainrotModel]
	if not state then return end
	state.speed = math.clamp(newSpeed, minspeed, maxspeed)
end

function BrainrotMovement.Pause(brainrotModel)
	if not brainrotModel then return end
	local state = BrainrotMovement.Brainrots[brainrotModel]
	if not state then return end
	state.moving = false
	state.speed = 0
	local run = getTrack(state)
	if run then run:Stop() end
end

function BrainrotMovement.Resume(brainrotModel)
	if not brainrotModel then return end
	local state = BrainrotMovement.Brainrots[brainrotModel]
	if not state then return end
	state.moving = true
	local run = getTrack(state)
	if run then run:Play() end
end

return BrainrotMovement
