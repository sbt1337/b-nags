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
local TweenService      = Game:GetService("TweenService")
local Debris            = Game:GetService("Debris")
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
    ["Reset Wait"]    = 2,   -- post-respawn buffer; the real wait is inside Farm.ResetChar()
    -- Code Redeemer — fill in via getgenv() so they survive server hops:
    --   getgenv().RaidFarmDiscordToken = "YOUR_TOKEN"   (self-bot: raw token from browser devtools)
    --   getgenv().RaidFarmCodesChannel = "CHANNEL_ID"   (right-click channel → Copy Channel ID)
    -- Leave as "" to keep the feature disabled.
    ["Discord Token"]      = Environment.RaidFarmDiscordToken or "",
    ["Codes Channel ID"]   = Environment.RaidFarmCodesChannel or "",
    ["Code Poll Interval"] = 90,
}

local Worlds = {
    "Hueco Mundo",
}

-- State

local Farm  = {Connections = {}}
local State = {
    -- start 30s behind so the first scan has a full cooldown on fresh injection/reconnect
    LastScan      = tick() - Config["Scan Cooldown"] + 30,
    DeathCount    = 0,
    LastWebhook   = Environment.RaidFarmLastWebhook or tick(),
    InLobby       = false,
    WasInRaid     = false,
    RaidEndedAt   = 0,
    TimerZeroAt   = 0,   -- when KillDaCaptain.TimeLeft first hit 0
    LastJobID     = nil,
    HUD           = nil,
}

-- blacklist: lives in getgenv across server-side hops, AND in a local file so it
-- survives TeleportService:Teleport() reconnects (which wipe getgenv on Delta mobile).
-- ghost servers like ones stuck in the TS server list for hours stay blacklisted.
if not Environment.RaidFarmBlacklist then
    Environment.RaidFarmBlacklist = (function()
        if not readfile then return {} end
        local Ok, Data = pcall(readfile, "raid_farm_blacklist.json")
        if not Ok or not Data or Data == "" then return {} end
        local Ok2, T = pcall(HttpService.JSONDecode, HttpService, Data)
        if not Ok2 or type(T) ~= "table" then return {} end
        -- prune entries older than 24h so the file doesn't grow forever
        local Now = tick()
        for JobID, Ts in next, T do
            if Now - Ts > 86400 then T[JobID] = nil end
        end
        return T
    end)()
end
local Blacklist = Environment.RaidFarmBlacklist

-- item drop tracker persists across reconnects
if not Environment.RaidFarmItems then
    Environment.RaidFarmItems = {}
end
local ItemTotals = Environment.RaidFarmItems

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
        local RP  = Farm.GetRP()
        local Kan = Farm.GetKan()
        Farm.Webhook(Format(
            "**Raid Farm** — hourly update | RP: **%d** | Kan: **%d**\nItems this session: %s",
            RP, Kan, Farm.ItemSummary()
        ))
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

    function Farm.GetKan()
        local Char = Client.Character
        if not Char then return 0 end
        return Floor(Char:GetAttribute("Kan") or 0)
    end

    function Farm.ItemSummary()
        local Parts = {}
        for Name, Count in next, ItemTotals do
            Parts[#Parts + 1] = Format("**%s** ×%d", Name, Count)
        end
        return #Parts > 0 and table.concat(Parts, " | ") or "none"
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

    -- race → soul color, mirrors the per-race particle color in Soul.lua
    local SoulColors = {
        ["Shinigami"]  = NewRGB(180, 220, 255),
        ["Visored"]    = NewRGB(180, 220, 255),
        ["Quincy"]     = NewRGB(100, 160, 255),
        ["Arrancar"]   = NewRGB(210, 160, 255),
        ["Vastocar"]   = NewRGB(210, 160, 255),
        ["Fullbringer"] = NewRGB(255, 200, 100),
    }

    function Farm.DeathEffect()
        local Char = Client.Character
        if not Char then return end
        local Root = Char:FindFirstChild("HumanoidRootPart")
        if not Root then return end

        local Color = SoulColors[Char:GetAttribute("EntityType") or ""] or NewRGB(180, 220, 255)

        -- Highlight pulse on the character (matches Soul.lua's Highlight flash)
        local Hl = NewInstance("Highlight")
        Hl.FillColor           = Color
        Hl.OutlineColor        = Color
        Hl.FillTransparency    = 1
        Hl.OutlineTransparency = 1
        Hl.DepthMode           = Enum.HighlightDepthMode.Occluded
        Hl.Parent              = Char
        TweenService:Create(Hl, TweenInfo.new(0.35), {
            FillTransparency    = 0.25,
            OutlineTransparency = 0.25,
        }):Play()
        Debris:AddItem(Hl, 1.2)

        -- expanding neon sphere (approximates soulOutOfBody's script.Force part)
        local Sphere = NewInstance("Part")
        Sphere.Shape        = Enum.PartType.Ball
        Sphere.Material     = Enum.Material.Neon
        Sphere.Color        = Color
        Sphere.Size         = Vector3.new(1, 1, 1)
        Sphere.Anchored     = true
        Sphere.CanCollide   = false
        Sphere.Transparency = 0.25
        Sphere.CFrame       = Root.CFrame
        Sphere.Parent       = workspace
        TweenService:Create(Sphere, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
            Size        = Vector3.new(18, 18, 18),
            Transparency = 1,
        }):Play()
        Debris:AddItem(Sphere, 1)

        Wait(0.4)  -- let the flash peak before health drops
    end

    function Farm.ResetChar()
        local Char = Client.Character
        if not Char then return end
        local Humanoid = Char:FindFirstChildOfClass("Humanoid")
        if not Humanoid or Humanoid.Health <= 0 then return end

        Farm.DeathEffect()
        Humanoid.Health = 0

        -- ClientProgression.lua (line 1968) sets PlayerGui.FactionsUI.RespawnTimer.Visible
        -- to true when the server countdown starts, and back to false when it hits 0
        -- (right before the character actually spawns). Watch that instead of guessing.
        local FactionsUI = Client.PlayerGui:FindFirstChild("FactionsUI")
        local Timer      = FactionsUI and FactionsUI:FindFirstChild("RespawnTimer")

        if Timer then
            -- wait up to 6s for the countdown label to appear after death processing
            local T = tick() + 6
            while not Timer.Visible and tick() < T do
                Wait(0.2)
            end
            -- wait for it to disappear — that's the server telling us respawn is now
            T = tick() + 30
            while Timer.Visible and tick() < T do
                Wait(0.2)
            end
        else
            -- FactionsUI not found; fall back to CharacterAdded
            local Done = false
            local Conn = Client.CharacterAdded:Connect(function() Done = true end)
            local T    = tick() + 20
            while not Done and tick() < T do Wait(0.5) end
            Conn:Disconnect()
        end

        -- brief buffer for CharacterHandler and remotes to finish loading
        Wait(1.5)
    end

    function Farm.Blacklist(JobID)
        if not JobID or JobID == "" then return end
        Blacklist[JobID] = tick()
        -- persist to file so the entry survives getgenv wipes on reconnect
        if writefile then
            pcall(writefile, "raid_farm_blacklist.json", HttpService:JSONEncode(Blacklist))
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
        Frame.Size                   = NewUDim2(0, 230, 0, 128)
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
            Status = Label("Status", 4,   NewRGB(230, 230, 230)),
            Phase  = Label("Phase",  28,  NewRGB(180, 130, 255)),
            Points = Label("Points", 52,  NewRGB(255, 169, 108)),
            Kan    = Label("Kan",    76,  NewRGB(100, 200, 255)),
            Items  = Label("Items",  100, NewRGB(120, 220, 120)),
        }
    end
end

-- Scanner

do
    local HttpReq = request or (syn and syn.request) or http_request or nil

    -- Set of JobIDs Roblox's own registry confirms are alive right now.
    -- RequestServerList returns stale data — servers stay listed as Raid==true
    -- for minutes after they actually shut down. Cross-referencing against
    -- games.roblox.com eliminates those ghosts before we even try to join.
    local LiveServers   = {}
    local LastSync      = 0
    local SyncInterval  = 45  -- refresh every 45s

    local function SyncLiveServers()
        if tick() - LastSync < SyncInterval then return end
        LastSync = tick()
        if not HttpReq then return end

        local PlaceId = tostring(Game.PlaceId)
        local Fresh   = {}
        local Cursor  = ""

        for _ = 1, 8 do   -- cap at 8 pages / 800 servers
            local Url = "https://games.roblox.com/v1/games/" .. PlaceId
                .. "/servers/Public?sortOrder=Asc&excludeFullGames=false&limit=100"
            if Cursor ~= "" then Url = Url .. "&cursor=" .. Cursor end

            local Ok, Result = pcall(HttpReq, {Url = Url, Method = "GET"})
            if not Ok or not Result or not Result.Success then break end

            local Ok2, Data = pcall(HttpService.JSONDecode, HttpService, Result.Body)
            if not Ok2 or type(Data) ~= "table" or type(Data.data) ~= "table" then break end

            for _, Srv in ipairs(Data.data) do
                if type(Srv.id) == "string" and Srv.id ~= "" then
                    Fresh[Srv.id] = true
                end
            end

            Cursor = type(Data.nextPageCursor) == "string" and Data.nextPageCursor or ""
            if Cursor == "" then break end
            Wait(0.15)
        end

        -- only replace if we got actual data; a failed fetch keeps the last known set
        if next(Fresh) then
            LiveServers = Fresh
        end
    end

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

                local JobID    = Data.JobID
                local Reserved = Data.ReservedId ~= nil and Data.ReservedId ~= ""

                if Blacklist[JobID] and tick() - Blacklist[JobID] < 300 then continue end

                -- validate against Roblox's live registry; public servers not in the list
                -- are dead ghosts — blacklist them now so we never try again.
                -- reserved-server instances don't appear in the public list, skip the check.
                if not Reserved and next(LiveServers) ~= nil then
                    if not LiveServers[JobID] then
                        Farm.Blacklist(JobID)
                        continue
                    end
                end

                return {
                    WorldName  = WorldName,
                    ServerName = Data.ServerName or "Unknown",
                    JobID      = JobID,
                    ReservedId = Data.ReservedId,
                }
            end
        end

        return nil
    end

    function Farm.ScanWorlds()
        SyncLiveServers()   -- refresh live-server set before each scan pass
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

        -- server silently rejects ServerListTeleport if the character is dead —
        -- wait until health > 0 before attempting anything
        local Hum = Char:FindFirstChildOfClass("Humanoid")
        if Hum and Hum.Health <= 0 then
            HUD.Phase.Text = "waiting to respawn..."
            local Deadline = tick() + 20
            while tick() < Deadline do
                Char = Client.Character or Char
                Hum  = Char:FindFirstChildOfClass("Humanoid") or Hum
                if Hum.Health > 0 then break end
                Wait(0.5)
            end
        end

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

    -- Hook ClientEffects to intercept ItemObtained — catches every raid drop
    -- regardless of what the item is named, no hard-coded item list needed
    pcall(function()
        local EffectsRemote = ReplicatedStorage:WaitForChild("Remotes", 5)
            :WaitForChild("ClientEffects", 5)
        EffectsRemote.OnClientEvent:Connect(function(_, PathData, _, ItemName, Count)
            if type(PathData) ~= "table" then return end
            if PathData.Skill ~= "ItemObtained" then return end
            if type(ItemName) ~= "string" or ItemName == "" then return end
            local Qty = (type(Count) == "number" and Count > 1) and Count or 1
            ItemTotals[ItemName] = (ItemTotals[ItemName] or 0) + Qty
        end)
    end)

    -- Watch KillDaCaptain.TimeLeft — stamp when it first hits 0 so we can
    -- detect a stuck raid (timer frozen at 00:00 but RaidActive never clears)
    Spawn(function()
        local function HookTimeLeft(Container)
            local TimeLeft = Container:FindFirstChild("TimeLeft")
            if not TimeLeft then return end

            -- seed immediately from current value — critical for joining a server
            -- where the timer is ALREADY at 0; Changed never fires in that case
            -- so without this check TimerZeroAt stays 0 and StuckRaid never triggers
            if (TimeLeft.Value or 0) <= 0 and State.TimerZeroAt == 0 then
                State.TimerZeroAt = tick()
            end

            TimeLeft.Changed:Connect(function(Val)
                if Val <= 0 and State.TimerZeroAt == 0 then
                    State.TimerZeroAt = tick()
                elseif Val > 0 then
                    State.TimerZeroAt = 0
                end
            end)
        end

        -- might already exist
        local Existing = ReplicatedStorage:FindFirstChild("KillDaCaptain")
        if Existing then HookTimeLeft(Existing) end

        ReplicatedStorage.ChildAdded:Connect(function(Child)
            if Child.Name == "KillDaCaptain" then
                State.TimerZeroAt = 0
                HookTimeLeft(Child)
            end
        end)
        ReplicatedStorage.ChildRemoved:Connect(function(Child)
            if Child.Name == "KillDaCaptain" then
                State.TimerZeroAt = 0
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
                    Farm.Blacklist(FailedJob)
                    Environment.RaidFarmLastJob = nil
                end

                Farm.WebhookDisconnect(Reason)

                -- Wait before reconnecting: on Delta mobile, TeleportService:Teleport()
                -- wipes getgenv() so the blacklist is gone on the next run. A delay here
                -- + the 30s startup scan delay = ~90s gap, enough for most dead servers
                -- to fall off the TS server list before the script scans again.
                Wait(60)

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

-- Code Redeemer

do
    local HttpReq = request or (syn and syn.request) or http_request or nil

    -- redeemed-code set and last-seen message ID both live in getgenv so they
    -- persist across server-side teleports. they get wiped on TeleportService:Teleport()
    -- reconnects, but that's fine — the server rejects already-redeemed codes.
    if not Environment.RaidFarmLastCodeMsgID then
        Environment.RaidFarmLastCodeMsgID = nil
    end
    if not Environment.RaidFarmRedeemedCodes then
        Environment.RaidFarmRedeemedCodes = {}
    end

    local function FetchMessages()
        local Token     = Config["Discord Token"]
        local ChannelID = Config["Codes Channel ID"]
        if Token == "" or ChannelID == "" or not HttpReq then return nil end

        -- &after= cursor means we only get messages newer than the last one we saw
        local Url = "https://discord.com/api/v10/channels/" .. ChannelID .. "/messages?limit=10"
        if Environment.RaidFarmLastCodeMsgID then
            Url = Url .. "&after=" .. Environment.RaidFarmLastCodeMsgID
        end

        local Ok, Result = pcall(HttpReq, {
            Url     = Url,
            Method  = "GET",
            Headers = {
                ["Authorization"] = Token,
                ["User-Agent"]    = "Mozilla/5.0",
            },
        })
        if not Ok or not Result or not Result.Success then return nil end

        local Ok2, Data = pcall(HttpService.JSONDecode, HttpService, Result.Body)
        if not Ok2 or type(Data) ~= "table" then return nil end
        return Data
    end

    -- words that appear in announcements but are definitely not codes
    local StopWords = {
        THE=true, AND=true, FOR=true, WITH=true, THIS=true, FROM=true,
        HAVE=true, BEEN=true, WILL=true, THAT=true, THEY=true, YOUR=true,
        RAID=true, FARM=true, TYPE=true, SOUL=true, GAME=true, CODE=true,
        FREE=true, DROP=true, LIKE=true, MORE=true, INTO=true, ONLY=true,
        DISCORD=true, SERVER=true, ROBLOX=true, CODES=true, USING=true,
        REWARD=true, BONUS=true, CLAIM=true, ENTER=true, LIMITED=true,
        TIME=true, MAKE=true, SURE=true, HERE=true, DONT=true, JUST=true,
    }

    local function ExtractCodes(Content)
        local Upper = Content:upper()
        local Found = {}
        local Seen  = {}

        -- first pass: anything right after "code" / "codes" keyword — catches "code: RICHKID"
        for Code in Upper:gmatch("CODES?%s*[:%!%=]%s*([A-Z0-9][A-Z0-9%-_]*)") do
            if #Code >= 4 and #Code <= 25 and not Seen[Code] then
                Found[#Found + 1] = Code
                Seen[Code] = true
            end
        end

        -- second pass: long standalone uppercase tokens not in the stopword list
        -- 7-char min to avoid catching normal words; covers RICHKID (7), BETARELEASE (11), etc.
        for Code in Upper:gmatch("[A-Z][A-Z0-9%-_]+[A-Z0-9]") do
            if #Code >= 7 and #Code <= 25 and not StopWords[Code] and not Seen[Code] then
                Found[#Found + 1] = Code
                Seen[Code] = true
            end
        end

        return Found
    end

    local function RedeemCode(Code)
        local Char = Client.Character
        if not Char then return false, "no character" end
        local Handler = Char:FindFirstChild("CharacterHandler")
        if not Handler then return false, "no CharacterHandler" end
        local Remotes = Handler:FindFirstChild("Remotes")
        if not Remotes then return false, "no Remotes" end
        local CodesRemote = Remotes:FindFirstChild("Codes")
        if not CodesRemote then return false, "Codes remote not found" end
        local Ok, Success, Msg = pcall(function()
            return CodesRemote:InvokeServer(Code)
        end)
        if not Ok then return false, "invoke failed" end
        return Success, Msg or (Success and "Redeemed!" or "Already used or invalid")
    end

    local LastPoll = 0

    Spawn(function()
        while true do
            Wait(5)
            if tick() - LastPoll < Config["Code Poll Interval"] then continue end
            LastPoll = tick()

            local Messages = FetchMessages()
            if not Messages or #Messages == 0 then continue end

            -- Discord returns newest-first on initial fetch, ascending with &after=.
            -- Either way, walk all messages and track the highest snowflake ID.
            local NewestID = Environment.RaidFarmLastCodeMsgID
            for _, Msg in ipairs(Messages) do
                local MsgID = tostring(Msg.id or "")
                if MsgID ~= "" then
                    if not NewestID or tonumber(MsgID) > tonumber(NewestID) then
                        NewestID = MsgID
                    end
                end
            end

            for _, Msg in ipairs(Messages) do
                local Codes = ExtractCodes(tostring(Msg.content or ""))
                for _, Code in ipairs(Codes) do
                    if Environment.RaidFarmRedeemedCodes[Code] then continue end
                    Environment.RaidFarmRedeemedCodes[Code] = true

                    Wait(1)
                    local Success, Result = RedeemCode(Code)
                    Farm.Notify("Code Redeemer", Format("%s — %s", Code, Result), 8)

                    if HttpReq then
                        pcall(HttpReq, {
                            Url     = Config["Webhook URL"],
                            Method  = "POST",
                            Headers = {["Content-Type"] = "application/json"},
                            Body    = HttpService:JSONEncode({
                                username = "Code Redeemer",
                                embeds   = {{
                                    title       = Success and "Code Redeemed ✓" or "Code Failed ✗",
                                    description = Format("**`%s`**\n%s", Code, Result),
                                    color       = Success and 3066993 or 15158332,
                                }},
                            }),
                        })
                    end
                end
            end

            if NewestID then
                Environment.RaidFarmLastCodeMsgID = NewestID
            end
        end
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
        HUD.Points.Text = Format("RP: %d",  Farm.GetRP())
        HUD.Kan.Text    = Format("Kan: %d", Farm.GetKan())
        HUD.Items.Text  = Farm.ItemSummary()

        if tick() - State.LastWebhook >= 3600 then
            Farm.WebhookRP()
        end

        local NowInRaid = Farm.InRaid()

        -- detect raid-ended transition, give character time to leave ArenaSpectator
        if State.WasInRaid and not NowInRaid then
            State.RaidEndedAt = tick()
            State.InLobby     = false
            State.DeathCount  = 0
            -- blacklist this server so scanner doesn't re-join the same job
            Farm.Blacklist(Game.JobId)
            Farm.Webhook(Format("**Raid ended** — RP so far: **%d** | waiting 8s then scanning", Farm.GetRP()))
        end
        State.WasInRaid = NowInRaid

        -- stuck-raid escape: KillDaCaptain.TimeLeft hit 0 but RaidActive never cleared
        -- if the timer has been at 00:00 for >60s we're in a frozen server
        local StuckRaid = NowInRaid and State.TimerZeroAt > 0 and (tick() - State.TimerZeroAt) > 60
        if StuckRaid then
            HUD.Status.Text = "Stuck raid — leaving"
            HUD.Phase.Text  = "timer frozen >60s"
            Farm.Blacklist(Game.JobId)
            State.TimerZeroAt = 0
            Farm.Webhook(Format("**Stuck raid** (timer frozen >60s) — bailing | RP: **%d**", Farm.GetRP()))

            -- try to jump straight into a new raid; fall back to fresh reconnect
            local Escape = Farm.ScanWorlds()
            if Escape then
                HUD.Status.Text = Format("Escaping to %s", Escape.WorldName)
                if Farm.JoinServer(Escape) then
                    Farm.Blacklist(Escape.JobID)
                end
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
                        if Farm.JoinServer(Found) then
                            -- blacklist immediately so the scanner doesn't re-find this
                            -- server while the server-side teleport is still in flight
                            Farm.Blacklist(Found.JobID)
                        else
                            Farm.Notify("Raid Farm", "Teleport failed — retrying", 4)
                        end

                        Wait(Config["Rejoin Wait"])
                        -- always enforce the full cooldown after a join attempt;
                        -- the old "or -ScanCooldown" path caused a second teleport to fire
                        -- before the first one landed (double-teleport into dead servers)
                        State.LastScan = tick()
                    else
                        HUD.Status.Text = Format("No raid (retry in %ds)", Config["Scan Cooldown"])
                    end
                end
            end

        elseif Farm.InLobby() then
            State.DeathCount = 0   -- made it in; clear so next raid entry starts from 1
            HUD.Status.Text = "Lobby — farming RP"
            HUD.Phase.Text  = ""

            -- backup: if we somehow missed the initial-value seed (e.g. KillDaCaptain
            -- spawned before the hook was registered), catch it here every tick
            if NowInRaid and State.TimerZeroAt == 0 then
                local Kdc = ReplicatedStorage:FindFirstChild("KillDaCaptain")
                local Tl  = Kdc and Kdc:FindFirstChild("TimeLeft")
                if Tl and (Tl.Value or 0) <= 0 then
                    State.TimerZeroAt = tick()
                end
            end

        else
            State.DeathCount += 1

            -- 5 resets and still not spectating = bugged lobby, get out
            if State.DeathCount > 5 then
                -- hold at 5 so if the teleport stalls and we're somehow still here,
                -- the next tick bails again immediately instead of resetting to #1/5
                State.DeathCount = 5
                HUD.Status.Text = "Bugged lobby — escaping"
                HUD.Phase.Text  = ""
                Farm.Blacklist(Game.JobId)
                Farm.Webhook(Format(
                    "**Bugged lobby** (5 resets, never reached ArenaSpectator) — teleporting out | RP: **%d**",
                    Farm.GetRP()
                ))
                Farm.Notify("Raid Farm", "Bugged lobby after 5 resets — escaping", 6)

                -- ServerListTeleport is blocked server-side when inside an active raid;
                -- use TeleportService directly — it's engine-level and can't be rejected
                local PlaceId = Game.PlaceId
                while true do
                    local Ok = pcall(function() TeleportService:Teleport(PlaceId, Client) end)
                    if Ok then break end
                    Wait(3)
                end
                Wait(Config["Rejoin Wait"])
            else
                HUD.Status.Text = "Getting to lobby..."
                HUD.Phase.Text  = Format("Reset #%d / 5", State.DeathCount)

                if State.DeathCount == 1 then
                    Farm.Notify("Raid Farm", "In raid — resetting to lobby", 4)
                end

                Farm.ResetChar()
                Wait(Config["Reset Wait"])
            end
        end
    end
end)
