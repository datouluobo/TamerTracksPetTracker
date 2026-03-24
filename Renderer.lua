local addonName, ns = ...
local TT = TamerTracksPetTracker

local HBD = LibStub("HereBeDragons-2.0")
local HBDPins = LibStub("HereBeDragons-Pins-2.0")

-- ==========================================
-- 大地图自适应反差颜色配置
-- ==========================================
local mapLineColors = {
    [371] = {1, 0, 1, 0.8},       -- 翡翠林 (主色:翠绿) -> 反差色:品红
    [376] = {0, 0.2, 1, 0.8},     -- 四风谷 (主色:金黄) -> 反差色:深蓝
    [418] = {0, 1, 1, 0.8},       -- 卡桑琅丛林 (主色:暗绿) -> 反差色:亮青
    [379] = {1, 0, 0, 0.8},       -- 昆莱山 (主色:白雪) -> 反差色:纯红
    [388] = {1, 0, 1, 0.8},       -- 螳螂高原 (主色:暗灰) -> 反差色:品红
    [422] = {1, 0.5, 0, 0.8},     -- 恐惧废土 (主色:深蓝黑) -> 反差色:亮橙
    [390] = {1, 0, 0, 0.8},       -- 锦绣谷 (主色:金黄/暗紫) -> 反差色:纯红
}
local defaultLineColor = {1, 0, 0, 0.8} -- 默认颜色: 警戒红

local function GetLineColor(mapID)
    if not mapID then return unpack(defaultLineColor) end
    local c = mapLineColors[mapID] or defaultLineColor
    return c[1], c[2], c[3], c[4]
end

-- ==========================================
-- 大地图渲染方案 (点阵与连线架构准备)
-- ==========================================

local activePins = {}
local pinPool = {}

local function GetMapPin()
    local p = table.remove(pinPool)
    if not p then
        p = CreateFrame("Frame", nil, nil)
        p.t = p:CreateTexture(nil, "OVERLAY")
        p.t:SetAllPoints()
        p.t:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
        -- 尝试利用现代客户端原生线条API
        if p.CreateLine then
            p.line = p:CreateLine(nil, "BACKGROUND")
            p.line:SetTexture("Interface\\ChatFrame\\ChatFrameBackground")
            p.line:SetThickness(2)
        end
    end
    p:Show()
    if p.line then p.line:Hide() end
    return p
end

function TT:RefreshMapLayer()
    -- 1. 清空大地图和小地图中的旧标记
    HBDPins:RemoveAllMinimapIcons(TT)
    HBDPins:RemoveAllWorldMapIcons(TT)
    
    -- 2. 回收旧 Frame 与线段
    for _, pin in ipairs(activePins) do
        pin:Hide()
        pin:ClearAllPoints()
        table.insert(pinPool, pin)
    end
    wipe(activePins)
    
    local petID = self.db.global.selectedPet
    if not petID then return end
    
    local path = self.db.global.routes[petID]
    if not path or #path == 0 then return end
    
    -- 3. 就近连线算法 (最近邻近似)：整理有效的分段
    local unvisited = {}
    for i, p in ipairs(path) do
        unvisited[i] = {id = i, m = p.m, x = p.x, y = p.y}
    end
    
    local segments = {}
    while next(unvisited) do
        local startIdx, startPt
        for i, p in pairs(unvisited) do
            startIdx, startPt = i, p
            break
        end
        unvisited[startIdx] = nil
        
        local current_seg = { startPt }
        local current = startPt
        
        while true do
            local bestDist = 0.06 -- 全地图6%的距离判定为偏离断点(阈值)
            local bestIdx, bestPt
            for i, p in pairs(unvisited) do
                if p.m == current.m then
                    local dx = p.x - current.x
                    local dy = p.y - current.y
                    local dist = math.sqrt(dx*dx + dy*dy)
                    if dist < bestDist then
                        bestDist = dist
                        bestIdx = i
                        bestPt = p
                    end
                end
            end
            
            if bestPt then
                table.insert(current_seg, bestPt)
                unvisited[bestIdx] = nil
                current = bestPt
            else
                break
            end
        end
        table.insert(segments, current_seg)
    end
    
    -- 4. 绘制连线分段与节点
    local totalDrawn = 0
    for sIdx, seg in ipairs(segments) do
        local prevPin = nil
        for i, p in ipairs(seg) do
            local isLatest = (p.id == #path)
            
            local wPin = GetMapPin()
            wPin:SetSize(4, 4)
            if isLatest then
                wPin.t:SetVertexColor(0, 1, 0, 1)    -- 最新点: 绿色
            else
                wPin.t:SetVertexColor(1, 1, 0, 1)  -- 历史点: 黄色
            end
            if wPin.SetFrameLevel then wPin:SetFrameLevel(9999) end
            
            HBDPins:AddWorldMapIconMap(TT, wPin, p.m, p.x, p.y, 0)
            table.insert(activePins, wPin)
            
            -- 实现真连线/虚拟连线回退
            if prevPin then
                local lr, lg, lb, la = GetLineColor(p.m)
                
                if prevPin.line then
                    -- 现代客户端支持真线段
                    prevPin.line:SetStartPoint("CENTER", prevPin)
                    prevPin.line:SetEndPoint("CENTER", wPin)
                    prevPin.line:SetVertexColor(lr, lg, lb, la)
                    prevPin.line:Show()
                else
                    -- 兼容老客户端：平滑插入虚拟点生成虚线
                    local dist = math.sqrt((p.x - prevPin.rawX)^2 + (p.y - prevPin.rawY)^2)
                    local steps = math.floor(dist / 0.005) -- 每 0.5% 距离插一个点
                    if steps > 10 then steps = 10 end
                    for st = 1, steps - 1 do
                        local dot = GetMapPin()
                        dot:SetSize(2, 2)
                        dot.t:SetVertexColor(lr, lg, lb, la)
                        local mx = prevPin.rawX + (p.x - prevPin.rawX) * (st / steps)
                        local my = prevPin.rawY + (p.y - prevPin.rawY) * (st / steps)
                        HBDPins:AddWorldMapIconMap(TT, dot, p.m, mx, my, 0)
                        table.insert(activePins, dot)
                    end
                end
            end
            
            wPin.rawX = p.x
            wPin.rawY = p.y
            prevPin = wPin
            totalDrawn = totalDrawn + 1
        end
    end
    
    print(string.format("|cff00ccff[TamerTracksPetTracker]|r: 路径智能连线完毕。有效坐标: %d，拆分为 %d 段联结线。", totalDrawn, #segments))
end

-- 进游戏自动加载逻辑 (去除冗余的 /trtest 命令)
local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:SetScript("OnEvent", function(self, event)
    C_Timer.After(4, function() 
        if TT.RefreshMapLayer then TT:RefreshMapLayer() end 
    end)
end)
