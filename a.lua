local Game = game

local NewInstance = Instance.new
local NewVector2  = Vector2.new
local NewRGB      = Color3.fromRGB
local NewUDim2    = UDim2.new
local NewUDim     = UDim.new

local HttpService       = Game:GetService("HttpService")
local ReplicatedStorage = Game:GetService("ReplicatedStorage")
local VirtualUser       = Game:GetService("VirtualUser")
local Players           = Game:GetService("Players")

local Spawn  = task.spawn
local Wait   = task.wait
local Delay  = task.delay

local Floor  = math.floor
local Ceil   = math.ceil
local Format = string.format

local Client = Players.LocalPlayer

-- Config

local Config = {
    ["Webhook URL"]   = "",   -- paste Discord webhook URL here
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
    LastScan    = -Config["Scan Cooldown"],
    DeathCount  = 0,
    LastWebhook = tick(),
    HUD         = nil,
}

-- Webhook

do
    function Farm.Webhook(Message)
        if Config["Webhook URL"] == "" then return end
        pcall(function()
            request({
                Url     = Config["Webhook URL"],
                Method  = "POST",
                Headers = {["Content-Type"] = "application/json"},
                Body    = HttpService:JSONEncode({username = "Raid Farm", content = Message}),
            })
        end)
    end

    function Farm.WebhookRP()
        local RP = Farm.GetRP()
        Farm.Webhook(Format("**Raid Farm** — hourly update | RP: **%d**", RP))
        State.LastWebhook = tick()
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
        local Char = Client.Character or Client.CharacterAdded:Wait()

        local Ok, Handler = pcall(function()
            return Char:WaitForChild("CharacterHandler", 5)
        end)
        if not Ok or not Handler then return false end

        local Ok2, Remotes = pcall(function()
            return Handler:WaitForChild("Remotes", 5)
        end)
        if not Ok2 or not Remotes then return false end

        local Teleport = Remotes:FindFirstChild("ServerListTeleport")
        if not Teleport then return false end

        Teleport:FireServer(Info.WorldName, Info.JobID, nil, Info.ReservedId)
        return true
    end
end

-- Connections

do
    Client.Idled:Connect(function()
        pcall(function()
            VirtualUser:CaptureController()
            VirtualUser:ClickButton2(NewVector2())
        end)
    end)

    Client.CharacterAdded:Connect(function()
        Wait(2)
        Farm.HookAfk()
        if not Client.PlayerGui:FindFirstChild("RaidFarmHUD") then
            State.HUD = Farm.BuildHUD()
        end
    end)

    Client.AncestryChanged:Connect(function()
        if not Client.Parent then
            Farm.WebhookDisconnect("kicked / removed from server")
        end
    end)

    Game.Close:Connect(function()
        Farm.WebhookDisconnect("game closed")
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

        if not Farm.InRaid() then
            State.DeathCount = 0
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

                    if not Farm.JoinServer(Found) then
                        Farm.Notify("Raid Farm", "Teleport failed — retrying", 4)
                    end

                    Wait(Config["Rejoin Wait"])
                    State.LastScan = tick()
                else
                    HUD.Status.Text = Format("No raid (retry in %ds)", Config["Scan Cooldown"])
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
