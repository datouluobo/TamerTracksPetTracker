local addonName, ns = ...
TamerTracksPetTracker = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceEvent-3.0", "AceTimer-3.0", "AceConsole-3.0", "AceComm-3.0")

local AceSerializer = LibStub("AceSerializer-3.0")
local LibDeflate = LibStub("LibDeflate")

local defaults = {
    global = {
        trackerEnabled = true,
        selectedPet = 50813,
        routes = {},
        settings = { alertSound = true, alertVisual = true, minDistance = 0.005, breakDistance = 0.05 }
    }
}

function TamerTracksPetTracker:OnInitialize()
    self.db = LibStub("AceDB-3.0"):New("TamerTracksPetTrackerDB", defaults, true)
    self:RegisterChatCommand("tr", "SlashHandler")
    self:RegisterChatCommand("tra", "RecordCurrentPoint")
    
    -- 注册 P2P 通信信道，突破聊天 255 字节限制
    self:RegisterComm("TT_REQ", "OnCommReceive")
    self:RegisterComm("TT_DATA", "OnCommReceive")
    
    -- 注册本地渲染过滤器，解决链接无法发送被剥离的问题
    ChatFrame_AddMessageEventFilter("CHAT_MSG_CHANNEL", self.ChatLinkFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_SAY", self.ChatLinkFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_YELL", self.ChatLinkFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_GUILD", self.ChatLinkFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_OFFICER", self.ChatLinkFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_PARTY", self.ChatLinkFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_PARTY_LEADER", self.ChatLinkFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_RAID", self.ChatLinkFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_RAID_LEADER", self.ChatLinkFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_WHISPER", self.ChatLinkFilter)
    ChatFrame_AddMessageEventFilter("CHAT_MSG_BN_WHISPER", self.ChatLinkFilter)
    
    self:HookChatLinks()
end

function TamerTracksPetTracker.ChatLinkFilter(self, event, msg, ...)
    -- 识别特定的明文标记 {TT:PetID:SenderName} 并替换为可点击链接
    local pattern = "{TT:(%d+):([^}]+)}"
    if msg:find(pattern) then
        local petID, senderName = msg:match(pattern)
        local petName = ns.pets[tonumber(petID)] and ns.pets[tonumber(petID)].name or "未知"
        local replacement = string.format("|cff00ecff|HTamerTracksPetTracker:%s:%s|h[TamerTracksPetTracker分享: %s]|h|r", petID, senderName, petName)
        msg = msg:gsub(pattern, replacement)
        return false, msg, ...
    end
end

function TamerTracksPetTracker:OnCommReceive(prefix, message, distribution, sender)
    -- 处理跨服场景下的玩家名统一格式
    local localPlayer = UnitName("player")
    local localRealm = GetRealmName():gsub("%s+", "")
    local shortSender = strsplit("-", sender)
    if sender == localPlayer or shortSender == localPlayer or sender == string.format("%s-%s", localPlayer, localRealm) then return end
    
    if prefix == "TT_REQ" then
        -- 接收方索要数据
        local petID = tonumber(message)
        if petID and self.db.global.routes[petID] then
            local encoded = self:ExportToShareString(petID)
            -- AceComm 能够自动为超长文本 (如上千字的路线) 实行静默切割封包并在对端重组
            self:SendCommMessage("TT_DATA", petID .. ":" .. encoded, "WHISPER", sender)
        end
    elseif prefix == "TT_DATA" then
        -- 请求方收到完整封包流
        local petIDStr, encoded = strsplit(":", message, 2)
        local petID = tonumber(petIDStr)
        if petID and encoded then
            if self.ShowImportConfirmPopup then
                self:ShowImportConfirmPopup(petID, encoded)
            end
        end
    end
end

function TamerTracksPetTracker:OnEnable()
    self:ScheduleRepeatingTimer("CheckTooltip", 0.1)
end

local lastAlertTime = 0
function TamerTracksPetTracker:CheckTooltip()
    if not self.db.global.trackerEnabled then return end
    if GameTooltip:IsVisible() then
        local text = GameTooltipTextLeft1 and GameTooltipTextLeft1:GetText()
        if text and (text:find("踪迹") or text:find("脚印") or text:find("迹象") or text:find("Tracks") or text:find("Prints")) then
            local now = GetTime()
            if now - lastAlertTime > 3 then
                lastAlertTime = now
                self:TriggerAlert(text)
            end
        end
    end
end

function TamerTracksPetTracker:TriggerAlert(targetName)
    if self.db.global.settings.alertSound then PlaySound(8959, "Master") end
    if self.db.global.settings.alertVisual then
        RaidNotice_AddMessage(RaidWarningFrame, "|cffff0000[发现足迹]|r: " .. (targetName or "未知踪迹"), ChatTypeInfo["RAID_WARNING"])
    end
end

function TamerTracksPetTracker:SlashHandler(input)
    if not input or input == "" then
        if self.HUDFrame then
            if self.HUDFrame:IsVisible() then self.HUDFrame:Hide() else self.HUDFrame:Show() end
        else
            self:CreateHUD()
        end
    end
end

function TamerTracksPetTracker:RecordCurrentPoint()
    local mapID = C_Map and C_Map.GetBestMapForUnit("player")
    if not mapID then return end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos or pos.x == 0 then return end
    
    local petID = self.db.global.selectedPet
    if not self.db.global.routes[petID] then self.db.global.routes[petID] = {} end
    
    table.insert(self.db.global.routes[petID], {x = pos.x, y = pos.y, m = mapID})
    
    print(string.format("|cff00ccff[TamerTracksPetTracker]|r: 已记录坐标 (%.2f, %.2f)", pos.x*100, pos.y*100))
    
    -- 实时更新列表和地图
    if self.HUDFrame and self.HUDFrame:IsVisible() then 
        if self.UpdateCoordList then self:UpdateCoordList() end
    end
    
    if self.RefreshMapLayer then 
        self:RefreshMapLayer() 
    end
end

-- ==========================================
-- 序列化与分享引擎 (第一维度: LibDeflate 方案)
-- ==========================================

function TamerTracksPetTracker:ExportToShareString(petID)
    local data = self.db.global.routes[petID] or {}
    -- 特别精简一下表结构减小体积
    local cleanData = {}
    for i, p in ipairs(data) do
        table.insert(cleanData, {p.m, tonumber(string.format("%.4f", p.x)), tonumber(string.format("%.4f", p.y))})
    end
    
    local serialized = AceSerializer:Serialize(cleanData)
    local compressed = LibDeflate:CompressDeflate(serialized)
    local encoded = LibDeflate:EncodeForPrint(compressed)
    
    return encoded
end

function TamerTracksPetTracker:DecodeShareString(encoded)
    local compressed = LibDeflate:DecodeForPrint(encoded)
    if not compressed then return false, "Base64 解码失败" end
    
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return false, "解压失败，压缩流已损坏" end
    
    local success, data = AceSerializer:Deserialize(serialized)
    if not success or type(data) ~= "table" then return false, "核心数据反序列化失败" end
    
    -- 还原表结构
    local restoredData = {}
    for i, p in ipairs(data) do
        table.insert(restoredData, {m = p[1], x = p[2], y = p[3]})
    end
    
    return true, restoredData
end

function TamerTracksPetTracker:MergeData(petID, newData, overwrite)
    local existing = self.db.global.routes[petID] or {}
    if overwrite then
        existing = {}
    end
    
    local insertedCount = 0
    for _, np in ipairs(newData) do
        local isDuplicate = false
        -- 第二维度: 策略三 空间降噪合并
        for _, ep in ipairs(existing) do
            if ep.m == np.m then
                local dx = math.abs(ep.x - np.x)
                local dy = math.abs(ep.y - np.y)
                local dist = math.sqrt(dx*dx + dy*dy)
                if dist < 0.005 then 
                    isDuplicate = true
                    break
                end
            end
        end
        
        if not isDuplicate then
            table.insert(existing, {m = np.m, x = np.x, y = np.y})
            insertedCount = insertedCount + 1
        end
    end
    
    self.db.global.routes[petID] = existing
    
    if self.HUDFrame and self.HUDFrame:IsVisible() and self.UpdateCoordList then 
        self:UpdateCoordList() 
    end
    if self.RefreshMapLayer then self:RefreshMapLayer() end
    
    return insertedCount
end

function TamerTracksPetTracker:HookChatLinks()
    local originalSetItemRef = SetItemRef
    SetItemRef = function(link, text, button, chatFrame)
        if link:find("^TamerTracksPetTracker:") then
            local _, petIDStr, senderName = strsplit(":", link, 3)
            local petID = tonumber(petIDStr)
            
            if petID and senderName then
                local localPlayer = UnitName("player")
                local shortSender = strsplit("-", senderName)
                local fullLocalName = localPlayer .. "-" .. GetRealmName():gsub("%s+", "")
                if senderName == localPlayer or shortSender == localPlayer or senderName == fullLocalName then
                    print("|cffff0000[TamerTracksPetTracker]|r 对不起，您不能接收导入自己分享在公屏的路线信息。")
                    return true
                end
                
                print(string.format("|cff00ccff[TamerTracksPetTracker]|r 正在通过加密信道向玩家 %s 申请轨迹数据，请稍候...", senderName))
                self:SendCommMessage("TT_REQ", tostring(petID), "WHISPER", senderName)
            end
            return true
        end
        return originalSetItemRef(link, text, button, chatFrame)
    end
end
