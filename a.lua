-- Type Soul | Raid Farm
-- Scans all worlds for servers with active raids (Raid == true in server list),
-- joins them, then resets repeatedly until the server puts us in ArenaSpectator
-- (raid lobby). Once there, stays idle to stack Raid Points passively.
-- Does NOT interact with BossRaidNPC / instance boss fights — world raids only.

local Players         = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local VirtualUser     = game:GetService("VirtualUser")
local RunService      = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer

-- ─── Config ───────────────────────────────────────────────────────────────────

local SCAN_COOLDOWN   = 30   -- seconds between server-list scans when no raid found
local REJOIN_WAIT     = 20   -- seconds to wait after firing a teleport before scanning again
local REQUEST_DELAY   = 0.4  -- delay between per-world requests to avoid throttle
local RESET_WAIT      = 6    -- seconds to wait after each self-kill before checking state / killing again

-- Worlds to search (same order the in-game server list uses)
local Worlds = {
    "Karakura Town",
    "Hueco Mundo",
    "Soul Society",
    "Las Noches",
    "Wandenreich City",
    "Rukon District",
    "Naruki City",
}

-- ─── Helpers ──────────────────────────────────────────────────────────────────

local function Notify(Title, Msg, Duration)
    pcall(function()
        game:GetService("StarterGui"):SetCore("SendNotification", {
            Title    = Title,
            Text     = Msg,
            Duration = Duration or 6,
        })
    end)
end

local function GetCharacter()
    return LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
end

local function IsInRaid()
    local Ambience = workspace:FindFirstChild("Ambience")
    return Ambience ~= nil and Ambience:GetAttribute("RaidActive") == true
end

local function GetRaidPoints()
    local Char = LocalPlayer.Character
    if not Char then return 0 end
    return math.floor(Char:GetAttribute("RaidPoints") or 0)
end

-- Returns true once the server has put us in the raid lobby / spectator state.
-- Two equivalent signals from the decompile:
--   character:GetAttribute("CurrentState") == "ArenaSpectator"  (ClientHandler.lua)
--   player:GetAttribute("Spectating") == true                   (Leaderboard.lua)
local function IsInLobby()
    if LocalPlayer:GetAttribute("Spectating") == true then return true end
    local Char = LocalPlayer.Character
    if Char and Char:GetAttribute("CurrentState") == "ArenaSpectator" then return true end
    return false
end

-- Kills the character instantly. The server will respawn us and track the death.
local function ResetCharacter()
    local Char = LocalPlayer.Character
    if not Char then return end
    local Humanoid = Char:FindFirstChildOfClass("Humanoid")
    if Humanoid and Humanoid.Health > 0 then
        Humanoid.Health = 0
    end
end

-- ─── AFK hooks ────────────────────────────────────────────────────────────────

-- Override the game's own AFK confirmation remote so the server never boots us.
-- The server invokes AfkPrompt.OnClientInvoke and boots the player if it returns
-- falsy or times out; returning true keeps us in.
local function HookAfkPrompt()
    local Requests = ReplicatedStorage:FindFirstChild("Requests")
    if not Requests then return end
    local Prompt = Requests:FindFirstChild("AfkPrompt")
    if not Prompt then return end
    Prompt.OnClientInvoke = function()
        Notify("Raid Farm", "AFK check — confirmed!", 3)
        return true
    end
end

-- Prevent Roblox's own 20-minute idle kick by simulating input when idle.
LocalPlayer.Idled:Connect(function()
    pcall(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end)

-- Re-hook after each respawn in case CharacterAdded reloads ClientHandler scripts.
LocalPlayer.CharacterAdded:Connect(function()
    task.wait(2)
    HookAfkPrompt()
end)

-- ─── Server scanning ──────────────────────────────────────────────────────────

-- Calls RequestServerList for a single world and returns the first non-full server
-- that has Raid == true, or nil if none found.
local function FindRaidInWorld(WorldName)
    local Requests = ReplicatedStorage:FindFirstChild("Requests")
    if not Requests then return nil end
    local RequestServerList = Requests:FindFirstChild("RequestServerList")
    if not RequestServerList then return nil end

    local Ok, Response = pcall(function()
        return RequestServerList:InvokeServer(WorldName, true)
    end)

    if not Ok or type(Response) ~= "table" then return nil end

    for _, Servers in pairs(Response) do
        if type(Servers) == "table" then
            for _, ServerData in pairs(Servers) do
                if type(ServerData) == "table"
                    and ServerData.Raid == true
                    and (ServerData.ServerPlayers or 0) < (ServerData.ServerPlayerMax or 99)
                then
                    return {
                        WorldName   = WorldName,
                        ServerName  = ServerData.ServerName  or "Unknown",
                        JobID       = ServerData.JobID,
                        ReservedId  = ServerData.ReservedId,
                        PlayerCount = ServerData.ServerPlayers or 0,
                    }
                end
            end
        end
    end

    return nil
end

-- Iterates all worlds and returns the first raid server found.
local function ScanAllWorlds()
    for _, WorldName in ipairs(Worlds) do
        local Found = FindRaidInWorld(WorldName)
        if Found then return Found end
        task.wait(REQUEST_DELAY)
    end
    return nil
end

-- ─── Teleport ─────────────────────────────────────────────────────────────────

local function JoinRaidServer(ServerInfo)
    local Char = GetCharacter()

    local Ok, CharHandler = pcall(function()
        return Char:WaitForChild("CharacterHandler", 5)
    end)
    if not Ok or not CharHandler then
        warn("[RaidFarm] CharacterHandler not found")
        return false
    end

    local Ok2, Remotes = pcall(function()
        return CharHandler:WaitForChild("Remotes", 5)
    end)
    if not Ok2 or not Remotes then
        warn("[RaidFarm] Remotes not found")
        return false
    end

    local Teleport = Remotes:FindFirstChild("ServerListTeleport")
    if not Teleport then
        warn("[RaidFarm] ServerListTeleport remote not found")
        return false
    end

    Teleport:FireServer(
        ServerInfo.WorldName,
        ServerInfo.JobID,
        nil,
        ServerInfo.ReservedId
    )
    return true
end

-- ─── HUD ──────────────────────────────────────────────────────────────────────

local function BuildHUD()
    -- Remove any old instance
    local Existing = LocalPlayer.PlayerGui:FindFirstChild("RaidFarmHUD")
    if Existing then Existing:Destroy() end

    local Gui    = Instance.new("ScreenGui")
    Gui.Name     = "RaidFarmHUD"
    Gui.ResetOnSpawn = false
    Gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    Gui.Parent   = LocalPlayer.PlayerGui

    local Frame  = Instance.new("Frame")
    Frame.Size   = UDim2.new(0, 230, 0, 82)
    Frame.Position = UDim2.new(1, -240, 0, 10)
    Frame.BackgroundColor3 = Color3.fromRGB(12, 12, 12)
    Frame.BackgroundTransparency = 0.25
    Frame.BorderSizePixel = 0
    Frame.Parent = Gui

    local Corner = Instance.new("UICorner")
    Corner.CornerRadius = UDim.new(0, 6)
    Corner.Parent = Frame

    local StatusLabel = Instance.new("TextLabel")
    StatusLabel.Name  = "Status"
    StatusLabel.Size  = UDim2.new(1, -10, 0, 22)
    StatusLabel.Position = UDim2.new(0, 8, 0, 4)
    StatusLabel.BackgroundTransparency = 1
    StatusLabel.TextColor3 = Color3.fromRGB(230, 230, 230)
    StatusLabel.Font = Enum.Font.GothamMedium
    StatusLabel.TextSize = 13
    StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
    StatusLabel.Text = "⚙  Raid Farm — Starting"
    StatusLabel.Parent = Frame

    local PhaseLabel = Instance.new("TextLabel")
    PhaseLabel.Name  = "Phase"
    PhaseLabel.Size  = UDim2.new(1, -10, 0, 22)
    PhaseLabel.Position = UDim2.new(0, 8, 0, 28)
    PhaseLabel.BackgroundTransparency = 1
    PhaseLabel.TextColor3 = Color3.fromRGB(180, 130, 255)
    PhaseLabel.Font = Enum.Font.GothamMedium
    PhaseLabel.TextSize = 13
    PhaseLabel.TextXAlignment = Enum.TextXAlignment.Left
    PhaseLabel.Text = ""
    PhaseLabel.Parent = Frame

    local PointsLabel = Instance.new("TextLabel")
    PointsLabel.Name  = "Points"
    PointsLabel.Size  = UDim2.new(1, -10, 0, 22)
    PointsLabel.Position = UDim2.new(0, 8, 0, 54)
    PointsLabel.BackgroundTransparency = 1
    PointsLabel.TextColor3 = Color3.fromRGB(255, 169, 108)
    PointsLabel.Font = Enum.Font.GothamMedium
    PointsLabel.TextSize = 13
    PointsLabel.TextXAlignment = Enum.TextXAlignment.Left
    PointsLabel.Text = "RP: 0"
    PointsLabel.Parent = Frame

    return {
        Status = StatusLabel,
        Phase  = PhaseLabel,
        Points = PointsLabel,
    }
end

-- ─── Main loop ────────────────────────────────────────────────────────────────

local function Main()
    HookAfkPrompt()

    local HUD = BuildHUD()

    -- Rebuild HUD on respawn (ResetOnSpawn = false keeps it alive, but just in case)
    LocalPlayer.CharacterAdded:Connect(function()
        task.wait(2)
        HookAfkPrompt()
        -- HUD persists (ResetOnSpawn = false), only rebuild if destroyed
        if not LocalPlayer.PlayerGui:FindFirstChild("RaidFarmHUD") then
            HUD = BuildHUD()
        end
    end)

    Notify("Raid Farm", "Started — scanning for raids...", 5)

    local LastScan  = -SCAN_COOLDOWN  -- force immediate first scan
    local DeathCount = 0

    while true do
        task.wait(1)

        -- Always update RP display
        HUD.Points.Text = "RP: " .. GetRaidPoints()

        -- ── Phase 1: not in a raid at all → find one ─────────────────────────
        if not IsInRaid() then
            DeathCount = 0
            local TimeUntil = math.ceil(SCAN_COOLDOWN - (tick() - LastScan))

            if TimeUntil > 0 then
                HUD.Status.Text = ("🔍  Scan in %ds"):format(TimeUntil)
                HUD.Phase.Text  = ""
            else
                HUD.Status.Text = "🔍  Scanning worlds..."
                HUD.Phase.Text  = ""
                LastScan = tick()

                local Found = ScanAllWorlds()

                if Found then
                    HUD.Status.Text = ("✈  Joining %s"):format(Found.WorldName)
                    Notify(
                        "Raid Farm",
                        ("Raid found in %s (%s) — teleporting!"):format(Found.WorldName, Found.ServerName),
                        6
                    )
                    local Ok = JoinRaidServer(Found)
                    if Ok then
                        task.wait(REJOIN_WAIT)
                    else
                        Notify("Raid Farm", "Teleport failed — retrying next scan", 4)
                    end
                    LastScan = tick()
                else
                    HUD.Status.Text = ("❌  No raid (retry in %ds)"):format(SCAN_COOLDOWN)
                    Notify("Raid Farm", "No active raid servers found — retrying in " .. SCAN_COOLDOWN .. "s", 4)
                end
            end

        -- ── Phase 2: in a raid, already in lobby → idle and farm ─────────────
        elseif IsInLobby() then
            HUD.Status.Text = "💤  Lobby — farming RP"
            HUD.Phase.Text  = ("Deaths to get here: %d"):format(DeathCount)
            -- deliberately NOT touching LastScan here — when the raid ends and
            -- we fall into Phase 1, the cooldown will have naturally elapsed
            -- (raid lasts minutes, cooldown is 30s) so we scan immediately.

        -- ── Phase 3: in a raid but NOT yet in lobby → keep resetting ─────────
        else
            DeathCount += 1
            HUD.Status.Text = "🔄  Getting to lobby..."
            HUD.Phase.Text  = ("Reset #%d — waiting for ArenaSpectator"):format(DeathCount)

            if DeathCount == 1 then
                Notify("Raid Farm", "In raid — resetting to reach lobby...", 4)
            end

            ResetCharacter()

            -- Wait for the respawn + server state update before looping again.
            -- If the server is going to flip us to ArenaSpectator it does so on
            -- (or shortly after) the death that hits the threshold.
            task.wait(RESET_WAIT)
        end
    end
end

task.spawn(Main)
