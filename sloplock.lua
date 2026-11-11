--[[
    sloplock.lua - slop camlock feature set on Atlanta UI
    paste into executor or loadstring this file
    requires: Atlanta (i77lhm/Libraries), executor with gethui/getcustomasset
--]]

local library, themes = loadstring(game:HttpGet("https://raw.githubusercontent.com/i77lhm/Libraries/refs/heads/main/Atlanta/Library.lua"))()

----------------------------------------------------------------
-- services / cache
----------------------------------------------------------------
local players     = game:GetService("Players")
local run_service = game:GetService("RunService")
local stats       = game:GetService("Stats")
local workspace_  = workspace
local camera      = workspace_.CurrentCamera
local lp          = players.LocalPlayer
local mouse       = lp:GetMouse()
local gui_service = game:GetService("GuiService")

local world_to_viewport = camera.WorldToViewportPoint
local look_at           = CFrame.lookAt
local vector2_new       = Vector2.new
local vector3_new       = Vector3.new
local tick_             = tick

----------------------------------------------------------------
-- state
----------------------------------------------------------------
local lock = {
    enabled        = false,   -- master toggle
    locked         = false,   -- hotkey state: target acquired or not
    target         = nil,
    keybind        = Enum.KeyCode.Q,
    disable_key    = Enum.KeyCode.P,
    prediction     = 0.13,
    auto_prediction= false,
    smoothing      = 1,       -- 1 = instant, >1 = lerp divisor
    aim_part       = "HumanoidRootPart",
    h_offset       = 0,
    v_offset       = 0,
    jump_offset    = 0.22,
    fall_offset    = 0.22,
    auto_air       = false,
    auto_shoot     = false,
    air_delay      = 0.08,
    no_floor_shots = false,
    resolver       = false,
    -- checks
    wall_check     = true,
    knocked_check  = true,
    grabbed_check  = true,
    forcefield_check = true,
    crew_check     = false,
    distance_check = false,
    max_distance   = 1500,
    -- visuals
    highlight      = false,
    tracer         = false,
    tracer_color   = Color3.fromRGB(155, 125, 235),
    dot            = false,
    dot_color      = Color3.fromRGB(155, 125, 235),
    -- fov
    fov            = true,
    fov_visible    = true,
    fov_filled     = false,
    fov_radius     = 90,
    fov_thickness  = 1,
    fov_outline    = false,
    fov_color      = Color3.fromRGB(155, 125, 235),
    fov_outline_color = Color3.fromRGB(0, 0, 0),
    fov_spin       = false,
    fov_spin_speed = 25,
    fov_rotation   = 0,
}

local ping_cache = 0

----------------------------------------------------------------
-- drawings
----------------------------------------------------------------
local function new_drawing(class, props)
    local d = Drawing.new(class)
    for k, v in next, props do
        d[k] = v
    end
    return d
end

local fov_circle        = new_drawing("Circle", {Filled = false, Thickness = 1, Color = lock.fov_color, NumSides = 60, Radius = lock.fov_radius, Visible = false, ZIndex = 10})
local fov_circle_outline= new_drawing("Circle", {Filled = false, Thickness = 3, Color = lock.fov_outline_color, NumSides = 60, Radius = lock.fov_radius, Visible = false, ZIndex = 9})
local tracer_line       = new_drawing("Line",   {Thickness = 1, Color = lock.tracer_color, Visible = false, ZIndex = 11})
local target_dot        = new_drawing("Circle", {Filled = true, Thickness = 1, Color = lock.dot_color, Radius = 3, NumSides = 8, Visible = false, ZIndex = 11})
local target_highlight  = Instance.new("Highlight")
target_highlight.FillColor = Color3.fromRGB(155, 125, 235)
target_highlight.OutlineColor = Color3.fromRGB(0, 0, 0)
target_highlight.Enabled = false

----------------------------------------------------------------
-- helpers
----------------------------------------------------------------
local function get_ping()
    local item = stats.Network.ServerStatsItem["Data Ping"]
    if not item then return 0 end
    return tonumber(item:GetValueString():split("(")[1]) or 0
end

local function get_target_part(char)
    return char and char:FindFirstChild(lock.aim_part)
end

local function is_knocked(char)
    local effects = char and char:FindFirstChild("BodyEffects")
    local ko = effects and effects:FindFirstChild("K.O")
    return ko and ko.Value or false
end

local function is_grabbed(char)
    return char and char:FindFirstChild("GRABBING_COINSTRAINT") ~= nil
end

local function is_crewmate(player)
    local my_crew = lp:FindFirstChild("Data") and lp.Data:FindFirstChild("Team")
    local their_crew = player:FindFirstChild("Data") and player.Data:FindFirstChild("Team")
    if not (my_crew and their_crew) then return false end
    return my_crew.Value ~= "" and my_crew.Value == their_crew.Value
end

local function has_forcefield(char)
    local ff = char and char:FindFirstChild("ForceField")
    return ff ~= nil
end

local function wall_between(part)
    if not lock.wall_check then return false end
    local origin = camera.CFrame.Position
    local dir = (part.Position - origin)
    local params = RaycastParams.new()
    params.FilterDescendantsInstances = {lp.Character, camera}
    params.FilterType = Enum.RaycastFilterType.Exclude
    local hit = workspace_:Raycast(origin, dir, params)
    if not hit then return false end
    return not hit.Instance:IsDescendantOf(part.Parent)
end

local function is_valid(player)
    if player == lp then return false end
    local char = player.Character
    if not char then return false end
    local part = get_target_part(char)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not (part and hum and hum.Health > 0) then return false end
    local _, on_screen = world_to_viewport(camera, part.Position)
    if not on_screen then return false end
    if lock.knocked_check and is_knocked(char) then return false end
    if lock.grabbed_check and is_grabbed(char) then return false end
    if lock.forcefield_check and has_forcefield(char) then return false end
    if lock.crew_check and is_crewmate(player) then return false end
    if wall_between(part) then return false end
    if lock.distance_check then
        local dist = (camera.CFrame.Position - part.Position).Magnitude
        if dist > lock.max_distance then return false end
    end
    return true
end

local function get_closest()
    local mouse_pos = vector2_new(mouse.X, mouse.Y + gui_service:GetGuiInset().Y)
    local best, best_dist = nil, math.huge
    for _, player in next, players:GetPlayers() do
        if is_valid(player) then
            local part = get_target_part(player.Character)
            local pos, _ = world_to_viewport(camera, part.Position)
            local screen = vector2_new(pos.X, pos.Y)
            local dist = (screen - mouse_pos).Magnitude
            local radius = lock.fov and lock.fov_radius * 3.2 or math.huge
            if not (lock.fov and dist > radius) and dist < best_dist then
                best, best_dist = player, dist
            end
        end
    end
    return best
end

-- auto prediction: slop-style ping tiers
local pred_tiers = {
    {225, 0.1258}, {215, 0.1128}, {205, 0.0971}, {190, 0.0878},
    {180, 0.0843}, {170, 0.0811}, {160, 0.0780}, {150, 0.0747},
    {140, 0.0711}, {130, 0.0692}, {120, 0.0650}, {110, 0.0610},
    {105, 0.0588}, { 90, 0.0550}, { 80, 0.0521}, { 70, 0.0505},
    { 60, 0.0475}, { 50, 0.0440}, { 40, 0.0402}, { 30, 0.0325},
    { 20, 0.0250},
}
local function auto_prediction_value()
    for _, tier in next, pred_tiers do
        if ping_cache < tier[1] then
            return tier[2]
        end
    end
    return lock.prediction
end

----------------------------------------------------------------
-- notifications
----------------------------------------------------------------
local function notify(text)
    game:GetService("StarterGui"):SetCore("SendNotification", {
        Title = "sloplock",
        Text = text,
        Duration = 3,
    })
end

----------------------------------------------------------------
-- lock / unlock
----------------------------------------------------------------
local function clear_target()
    lock.locked = false
    lock.target = nil
    target_highlight.Enabled = false
    tracer_line.Visible = false
    target_dot.Visible = false
end

local function toggle_lock()
    if not lock.enabled then
        notify("Enable camlock in the menu first")
        return
    end
    if lock.locked then
        clear_target()
        notify("Unlocked")
    else
        local target = get_closest()
        if target then
            lock.target = target
            lock.locked = true
            notify("Locked: " .. target.Name)
        else
            notify("No target")
        end
    end
end

local function toggle_master()
    lock.enabled = not lock.enabled
    if not lock.enabled then
        clear_target()
    end
    notify(lock.enabled and "Camlock enabled" or "Camlock disabled")
end

----------------------------------------------------------------
-- input
----------------------------------------------------------------
game:GetService("UserInputService").InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == lock.keybind then
        toggle_lock()
    elseif input.KeyCode == lock.disable_key then
        toggle_master()
    end
end)

----------------------------------------------------------------
-- render loops
----------------------------------------------------------------
run_service.RenderStepped:Connect(function()
    -- fov circle
    if lock.fov then
        if lock.fov_spin then
            lock.fov_rotation = (lock.fov_rotation + lock.fov_spin_speed) % 360
            fov_circle.Rotation = lock.fov_rotation
            fov_circle_outline.Rotation = lock.fov_rotation
        end
        local vis = lock.fov_visible and lock.enabled
        fov_circle.Radius = lock.fov_radius
        fov_circle.Thickness = lock.fov_thickness
        fov_circle.Color = lock.fov_color
        fov_circle.Filled = lock.fov_filled
        fov_circle.Visible = vis
        fov_circle_outline.Radius = lock.fov_radius
        fov_circle_outline.Visible = vis and lock.fov_outline
        fov_circle_outline.Color = lock.fov_outline_color
    else
        fov_circle.Visible = false
        fov_circle_outline.Visible = false
    end

    if not lock.enabled then return end
    ping_cache = get_ping()

    -- re-acquire target if lock key held state and target gone
    if lock.locked then
        local char = lock.target and lock.target.Character
        if not (lock.target and lock.target.Parent and char and get_target_part(char)) then
            clear_target()
            notify("Target lost")
        end
    end

    if not (lock.locked and lock.target) then return end
    local char = lock.target.Character
    local part = get_target_part(char)
    if not part then return end

    -- resolver: clamp underground / air-shot offsets
    local vel = part.AssemblyLinearVelocity
    local prediction = lock.auto_prediction and auto_prediction_value() or lock.prediction
    local vertical_mult = prediction
    if vel.Y > lock.jump_offset then
        vertical_mult = prediction * 2
    elseif vel.Y < -lock.fall_offset then
        vertical_mult = prediction
    end

    local predicted = part.Position + vector3_new(vel.X * prediction, vel.Y * vertical_mult, vel.Z * prediction)
    if lock.no_floor_shots and vel.Y < -lock.fall_offset then
        predicted += vector3_new(0, 3.5, 0)
    end
    if lock.resolver and part.Position.Y < -50 then
        predicted = vector3_new(predicted.X, 0, predicted.Z)
    end
    predicted += vector3_new(lock.h_offset, lock.v_offset, 0)

    local goal = look_at(camera.CFrame.Position, predicted)
    if lock.smoothing <= 1 then
        camera.CFrame = goal
    else
        camera.CFrame = camera.CFrame:Lerp(goal, 1 / lock.smoothing)
    end

    -- target visuals
    target_highlight.Adornee = char
    target_highlight.Enabled = lock.highlight

    local pos, on_screen = world_to_viewport(camera, part.Position)
    local screen = vector2_new(pos.X, pos.Y)
    if on_screen then
        if lock.tracer then
            tracer_line.From = vector2_new(camera.ViewportSize.X / 2, camera.ViewportSize.Y)
            tracer_line.To = screen
            tracer_line.Color = lock.tracer_color
            tracer_line.Visible = true
        else
            tracer_line.Visible = false
        end
        if lock.dot then
            target_dot.Position = screen
            target_dot.Color = lock.dot_color
            target_dot.Visible = true
        else
            target_dot.Visible = false
        end
    else
        tracer_line.Visible = false
        target_dot.Visible = false
    end
end)

run_service.Heartbeat:Connect(function()
    -- auto air + auto shoot
    if not (lock.enabled and lock.auto_air and lock.auto_shoot and lock.locked and lock.target) then return end
    local char = lock.target.Character
    local root = char and char:FindFirstChild("HumanoidRootPart")
    if not root then return end
    local vel = root.AssemblyLinearVelocity
    if (vel.Y > lock.jump_offset or vel.Y < -lock.fall_offset) then
        if not lock._last_air or tick_() - lock._last_air > lock.air_delay then
            lock._last_air = tick_()
            local tool = lp.Character and lp.Character:FindFirstChildOfClass("Tool")
            if tool then
                tool:Activate()
            end
        end
    end
end)

----------------------------------------------------------------
-- UI
----------------------------------------------------------------
local window = library:window({
    name = os.date("sloplock - %b %d %Y"),
    size = UDim2.new(0, 750, 0, 782),
})

local cam_tab   = window:tab({name = "Camlock"})
local vis_tab   = window:tab({name = "Visuals"})
local checks_tab= window:tab({name = "Checks"})
local misc_tab  = window:tab({name = "Misc"})

-- camlock
do
    local column = cam_tab:column()
    local main, air = column:multi_section({names = {"Camlock", "Air / Shoot"}})

    main:toggle({name = "Enabled", flag = "lock_enabled", callback = function(v)
        lock.enabled = v
        if not v then
            clear_target()
        end
    end})
    main:keybind({name = "Lock Key", flag = "lock_key", callback = toggle_lock})
    main:keybind({name = "Disable Key", flag = "lock_disable_key", callback = toggle_master})
    main:dropdown({name = "Aim Part", flag = "lock_aim_part", items = {"HumanoidRootPart", "UpperTorso", "Head", "LowerTorso", "RightHand"}, default = "HumanoidRootPart", callback = function(v)
        lock.aim_part = v
    end})
    main:toggle({name = "Auto Prediction", flag = "lock_auto_pred", callback = function(v)
        lock.auto_prediction = v
    end})
    main:slider({name = "Prediction", flag = "lock_prediction", min = 0, max = 1, default = 0.13, interval = 0.001, callback = function(v)
        lock.prediction = v
    end})
    main:slider({name = "Smoothness", flag = "lock_smoothing", min = 1, max = 10, default = 1, interval = 0.05, suffix = "x", callback = function(v)
        lock.smoothing = v
    end})
    main:slider({name = "Horizontal Offset", flag = "lock_h_offset", min = -2, max = 2, default = 0, interval = 0.01, callback = function(v)
        lock.h_offset = v
    end})
    main:slider({name = "Vertical Offset", flag = "lock_v_offset", min = -2, max = 2, default = 0, interval = 0.01, callback = function(v)
        lock.v_offset = v
    end})

    air:toggle({name = "Auto Air", flag = "lock_auto_air", callback = function(v)
        lock.auto_air = v
    end})
    air:toggle({name = "Auto Shoot", flag = "lock_auto_shoot", callback = function(v)
        lock.auto_shoot = v
    end})
    air:slider({name = "Air Delay", flag = "lock_air_delay", min = 0, max = 1, default = 0.08, interval = 0.01, suffix = "s", callback = function(v)
        lock.air_delay = v
    end})
    air:slider({name = "Jump Offset", flag = "lock_jump_offset", min = 0, max = 2, default = 0.22, interval = 0.01, callback = function(v)
        lock.jump_offset = v
    end})
    air:slider({name = "Fall Offset", flag = "lock_fall_offset", min = 0, max = 2, default = 0.22, interval = 0.01, callback = function(v)
        lock.fall_offset = v
    end})
    air:toggle({name = "No Floor Shots", flag = "lock_no_floor", callback = function(v)
        lock.no_floor_shots = v
    end})
    air:toggle({name = "Underground Resolver", flag = "lock_resolver", callback = function(v)
        lock.resolver = v
    end})
end

-- visuals
do
    local column = vis_tab:column()
    local target_vis, fov_vis = column:multi_section({names = {"Target", "FOV"}})

    target_vis:toggle({name = "Highlight", flag = "tv_highlight", callback = function(v)
        lock.highlight = v
        target_highlight.Enabled = v and lock.locked
    end}):colorpicker({name = "Fill", flag = "tv_highlight_fill", color = Color3.fromHex("#9B7DEB"), callback = function(c)
        target_highlight.FillColor = c
    end})
    target_vis:toggle({name = "Tracer", flag = "tv_tracer", callback = function(v)
        lock.tracer = v
    end}):colorpicker({name = "Color", flag = "tv_tracer_color", color = Color3.fromHex("#9B7DEB"), callback = function(c)
        lock.tracer_color = c
        tracer_line.Color = c
    end})
    target_vis:toggle({name = "Dot", flag = "tv_dot", callback = function(v)
        lock.dot = v
    end}):colorpicker({name = "Color", flag = "tv_dot_color", color = Color3.fromHex("#9B7DEB"), callback = function(c)
        lock.dot_color = c
        target_dot.Color = c
    end})

    fov_vis:toggle({name = "Enabled", flag = "fov_enabled", callback = function(v)
        lock.fov = v
    end})
    fov_vis:toggle({name = "Show", flag = "fov_visible", callback = function(v)
        lock.fov_visible = v
    end})
    fov_vis:toggle({name = "Filled", flag = "fov_filled", callback = function(v)
        lock.fov_filled = v
    end}):colorpicker({name = "Color", flag = "fov_color", color = Color3.fromHex("#9B7DEB"), alpha = 0.5, callback = function(c)
        lock.fov_color = c
    end})
    fov_vis:toggle({name = "Outline", flag = "fov_outline", callback = function(v)
        lock.fov_outline = v
    end}):colorpicker({name = "Outline Color", flag = "fov_outline_color", color = Color3.fromHex("#000000"), callback = function(c)
        lock.fov_outline_color = c
    end})
    fov_vis:slider({name = "Radius", flag = "fov_radius", min = 10, max = 500, default = 90, interval = 1, callback = function(v)
        lock.fov_radius = v
    end})
    fov_vis:slider({name = "Thickness", flag = "fov_thickness", min = 1, max = 5, default = 1, interval = 1, callback = function(v)
        lock.fov_thickness = v
    end})
    fov_vis:toggle({name = "Spin", flag = "fov_spin", callback = function(v)
        lock.fov_spin = v
    end})
    fov_vis:slider({name = "Spin Speed", flag = "fov_spin_speed", min = 0, max = 100, default = 25, interval = 1, suffix = "°", callback = function(v)
        lock.fov_spin_speed = v
    end})
end

-- checks
do
    local column = checks_tab:column()
    local section = column:section({name = "Target Checks"})

    section:toggle({name = "Wall Check", flag = "ck_wall", callback = function(v)
        lock.wall_check = v
    end})
    section:toggle({name = "Knocked Check", flag = "ck_knocked", callback = function(v)
        lock.knocked_check = v
    end})
    section:toggle({name = "Grabbed Check", flag = "ck_grabbed", callback = function(v)
        lock.grabbed_check = v
    end})
    section:toggle({name = "ForceField Check", flag = "ck_ff", callback = function(v)
        lock.forcefield_check = v
    end})
    section:toggle({name = "Crew Check", flag = "ck_crew", callback = function(v)
        lock.crew_check = v
    end})
    section:toggle({name = "Distance Check", flag = "ck_distance", callback = function(v)
        lock.distance_check = v
    end})
    section:slider({name = "Max Distance", flag = "ck_max_distance", min = 100, max = 5000, default = 1500, interval = 10, suffix = "st", callback = function(v)
        lock.max_distance = v
    end})
end

-- misc
do
    local column = misc_tab:column()
    local section = column:section({name = "Utility"})

    section:button({name = "Rejoin Server", callback = function()
        game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, game.JobId, lp)
    end})
    section:button({name = "Copy JobId", callback = function()
        setclipboard(game.JobId)
    end})
    section:label({name = "sloplock - camlock on atlanta"})
end

cam_tab.open_tab()

-- theme init, same as example
library:config_list_update()
for index, value in themes.preset do
    pcall(function()
        library:update_theme(index, value)
    end)
end
task.wait()
library.old_config = library:get_config()
