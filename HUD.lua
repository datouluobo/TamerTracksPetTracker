local addonName, ns = ...
local TT = TamerTracksPetTracker
local AceGUI = LibStub("AceGUI-3.0")

function TT:CreateHUD()
    if self.HUDFrame then return end
    
    local f = AceGUI:Create("Window")
    f:SetTitle("TamerTracksPetTracker 控制台")
    f:SetLayout("Fill")
    f:SetWidth(340)
    f:SetHeight(500)
    
    local tabGroup = AceGUI:Create("TabGroup")
    tabGroup:SetLayout("Flow")
    tabGroup:SetTabs({
        {text = "轨迹追踪", value = "tab_track"},
        {text = "数据共享", value = "tab_sync"}
    })
    
    tabGroup:SetCallback("OnGroupSelected", function(container, event, group)
        container:ReleaseChildren()
        if group == "tab_track" then
            self:DrawTrackTab(container)
        elseif group == "tab_sync" then
            self:DrawSyncTab(container)
        end
    end)
    
    tabGroup:SelectTab("tab_track")
    f:AddChild(tabGroup)
    
    self.HUDFrame = f
end

function TT:DrawTrackTab(container)
    local selectPet = AceGUI:Create("Dropdown")
    local list = {}
    for id, p in pairs(ns.pets) do list[id] = p.name end
    selectPet:SetList(list)
    selectPet:SetValue(self.db.global.selectedPet)
    selectPet:SetCallback("OnValueChanged", function(widget, event, value)
        self.db.global.selectedPet = value
        self:UpdateCoordList()
        self:RefreshMapLayer()
    end)
    selectPet:SetFullWidth(true)
    container:AddChild(selectPet)
    
    local btnRec = AceGUI:Create("Button")
    btnRec:SetText("点击录入当前坐标 (/tra)")
    btnRec:SetCallback("OnClick", function() self:RecordCurrentPoint() end)
    btnRec:SetFullWidth(true)
    container:AddChild(btnRec)
    
    local btnRegen = AceGUI:Create("Button")
    btnRegen:SetText("|cff00ff00重新生成大小地图标记|r")
    btnRegen:SetCallback("OnClick", function() 
        if self.RefreshMapLayer then self:RefreshMapLayer() end 
    end)
    btnRegen:SetFullWidth(true)
    container:AddChild(btnRegen)

    local scrollContainer = AceGUI:Create("SimpleGroup")
    scrollContainer:SetFullWidth(true)
    scrollContainer:SetHeight(230)
    scrollContainer:SetLayout("Fill")
    container:AddChild(scrollContainer)

    local scroll = AceGUI:Create("ScrollFrame")
    scroll:SetLayout("Flow")
    scrollContainer:AddChild(scroll)
    self.CoordScroll = scroll

    local btnClear = AceGUI:Create("Button")
    btnClear:SetText("清空选中宠物的路径")
    btnClear:SetCallback("OnClick", function() 
        if not StaticPopupDialogs["TAMER_CLEAR_ROUTE"] then
            StaticPopupDialogs["TAMER_CLEAR_ROUTE"] = {
                text = "确认清空当前所选宠物的全部路点数据吗？此操作不可恢复！",
                button1 = "确认",
                button2 = "取消",
                OnAccept = function() 
                    TT.db.global.routes[TT.db.global.selectedPet] = {}
                    TT:UpdateCoordList()
                    if TT.RefreshMapLayer then TT:RefreshMapLayer() end
                end,
                timeout = 0,
                whileDead = true,
                hideOnEscape = true,
                preferredIndex = 3,
            }
        end
        StaticPopup_Show("TAMER_CLEAR_ROUTE") 
    end)
    btnClear:SetFullWidth(true)
    container:AddChild(btnClear)
    
    self:UpdateCoordList()
end

function TT:DrawSyncTab(container)
    local l1 = AceGUI:Create("Label")
    l1:SetText("您可以将当前选中宠物的轨迹发布到聊天频道中分享给其他人，或导出代码保留。")
    l1:SetFullWidth(true)
    container:AddChild(l1)
    
    local editBox = AceGUI:Create("MultiLineEditBox")
    editBox:SetLabel("数据代码 (可全选复制 / 覆盖粘贴后导入)")
    editBox:SetFullWidth(true)
    editBox:SetNumLines(8)
    editBox:DisableButton(true) -- 我们做自己的按钮
    container:AddChild(editBox)

    local btnExport = AceGUI:Create("Button")
    btnExport:SetText("生成导出数据代码")
    btnExport:SetFullWidth(true)
    btnExport:SetCallback("OnClick", function()
        local code = self:ExportToShareString(self.db.global.selectedPet)
        editBox:SetText(code)
    end)
    container:AddChild(btnExport)
    
    local btnChat = AceGUI:Create("Button")
    btnChat:SetText("|cff00ccff分享当前路线到游戏聊天频道|r")
    btnChat:SetFullWidth(true)
    btnChat:SetCallback("OnClick", function()
        local petName = ns.pets[self.db.global.selectedPet] and ns.pets[self.db.global.selectedPet].name or "未知"
        
        -- 生成跨服唯一识别名 (Name-Realm)
        local senderName = UnitName("player")
        local realmName = GetRealmName():gsub("%s+", "")
        local fullName = senderName .. "-" .. realmName
        
        -- 生成具有极短信标标识的纯文本消息 (绕过服务器过滤)
        local shortLink = string.format("【TamerTracksPetTracker】我摸索出了新的动物足迹！点击查看路线：{TT:%d:%s}", self.db.global.selectedPet, fullName)
        
        local activeEditBox = ChatEdit_GetActiveWindow()
        if activeEditBox then
            activeEditBox:Insert(shortLink)
        else
            ChatFrame_OpenChat(shortLink)
        end
    end)
    container:AddChild(btnChat)
    
    local btnImport = AceGUI:Create("Button")
    btnImport:SetText("|cffffcc00解析并导入输入框的数据|r")
    btnImport:SetFullWidth(true)
    btnImport:SetCallback("OnClick", function()
        local text = editBox:GetText()
        if not text or text == "" then return end
        self:ShowImportConfirmPopup(self.db.global.selectedPet, text)
        editBox:SetText("")
    end)
    container:AddChild(btnImport)
end

function TT:UpdateCoordList()
    if not self.CoordScroll then return end
    self.CoordScroll:ReleaseChildren()
    
    local petID = self.db.global.selectedPet
    local path = self.db.global.routes[petID] or {}
    
    local title = AceGUI:Create("Heading")
    title:SetText(string.format("已录入点 (总计 %d)", #path))
    title:SetFullWidth(true)
    self.CoordScroll:AddChild(title)

    for i = #path, 1, -1 do
        local p = path[i]
        
        local row = AceGUI:Create("SimpleGroup")
        row:SetFullWidth(true)
        row:SetLayout("Flow")
        
        local l = AceGUI:Create("Label")
        l:SetText(string.format("[%d] X:%.2f Y:%.2f", i, p.x*100, p.y*100))
        l:SetRelativeWidth(0.8) 
        l:SetColor(0.8, 0.8, 0.2)
        row:AddChild(l)
        
        local btnDel = AceGUI:Create("Button")
        btnDel:SetText("X")
        btnDel:SetRelativeWidth(0.18)
        btnDel:SetCallback("OnClick", function()
            table.remove(self.db.global.routes[petID], i)
            self:UpdateCoordList()
            if self.RefreshMapLayer then self:RefreshMapLayer() end
        end)
        row:AddChild(btnDel)
        
        self.CoordScroll:AddChild(row)
    end
end

-- 全局的聊天点击解析弹窗
function TT:ShowImportConfirmPopup(targetPetID, encodedString)
    local success, newDataOrError = self:DecodeShareString(encodedString)
    if not success then
        print("|cffff0000[TamerTracksPetTracker]|r 链接或数据解析失败: " .. tostring(newDataOrError))
        return
    end
    
    if #newDataOrError == 0 then
        print("|cffff0000[TamerTracksPetTracker]|r 这个分享中未包含任何坐标点。")
        return
    end
    
    local petName = ns.pets[targetPetID] and ns.pets[targetPetID].name or "未知猎物"
    
    -- 准备带有 追加 和 覆盖 功能的选择弹窗
    if not StaticPopupDialogs["TAMER_IMPORT_ROUTE"] then
        StaticPopupDialogs["TAMER_IMPORT_ROUTE"] = {
            text = "接收到了关于 [%s] 的路线分享（共 %d 个点）。\n请选择将如何与你的本地路线合并：\n\n【智能追加】保留你的数据，跳过重叠点，仅添加新点。\n【清理并覆盖】彻底删除你记录的该宠物踪迹，只保留对方的数据。",
            button1 = "清理并覆盖",
            button2 = "取消",
            button3 = "智能追加",
            OnAccept = function(dialog, data)
                -- 核心逻辑处理 - 覆盖
                local petID, rData = data.id, data.points
                local added = TT:MergeData(petID, rData, true)
                print(string.format("|cff00ccff[TamerTracksPetTracker]|r 数据已清理并覆盖，共载入 %d 个路点。", added))
            end,
            OnAlt = function(dialog, data)
                -- 核心逻辑处理 - 追加
                local petID, rData = data.id, data.points
                local added = TT:MergeData(petID, rData, false)
                print(string.format("|cff00ccff[TamerTracksPetTracker]|r 智能追加完毕！实际新增了 %d 个不重复路点。", added))
            end,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
        }
    end
    
    -- 更新文本
    StaticPopupDialogs["TAMER_IMPORT_ROUTE"].text = string.format("接收到了关于 [%s] 的路线分享（共 %d 个点）。\n请选择将如何与你的本地路线合并：\n\n【智能追加】保留你的数据，跳过重叠点（极近点去重算法），仅添加新点。\n【完全覆盖】彻底删除你记录的该宠物行迹，完全采用分享数据。", petName, #newDataOrError)
    
    local popup = StaticPopup_Show("TAMER_IMPORT_ROUTE")
    if popup then
        popup.data = {id = targetPetID, points = newDataOrError}
    end
end
