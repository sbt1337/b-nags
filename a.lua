local Game        = game
local Environment = getgenv()

local GetPropertyChangedSignal = Game.GetPropertyChangedSignal
local SFind = string.find

local NewInstance = Instance.new
local NewVector2  = Vector2.new
local NewRGB      = Color3.fromRGB
local NewUDim2    = UDim2.new
local NewUDim     = UDim.new

local HttpService       = Game:GetService("HttpService")
local ReplicatedStorage = Game:GetService("ReplicatedStorage")
local TeleportService   = Game:GetService("TeleportService")
local VirtualUser       = Game:GetService("VirtualUser")
local Players           = Game:GetService("Players")
local CoreGui           = Game:GetService("CoreGui")

local Spawn  = task.spawn
local Wait   = task.wait
local Delay  = task.delay

local Floor  = math.floor
local Ceil   = math.ceil
local Format = string.format

local Client = Players.LocalPlayer

-- Config
-- Set your webhook once in console: getgenv().RaidFarmWebhook = "https://discord.com/api/webhooks/..."
-- It persists across server hops so you never have to set it again this session.

local Config = {
    ["Webhook URL"]   = Environment.RaidFarmWebhook or "https://discord.com/api/webhooks/1512584732637008114/0MAYEUOe1lKr4PrhZoUQ4FY1MtjcztnLOtVutuSPvHDlqMfOSa7HwpkOx6Rp8RydYxQC",
    ["Scan Cooldown"] = 30,
    ["Rejoin Wait"]   = 20,
    ["Request Delay"] = 0.4,
    ["Reset Wait"]    = 6,
}

local Worlds = {
    "Hueco Mundo",
}

-- State

local Farm  = {Connections = {}}
local State = {
    LastScan      = -Config["Scan Cooldown"],
    DeathCount    = 0,
    LastWebhook   = Environment.RaidFarmLastWebhook or tick(),
    InLobby       = false,
    WasInRaid     = false,
    RaidEndedAt   = 0,
    RaidEnteredAt = 0,
    LastJobID     = nil,
    HUD           = nil,
}

-- blacklist persists across reconnects via getgenv
if not Environment.RaidFarmBlacklist then
    Environment.RaidFarmBlacklist = {}
end
local Blacklist = Environment.RaidFarmBlacklist

-- Webhook

do
    local HttpRequest = request or syn and syn.request or http_request or (HttpService and function(t)
        HttpService:RequestAsync(t)
    end) or nil

    function Farm.Webhook(Message)
        if Config["Webhook URL"] == "" or not HttpRequest then return end
        pcall(HttpRequest, {
            Url     = Config["Webhook URL"],
            Method  = "POST",
            Headers = {["Content-Type"] = "application/json"},
            Body    = HttpService:JSONEncode({username = "Raid Farm", content = Message}),
        })
    end

    function Farm.WebhookRP()
        local RP = Farm.GetRP()
        Farm.Webhook(Format("**Raid Farm** — hourly update | RP: **%d**", RP))
        State.LastWebhook = tick()
        Environment.RaidFarmLastWebhook = State.LastWebhook
    end

    function Farm.WebhookDisconnect(Reason)
        Farm.Webhook(Format("**Raid Farm** — disconnected (%s) | Last RP: **%d**", Reason, Farm.GetRP()))
    end
end

-- Helpers

do
    function Farm.Notify(Title, Msg, Duration)
        pcall(function()
            Game:GetService("StarterGui"):SetCore("SendNotification", {
                Title = Title, Text = Msg, Duration = Duration or 6,
            })
        end)
    end

    function Farm.GetRP()
        local Char = Client.Character
        if not Char then return 0 end
        return Floor(Char:GetAttribute("RaidPoints") or 0)
    end

    function Farm.InRaid()
        local Ambience = workspace:FindFirstChild("Ambience")
        return Ambience ~= nil and Ambience:GetAttribute("RaidActive") == true
    end

    function Farm.InLobby()
        if State.InLobby then return true end
        -- fallback attribute checks in case the remote fired before we hooked it
        if Client:GetAttribute("Spectating") == true then return true end
        local Char = Client.Character
        if Char and Char:GetAttribute("CurrentState") == "ArenaSpectator" then return true end
        return false
    end

    function Farm.ResetChar()
        local Char = Client.Character
        if not Char then return end
        local Humanoid = Char:FindFirstChildOfClass("Humanoid")
        if Humanoid and Humanoid.Health > 0 then
            Humanoid.Health = 0
        end
    end

    function Farm.HookAfk()
        local Requests = ReplicatedStorage:FindFirstChild("Requests")
        if not Requests then return end
        local Prompt = Requests:FindFirstChild("AfkPrompt")
        if not Prompt then return end
        Prompt.OnClientInvoke = function() return true end
    end
end

-- HUD

do
    function Farm.BuildHUD()
        local Existing = Client.PlayerGui:FindFirstChild("RaidFarmHUD")
        if Existing then Existing:Destroy() end

        local Gui = NewInstance("ScreenGui")
        Gui.Name            = "RaidFarmHUD"
        Gui.ResetOnSpawn    = false
        Gui.ZIndexBehavior  = Enum.ZIndexBehavior.Sibling
        Gui.Parent          = Client.PlayerGui

        local Frame = NewInstance("Frame")
        Frame.Size                   = NewUDim2(0, 230, 0, 82)
        Frame.Position               = NewUDim2(1, -240, 0, 10)
        Frame.BackgroundColor3       = NewRGB(12, 12, 12)
        Frame.BackgroundTransparency = 0.25
        Frame.BorderSizePixel        = 0
        Frame.Parent                 = Gui

        local Corner = NewInstance("UICorner")
        Corner.CornerRadius = NewUDim(0, 6)
        Corner.Parent       = Frame

        local function Label(Name, Y, Color)
            local L = NewInstance("TextLabel")
            L.Name                   = Name
            L.Size                   = NewUDim2(1, -10, 0, 22)
            L.Position               = NewUDim2(0, 8, 0, Y)
            L.BackgroundTransparency = 1
            L.TextColor3             = Color
            L.Font                   = Enum.Font.GothamMedium
            L.TextSize               = 13
            L.TextXAlignment         = Enum.TextXAlignment.Left
            L.Text                   = ""
            L.Parent                 = Frame
            return L
        end

        return {
            Status = Label("Status", 4,  NewRGB(230, 230, 230)),
            Phase  = Label("Phase",  28, NewRGB(180, 130, 255)),
            Points = Label("Points", 54, NewRGB(255, 169, 108)),
        }
    end
end

-- Scanner

do
    function Farm.FindRaid(WorldName)
        local Requests = ReplicatedStorage:FindFirstChild("Requests")
        if not Requests then return nil end
        local Remote = Requests:FindFirstChild("RequestServerList")
        if not Remote then return nil end

        local Ok, Response = pcall(function()
            return Remote:InvokeServer(WorldName, true)
        end)
        if not Ok or type(Response) ~= "table" then return nil end

        for _, Servers in next, Response do
            if type(Servers) ~= "table" then continue end
            for _, Data in next, Servers do
                if type(Data) ~= "table" then continue end
                if Data.Raid ~= true then continue end
                if (Data.ServerPlayers or 0) >= (Data.ServerPlayerMax or 99) then continue end
                local JobID = Data.JobID
                if Blacklist[JobID] and tick() - Blacklist[JobID] < 300 then continue end
                return {
                    WorldName  = WorldName,
                    ServerName = Data.ServerName or "Unknown",
                    JobID      = Data.JobID,
                    ReservedId = Data.ReservedId,
                }
            end
        end

        return nil
    end

    function Farm.ScanWorlds()
        for _, World in next, Worlds do
            local Found = Farm.FindRaid(World)
            if Found then return Found end
            Wait(Config["Request Delay"])
        end
        return nil
    end
end

-- Teleport

do
    function Farm.JoinServer(Info)
        local HUD = State.HUD
        local Char = Client.Character or Client.CharacterAdded:Wait()

        HUD.Phase.Text = "finding CharacterHandler..."
        local Ok, Handler = pcall(function()
            return Char:WaitForChild("CharacterHandler", 8)
        end)
        if not Ok or not Handler then
            HUD.Phase.Text = "CharacterHandler missing"
            Farm.Webhook("**JoinServer failed** — CharacterHandler missing")
            return false
        end

        HUD.Phase.Text = "finding Remotes..."
        local Ok2, Remotes = pcall(function()
            return Handler:WaitForChild("Remotes", 8)
        end)
        if not Ok2 or not Remotes then
            HUD.Phase.Text = "Remotes missing"
            Farm.Webhook("**JoinServer failed** — Remotes missing")
            return false
        end

        local Teleport = Remotes:FindFirstChild("ServerListTeleport")
        if not Teleport then
            HUD.Phase.Text = "ServerListTeleport missing"
            Farm.Webhook("**JoinServer failed** — ServerListTeleport remote missing")
            return false
        end

        HUD.Phase.Text = "firing teleport..."
        Farm.Webhook(Format("**Teleporting** → %s (job: %s)", Info.WorldName, tostring(Info.JobID)))
        State.LastJobID             = Info.JobID
        Environment.RaidFarmLastJob = Info.JobID
        Teleport:FireServer(Info.WorldName, Info.JobID, nil, Info.ReservedId)
        return true
    end
end

-- Connections

do
    -- Idled event (fires after 20min idle)
    Client.Idled:Connect(function()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(NewVector2())
        end)
    end)

    -- Periodic anti-afk loop — Delta mobile won't always fire Idled reliably
    Spawn(function()
        while true do
            Wait(60)
            pcall(function()
                VirtualUser:CaptureController()
                VirtualUser:ClickButton2(NewVector2())
            end)
        end
    end)

    Client.CharacterAdded:Connect(function()
        Wait(2)
        Farm.HookAfk()
        if not Client.PlayerGui:FindFirstChild("RaidFarmHUD") then
            State.HUD = Farm.BuildHUD()
        end
    end)

    -- Hook the spectate remote directly — server fires "allowSpectating" the moment
    -- you hit the raid lobby, and "blockSpectating" when you leave it.
    -- Much more reliable than polling attributes.
    pcall(function()
        local Control = ReplicatedStorage:WaitForChild("Remotes", 5)
            :WaitForChild("Spectating", 5)
            :WaitForChild("Control", 5)
        Control.OnClientEvent:Connect(function(Action)
            if Action == "allowSpectating" then
                State.InLobby = true
            elseif Action == "blockSpectating" then
                State.InLobby = false
            end
        end)
    end)

    -- Reconnect: watch the Roblox kick popup, same pattern as atmfarm
    Spawn(function()
        local Ok, Overlay = pcall(function()
            return CoreGui:WaitForChild("RobloxPromptGui", 30)
                         :WaitForChild("promptOverlay", 30)
        end)
        if not Ok or not Overlay then return end

        Overlay.DescendantAdded:Connect(function(Desc)
            if Desc.ClassName ~= "TextLabel" or Desc.Name ~= "ErrorMessage" then return end

            GetPropertyChangedSignal(Desc, "Text"):Connect(function()
                local Reason = Desc.Text
                if Reason == "" then return end
                if SFind(Reason, "Client initiated disconnect.", 1, true) then return end
                if SFind(Reason, "Reconnect was unsuccessful.", 1, true) then return end
                if SFind(Reason, "Same account launched experience from different device.", 1, true) then return end

                -- blacklist the last attempted job so we don't re-join a dead server
                local FailedJob = Environment.RaidFarmLastJob
                if FailedJob then
                    Blacklist[FailedJob] = tick()
                    Environment.RaidFarmLastJob = nil
                end

                Farm.WebhookDisconnect(Reason)

                local PlaceId = Game.PlaceId
                while true do
                    local Success = pcall(function()
                        TeleportService:Teleport(PlaceId, Client)
                    end)
                    if Success then break end
                    Wait(3)
                end
            end)
        end)
    end)
end

-- Main

Spawn(function()
    Farm.HookAfk()
    State.HUD = Farm.BuildHUD()
    State.HUD.Status.Text = "Raid Farm — starting"
    Farm.Notify("Raid Farm", "Started — scanning for raids", 5)

    while true do
        Wait(1)

        local HUD = State.HUD
        HUD.Points.Text = Format("RP: %d", Farm.GetRP())

        if tick() - State.LastWebhook >= 3600 then
            Farm.WebhookRP()
        end

        local NowInRaid = Farm.InRaid()

        -- detect raid-started transition (track when we first entered)
        if not State.WasInRaid and NowInRaid then
            State.RaidEnteredAt = tick()
        end

        -- detect raid-ended transition, give character time to leave ArenaSpectator
        if State.WasInRaid and not NowInRaid then
            State.RaidEndedAt = tick()
            State.InLobby     = false
            State.DeathCount  = 0
            -- blacklist this server so scanner doesn't re-join the same job
            local CurrentJob = Game.JobId
            if CurrentJob and CurrentJob ~= "" then
                Blacklist[CurrentJob] = tick()
            end
            Farm.Webhook(Format("**Raid ended** — RP so far: **%d** | waiting 8s then scanning", Farm.GetRP()))
        end
        State.WasInRaid = NowInRaid

        -- stuck-raid escape: timer at 00:00 but RaidActive never cleared
        -- bail after 12 minutes in-raid (well past any real raid timer)
        local StuckRaid = NowInRaid and State.RaidEnteredAt > 0 and (tick() - State.RaidEnteredAt) > 720
        if StuckRaid then
            HUD.Status.Text = "Stuck raid — leaving"
            HUD.Phase.Text  = "blacklisting & scanning"
            local CurrentJob = Game.JobId
            if CurrentJob and CurrentJob ~= "" then
                Blacklist[CurrentJob] = tick()
            end
            State.RaidEnteredAt = 0
            Farm.Webhook(Format("**Stuck raid detected** (>12min) — bailing | RP: **%d**", Farm.GetRP()))

            -- try to jump straight into a new raid; fall back to fresh reconnect
            local Escape = Farm.ScanWorlds()
            if Escape then
                HUD.Status.Text = Format("Escaping to %s", Escape.WorldName)
                Farm.JoinServer(Escape)
            else
                -- no live raid found, just teleport out of this dead server
                local PlaceId = Game.PlaceId
                pcall(function() TeleportService:Teleport(PlaceId, Client) end)
            end
            Wait(Config["Rejoin Wait"])
        elseif not NowInRaid then
            State.DeathCount = 0

            local PostRaidWait = 8 - (tick() - State.RaidEndedAt)
            if PostRaidWait > 0 then
                HUD.Status.Text = Format("Raid ended — waiting %ds", Ceil(PostRaidWait))
                HUD.Phase.Text  = "letting character reset..."
            else
                local TimeLeft = Ceil(Config["Scan Cooldown"] - (tick() - State.LastScan))

                if TimeLeft > 0 then
                    HUD.Status.Text = Format("Scan in %ds", TimeLeft)
                    HUD.Phase.Text  = ""
                else
                    HUD.Status.Text = "Scanning worlds..."
                    HUD.Phase.Text  = ""
                    State.LastScan  = tick()

                    local Found = Farm.ScanWorlds()

                    if Found then
                        HUD.Status.Text = Format("Joining %s", Found.WorldName)
                        Farm.Notify("Raid Farm", Format("Raid found in %s — teleporting", Found.WorldName), 6)

                        State.InLobby = false
                        if not Farm.JoinServer(Found) then
                            Farm.Notify("Raid Farm", "Teleport failed — retrying", 4)
                        end

                        Wait(Config["Rejoin Wait"])
                        State.LastScan = Farm.InRaid() and tick() or -Config["Scan Cooldown"]
                    else
                        HUD.Status.Text = Format("No raid (retry in %ds)", Config["Scan Cooldown"])
                    end
                end
            end

        elseif Farm.InLobby() then
            HUD.Status.Text = "Lobby — farming RP"
            HUD.Phase.Text  = Format("Deaths: %d", State.DeathCount)

        else
            State.DeathCount += 1
            HUD.Status.Text = "Getting to lobby..."
            HUD.Phase.Text  = Format("Reset #%d", State.DeathCount)

            if State.DeathCount == 1 then
                Farm.Notify("Raid Farm", "In raid — resetting to lobby", 4)
            end

            Farm.ResetChar()
            Wait(Config["Reset Wait"])
        end
    end
end)
