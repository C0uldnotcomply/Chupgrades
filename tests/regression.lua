-- Run from repository root: luajit tests/regression.lua
local host, unpack = _G, unpack
local passed, failed = 0, 0
local function eq(a,b,msg) assert(a==b,(msg or 'mismatch')..': expected '..tostring(b)..', got '..tostring(a)) end
local function test(name,fn)
  local ok,err=xpcall(fn,debug.traceback)
  if ok then passed=passed+1; print('PASS '..name) else failed=failed+1; print('FAIL '..name..'\n'..err) end
end
local function uv(fn,name)
  for i=1,100 do local k,v=debug.getupvalue(fn,i); if not k then break end; if k==name then return v end end
  error('missing upvalue '..name)
end
local function env(saved)
  local e=setmetatable({},{__index=host}); e._G=e
  e.frames,e.timers,e.messages,e.items,e.equipped,e.requests={},{},{},{},{},{}
  e.now,e.level,e.class,e.hit,e.money=100000,60,'WARRIOR',0,1000000
  e.Chupgrades,e.ChupgradesDB=nil,saved; e.SlashCmdList,e.UISpecialFrames={},{}
  e.tinsert,e.wipe=table.insert,function(t) for k in pairs(t) do t[k]=nil end return t end
  e.print=function(...) local t={}; for i=1,select('#',...) do t[i]=tostring(select(i,...)) end; e.messages[#e.messages+1]=table.concat(t,' ') end
  e.time,e.GetTime=function() return e.now end,function() return e.now end
  e.UnitLevel,e.UnitClass=function() return e.level end,function() return e.class,e.class end
  e.GetMoney=function() return e.money end
  e.GetMoneyString,e.GetCoinTextureString=function(n) return tostring(n)..'c' end,function(n) return tostring(n)..'c' end
  e.GetInventoryItemLink=function(_,slot) return e.equipped[slot] end
  e.GetInventoryItemID=function(_,slot) local l=e.equipped[slot]; return l and tonumber(l:match('item:(%d+)')) end
  e.IsAltKeyDown,e.IsShiftKeyDown,e.IsControlKeyDown=function() return false end,function() return false end,function() return false end
  e.GetHitModifier,e.GetSpellHitModifier=function() return 0 end,function() return 0 end
  e.GetCombatRatingBonus,e.GetCombatRating=function() return e.hit end,function() return e.hit*10 end
  e.CR_HIT_MELEE,e.CR_HIT_RANGED,e.CR_HIT_SPELL=1,2,3
  e.Enum={ItemClass={Weapon=2,Armor=4},AuctionHouseSortOrder={Price=1,Buyout=2},ItemCommodityStatus={Item=1},PlayerInteractionType={Auctioneer=1}}
  local m,make={},nil
  function m:SetScript(k,fn) self.scripts[k]=fn end
  function m:GetScript(k) return self.scripts[k] end
  function m:RegisterEvent(k) self.events[k]=true end
  function m:UnregisterEvent(k) self.events[k]=nil end
  function m:UnregisterAllEvents() self.events={} end
  function m:SetSize(w,h) self.width,self.height=w,h end
  function m:SetWidth(w) self.width=w end
  function m:SetHeight(h) self.height=h end
  function m:GetWidth() return self.width or 900 end
  function m:GetHeight() return self.height or 520 end
  function m:SetScale(v) self.scale=v end
  function m:GetScale() return self.scale or 1 end
  function m:GetEffectiveScale() return self.scale or 1 end
  function m:SetFrameLevel(v) self.frameLevel=v end
  function m:GetFrameLevel() return self.frameLevel or 1 end
  function m:SetPoint(...) self.point={...} end
  function m:GetPoint() return unpack(self.point or {'CENTER',e.UIParent,'CENTER',0,0}) end
  function m:GetCenter() return 600,400 end
  function m:GetLeft() return 0 end
  function m:GetTop() return 800 end
  function m:ClearAllPoints() self.point=nil end
  function m:SetText(v) self.text=v end
  function m:GetText() return self.text or '' end
  function m:GetStringWidth() return #(self.text or '')*6 end
  function m:SetFormattedText(fmt,...) self.text=fmt:format(...) end
  function m:Show() local was=self.shown; self.shown=true; if not was and self.scripts.OnShow then self.scripts.OnShow(self) end end
  function m:Hide() self.shown=false end
  function m:SetShown(v) if v then self:Show() else self:Hide() end end
  function m:IsShown() return self.shown end
  function m:IsVisible() return self.shown end
  function m:SetChecked(v) self.checked=v end
  function m:GetChecked() return self.checked end
  function m:Enable() self.enabled=true end
  function m:Disable() self.enabled=false end
  function m:SetEnabled(v) self.enabled=v end
  function m:IsEnabled() return self.enabled end
  function m:GetParent() return self.parent end
  function m:SetVerticalScroll(v) self.scroll=v end
  function m:GetVerticalScroll() return self.scroll or 0 end
  function m:GetVerticalScrollRange() return 10000 end
  function m:GetContentHeight() return 1000 end
  function m:NumLines() return 0 end
  function m:IsMouseOver() return false end
  local mt={__index=function(t,k) if m[k] then return m[k] end; if k:match('^[A-Z]') then return function() end end end}
  make=function(kind,name,parent)
    local f=setmetatable({kind=kind,name=name,parent=parent,scripts={},events={},shown=true,enabled=true},mt)
    e.frames[#e.frames+1]=f; if name then e[name]=f end; return f
  end
  function m:CreateFontString() return make('FontString',nil,self) end
  function m:CreateTexture() return make('Texture',nil,self) end
  e.CreateFrame=function(kind,name,parent,template) local f=make(kind,name,parent); if template and template:find('BasicFrame') then f.TitleText=make('FontString',nil,f) end; return f end
  e.UIParent,e.AuctionHouseFrame,e.GameTooltip=make('Frame'),make('Frame'),make('Tooltip'); e.UIParent:SetSize(1920,1080)
  e.GameTooltip.SetHyperlink=function() end
  e.C_Timer={}
  function e.C_Timer.NewTimer(delay,fn) local t={at=e.now+delay,fn=fn,Cancel=function(self) self.cancelled=true end}; e.timers[#e.timers+1]=t; return t end
  function e.C_Timer.After(delay,fn) e.C_Timer.NewTimer(delay,fn) end
  function e.advance(seconds)
    local target,calls=e.now+seconds,0
    while true do
      local nt; for _,t in ipairs(e.timers) do if not t.cancelled and not t.ran and t.at<=target and (not nt or t.at<nt.at) then nt=t end end
      if not nt then break end; calls=calls+1; assert(calls<1000,'timer runaway'); e.now,nt.ran=nt.at,true; nt.fn()
    end; e.now=target
  end
  function e.emit(event,...)
    local list={}; for _,f in ipairs(e.frames) do list[#list+1]=f end
    for _,f in ipairs(list) do if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f,event,...) end end
  end
  function e.item(id,it)
    it=it or {}; it.id=id; it.link=it.link or ('|Hitem:'..id..':0:0:0:0:0:0:0|h[Item '..id..']|h')
    it.name=it.name or ('Item '..id); it.loc=it.loc or 'INVTYPE_HEAD'; it.class=it.class or 4; it.sub=it.sub or 4; it.req=it.req or 1
    it.stats=it.stats or {ITEM_MOD_ATTACK_POWER_SHORT=it.score or 10}; it.quality=it.quality or 2
    e.items[id],e.items[it.link]=it,it; return it
  end
  local function info(item) return e.items[item] or e.items[tonumber(type(item)=='string' and item:match('item:(%d+)') or item)] end
  e.GetItemInfo=function(item) local it=info(item); if not it or it.cached==false then return end; return it.name,it.link,it.quality,50,it.req,'Armor','Plate',1,it.loc,'icon',1,it.class,it.sub,1,1,it.setID end
  e.GetItemInfoInstant=function(item) local it=info(item); if not it or it.instant==false then return end; return it.id,'Armor','Plate',it.loc,'icon',it.class,it.sub end
  e.GetItemStats=function(item) local it=info(item); return it and it.cached~=false and it.stats or nil end
  e.C_Item={GetItemInfo=e.GetItemInfo,GetItemInfoInstant=e.GetItemInfoInstant,GetItemStats=e.GetItemStats,
    IsItemDataCachedByID=function(id) local it=info(id); return it and it.cached~=false or false end,
    RequestLoadItemDataByID=function(id) assert(type(id)=='number','load request must use numeric ID'); e.requests[#e.requests+1]=id end}
  e.weights={ITEM_MOD_ATTACK_POWER_SHORT=1,ITEM_MOD_HIT_RATING_SHORT=1}
  e.StatPriority={GetActiveWeights=function() return e.weights,'Arms',true end,Resolve=function() return {specID=71,specName='Arms'} end,
    IsForever=function() return true end,RatingPerPercent={hit=10},StripEnchant=function(l) return l end,Usability=function() return 'yes' end,
    ScoreItem=function(_,link,w) local it=info(link); if not it or it.cached==false then return nil end; if it.score then return it.score end; local n=0; for k,v in pairs(it.stats) do n=n+v*(w[k] or 0) end; return n end}
  e.C_AuctionHouse={ReplicateItems=function() e.replicates=(e.replicates or 0)+1 end,
    GetNumReplicateItems=function() return #(e.replicateRows or {}) end,
    GetReplicateItemInfo=function(i) local r=e.replicateRows[i+1]; return nil,nil,1,nil,nil,nil,nil,nil,nil,r.price,nil,nil,nil,nil,nil,nil,r.id end,
    GetReplicateItemLink=function(i) return e.replicateRows[i+1].link end,
    IsThrottledMessageSystemReady=function() return true end,
    SendBrowseQuery=function(q) e.browseQuery=q end,GetBrowseResults=function() return e.browseRows or {} end,HasFullBrowseResults=function() return true end,
    RequestMoreBrowseResults=function() e.moreBrowse=(e.moreBrowse or 0)+1 end,
    SendSearchQuery=function(key) e.sentKey=key end,GetNumItemSearchResults=function() return #(e.searchRows or {}) end,
    GetItemSearchResultInfo=function(_,i) return e.searchRows[i] end,HasFullItemSearchResults=function() return e.searchComplete~=false end,
    RequestMoreItemSearchResults=function() e.moreSearch=(e.moreSearch or 0)+1 end,GetItemCommodityStatus=function() return 1 end}
  for _,file in ipairs({'Config.lua','Core.lua'}) do local f=assert(loadfile('Chupgrades/'..file)); setfenv(f,e); f('Chupgrades') end
  e.emit('ADDON_LOADED','Chupgrades'); return e,e.Chupgrades
end

test('documented money formats and invalid input',function()
  local e,cu=env(); eq(cu.ParseMoney('5'),50000); eq(cu.ParseMoney('1g 33s 38c'),13338); eq(cu.ParseMoney(' 1G 2S 3C '),10203); eq(cu.ParseMoney('0.5'),5000)
  for _,v in ipairs({'-1','1x','nan','inf','1g junk','1e309'}) do eq(cu.ParseMoney(v),nil,v) end
end)
test('invalid slash settings preserve previous values',function()
  local e=env(); local db=e.ChupgradesDB
  for _,c in ipairs({{'budget','budgetCopper',12345,'wat'},{'keep','reserveCopper',999,'-1'},{'min','minUpgradePct',2,'-1'},{'ahead','levelLookahead',3,'1.5'},{'searchcap','searchCap',200,'inf'},{'floor','searchFloor',10,'-1'}}) do db[c[2]]=c[3]; e.SlashCmdList.CHUPGRADES(c[1]..' '..c[4]); eq(db[c[2]],c[3],c[1]) end
  for _,v in ipairs({'slot [','slot','slot h'}) do e.SlashCmdList.CHUPGRADES(v); eq(next(db.hiddenSlots),nil,v) end
end)
test('corrupt saved settings normalize before use',function()
  local e=env({minUpgradePct=0/0,levelLookahead=-8,reserveCopper='broken',view='nonsense',hiddenSlots=false,hiddenQuality='broken',budgetGold='oops',savedScan={time='oops',items={junk={price=-1}}}}); local d=e.ChupgradesDB
  assert(type(d.minUpgradePct)=='number' and d.minUpgradePct==d.minUpgradePct); assert(type(d.levelLookahead)=='number' and d.levelLookahead>=0); assert(type(d.reserveCopper)=='number' and d.reserveCopper>=0)
  eq(type(d.hiddenSlots),'table'); eq(type(d.hiddenQuality),'table'); eq(d.view,'list')
end)
test('first results render constructs complete window',function()
  local e,cu=env(); cu.lastScan={}; cu:BuildResults(); local w=cu.window or e.ChupgradesFrame
  assert(w and w.msg and w.cards and #w.cards==6,'complete results window missing'); assert(w:IsShown())
end)
test('budget and keep use separate gold/silver/copper boxes',function()
  local e,cu=env(); cu.lastScan={}; cu:BuildResults(); local w=cu.window or e.ChupgradesFrame; local db=e.ChupgradesDB
  local b,k=w.budgetField.boxes,w.reserveField.boxes; eq(#b,3); eq(#k,3)
  local function typeIn(boxes,g,s2,c) boxes[1]:SetText(g); boxes[2]:SetText(s2); boxes[3]:SetText(c); boxes[2].scripts.OnEditFocusLost(boxes[2]); e.advance(0) end
  typeIn(b,'1','33','38'); eq(db.budgetCopper,13338)
  typeIn(b,'5','',''); eq(db.budgetCopper,50000)
  typeIn(b,'','',''); eq(db.budgetCopper,nil)          -- empty budget = plan with carried money
  typeIn(k,'2','50',''); eq(db.reserveCopper,25000)
  typeIn(k,'','',''); eq(db.reserveCopper,0)           -- empty keep = keep nothing back
  db.budgetCopper=12345; w.budgetField.restore(); eq(b[1]:GetText(),'1'); eq(b[2]:GetText(),'23'); eq(b[3]:GetText(),'45')
  b[1]:SetText('99'); b[1].scripts.OnEscapePressed(b[1]); eq(b[1]:GetText(),'1'); e.advance(0); eq(db.budgetCopper,12345)
end)
test('every-upgrade pagination reaches items after sixth',function()
  local e,cu=env(); e.ChupgradesDB.showAll=true; e.ChupgradesDB.topFive=false; cu.lastScan={}
  for i=1,8 do local it=e.item(100+i,{score=10+i}); cu.lastScan[it.link]={price=100*i,equipLoc=it.loc,classID=4,subID=4} end
  cu:BuildResults(); eq(cu.pageCount,2); local w=cu.window or e.ChupgradesFrame; local first=w.cards[1].item.link
  assert(w.nextPage and w.nextPage.scripts.OnClick,'next-page control missing'); w.nextPage.scripts.OnClick(w.nextPage); assert(w.cards[1].item.link~=first); eq(cu.page,2)
end)
test('uncached equipped item never becomes empty baseline',function()
  local e,cu=env(); local old=e.item(1,{cached=false,score=100}); local new=e.item(2,{score=50}); e.equipped[1]=old.link; cu.lastScan={[new.link]={price=100,equipLoc=new.loc,classID=4,subID=4}}
  cu:BuildResults(); eq(#(cu.lastAll.Head or {}),0); assert(cu.pendingLoading>0); assert(#e.requests>0)
  e.SlashCmdList.CHUPGRADES('why '..new.link) -- diagnostic must handle an uncached baseline too
  old.cached=true; e.emit('GET_ITEM_INFO_RECEIVED',1,true); e.advance(2); eq(#(cu.lastAll.Head or {}),0)
end)
test('armor proficiency uses player level and lookahead',function()
  local e,cu=env(); local use=uv(cu.BuildResults,'CanUse'); local it=e.item(10,{req=35}); eq(use(it.link,it.loc,4,4),true)
  e.level=39; e.ChupgradesDB.levelLookahead=0; eq(use(it.link,it.loc,4,4),false); e.ChupgradesDB.levelLookahead=1; local ok,req=use(it.link,it.loc,4,4); eq(ok,true); eq(req,40)
end)
test('capped-hit-only empty slot is not an upgrade',function()
  local e,cu=env(); e.hit=20; local it=e.item(20,{stats={ITEM_MOD_HIT_RATING_SHORT=20}}); cu.lastScan={[it.link]={price=100,equipLoc=it.loc,classID=4,subID=4}}; cu:BuildResults(); eq(#(cu.lastAll.Head or {}),0)
end)
test('ring replacement maximizes hit-aware gain',function()
  local e,cu=env(); e.hit=17; local a=e.item(30,{loc='INVTYPE_FINGER',stats={ITEM_MOD_ATTACK_POWER_SHORT=10,ITEM_MOD_HIT_RATING_SHORT=90}}); local b=e.item(31,{loc='INVTYPE_FINGER',stats={ITEM_MOD_ATTACK_POWER_SHORT=20}}); local n=e.item(32,{loc='INVTYPE_FINGER',stats={ITEM_MOD_ATTACK_POWER_SHORT=30}})
  e.equipped[11],e.equipped[12]=a.link,b.link; cu.lastScan={[n.link]={price=100,equipLoc=n.loc,classID=4,subID=0}}; cu:BuildResults(); local r=assert((cu.lastAll.Ring or {})[1],'ring missing'); eq(r.gain,20)
end)
test('full scan never fabricates unresolved random variant',function()
  local e,cu=env(); local it=e.item(40); e.replicateRows={{id=40,price=100,link=nil}}; cu.lastScan={}; cu:StartScan(); e.emit('REPLICATE_ITEM_LIST_UPDATE'); e.advance(40)
  eq(cu.lastScan[it.link],nil); assert(cu.lastScanStats and cu.lastScanStats.unread>0)
end)
test('full-scan API exception cleans running state',function()
  local e,cu=env(); e.C_AuctionHouse.ReplicateItems=function() error('test API failure') end; cu:StartScan(); assert(not cu.fullScanRunning)
end)
test('closing AH cancels full scan and stale callback',function()
  local e,cu=env(); cu.lastScan={}; local old=cu.lastScan; cu:StartScan(); e.emit('REPLICATE_ITEM_LIST_UPDATE'); local callbacks={}; for _,t in ipairs(e.timers) do callbacks[#callbacks+1]=t.fn end
  e.emit('AUCTION_HOUSE_CLOSED'); assert(not cu.fullScanRunning); for _,fn in ipairs(callbacks) do fn() end; eq(cu.lastScan,old)
end)
test('targeted scan prices requested rolled key and pages',function()
  local e,cu=env(); local fixed=e.item(50,{quality=1}); local rolled=e.item(51,{stats={ITEM_MOD_ATTACK_POWER_SHORT=0}})
  local fk={itemID=50,itemLevel=10,itemSuffix=0,battlePetSpeciesID=0}; local rk={itemID=51,itemLevel=40,itemSuffix=10,battlePetSpeciesID=0}
  e.browseRows={{itemKey=fk,minPrice=10},{itemKey=rk,minPrice=100}}; cu:StartSlotSearch({'Head'}); e.emit('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED'); eq(e.sentKey.itemID,51)
  e.searchRows={{itemLink=rolled.link,buyoutAmount=100,quantity=1}}; e.searchComplete=false
  e.emit('ITEM_SEARCH_RESULTS_UPDATED',{itemID=51,itemLevel=40,itemSuffix=99,battlePetSpeciesID=0}); assert(cu.slotSearch)
  e.emit('ITEM_SEARCH_RESULTS_UPDATED',rk); assert(e.moreSearch and e.moreSearch>0); assert(cu.slotSearch)
  e.searchRows={{itemLink=rolled.link,buyoutAmount=100,quantity=1},{itemLink=rolled.link,buyoutAmount=50,quantity=1}}; e.searchComplete=true; e.emit('ITEM_SEARCH_RESULTS_ADDED',rk)
  assert(not cu.slotSearch); eq(cu.lastScan[rolled.link].price,50)
end)
test('ring pairs share hit-cap room exactly once',function()
  local e,cu=env(); e.hit=7
  local oldA=e.item(60,{loc='INVTYPE_FINGER',stats={ITEM_MOD_ATTACK_POWER_SHORT=10}})
  local oldB=e.item(61,{loc='INVTYPE_FINGER',stats={ITEM_MOD_ATTACK_POWER_SHORT=10}})
  local a=e.item(62,{loc='INVTYPE_FINGER',stats={ITEM_MOD_ATTACK_POWER_SHORT=10,ITEM_MOD_HIT_RATING_SHORT=10}})
  local b=e.item(63,{loc='INVTYPE_FINGER',stats={ITEM_MOD_ATTACK_POWER_SHORT=11,ITEM_MOD_HIT_RATING_SHORT=10}})
  e.equipped[11],e.equipped[12]=oldA.link,oldB.link
  cu.lastScan={}; for _,it in ipairs({a,b}) do cu.lastScan[it.link]={price=100,equipLoc=it.loc,classID=4,subID=0} end
  cu:BuildResults(); local groups=cu:BuildPlanOptions(e.weights); local found
  for _,opts in ipairs(groups) do for _,o in ipairs(opts) do if #o.items==2 then found=o end end end
  assert(found,'pair option missing'); eq(found.gain,11,'pair reused hit headroom')
end)
test('shopping total combines hit caps across different slots',function()
  local e,cu=env(); e.hit=7
  local oldA=e.item(70,{stats={ITEM_MOD_ATTACK_POWER_SHORT=100}})
  local oldB=e.item(71,{loc='INVTYPE_CHEST',stats={ITEM_MOD_ATTACK_POWER_SHORT=100}})
  local a=e.item(72,{stats={ITEM_MOD_ATTACK_POWER_SHORT=100,ITEM_MOD_HIT_RATING_SHORT=10}})
  local b=e.item(73,{loc='INVTYPE_CHEST',stats={ITEM_MOD_ATTACK_POWER_SHORT=100,ITEM_MOD_HIT_RATING_SHORT=10}})
  e.equipped[1],e.equipped[5]=oldA.link,oldB.link
  cu.lastScan={}; for _,it in ipairs({a,b}) do cu.lastScan[it.link]={price=100,equipLoc=it.loc,classID=4,subID=4} end
  cu:BuildResults(); cu.shownLinks,cu.lineItems={},{}
  local lines={}; cu:RenderPlan({AddMessage=function(_,s) lines[#lines+1]=s end})
  local summary; for _,line in ipairs(lines) do if line:find('Spend ',1,true) then summary=line; break end end
  assert(summary,'plan summary missing'); assert(summary:find('+5.0% gear score',1,true),summary)
end)
test('no-response full scan times out preserving old snapshot',function()
  local e,cu=env(); cu.lastScan={}; local old=cu.lastScan
  cu:StartScan(); e.advance(100); assert(not cu.fullScanRunning); eq(cu.lastScan,old)
end)
test('shopping plan never recommends a combined downgrade',function()
  local e,cu=env(); e.hit=7
  local oldA=e.item(80,{stats={ITEM_MOD_ATTACK_POWER_SHORT=100}})
  local oldB=e.item(81,{loc='INVTYPE_CHEST',stats={ITEM_MOD_ATTACK_POWER_SHORT=100}})
  local a=e.item(82,{stats={ITEM_MOD_ATTACK_POWER_SHORT=92,ITEM_MOD_HIT_RATING_SHORT=10}})
  local b=e.item(83,{loc='INVTYPE_CHEST',stats={ITEM_MOD_ATTACK_POWER_SHORT=92,ITEM_MOD_HIT_RATING_SHORT=10}})
  e.equipped[1],e.equipped[5]=oldA.link,oldB.link
  cu.lastScan={}; for _,it in ipairs({a,b}) do cu.lastScan[it.link]={price=100,equipLoc=it.loc,classID=4,subID=4} end
  cu:BuildResults(); cu.shownLinks,cu.lineItems={},{}
  local lines={}; cu:RenderPlan({AddMessage=function(_,s) lines[#lines+1]=s end})
  local summary; for _,line in ipairs(lines) do if line:find('Spend ',1,true) then summary=line; break end end
  assert(summary,'plan summary missing'); assert(summary:find('Spend 100c',1,true),summary); assert(summary:find('+1.0% gear score',1,true),summary)
end)
test('throttled targeted search has a bounded deadline',function()
  local e,cu=env(); cu.lastScan={}; local old=cu.lastScan
  e.C_AuctionHouse.IsThrottledMessageSystemReady=function() return false end
  cu:StartSlotSearch({'Head'}); e.advance(25); assert(not cu.slotSearch); eq(cu.lastScan,old)
end)
test('explicit stop preserves previous scan',function()
  local e,cu=env(); cu.lastScan={}; local old=cu.lastScan
  cu:StartScan(); e.SlashCmdList.CHUPGRADES('stop'); assert(not cu.fullScanRunning); eq(cu.lastScan,old)
  cu:StartSlotSearch({'Head'}); e.SlashCmdList.CHUPGRADES('stop'); assert(not cu.slotSearch); eq(cu.lastScan,old)
end)
test('incomplete browse timeout retains previous slot listings',function()
  local e,cu=env(); local old=e.item(90)
  cu.lastScan={[old.link]={price=50,equipLoc=old.loc,classID=4,subID=4}}
  e.ChupgradesDB.savedScan={time=e.now-60,items=cu.lastScan}
  e.C_AuctionHouse.HasFullBrowseResults=function() return false end
  cu:StartSlotSearch({'Head'}); e.emit('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED')
  eq(e.moreBrowse,1,'next browse page was not requested'); e.advance(40)
  assert(not cu.slotSearch,'incomplete browse did not finish within deadline')
  assert(cu.partialScan,'browse timeout was marked complete')
  assert(cu.lastScan[old.link],'incomplete browse deleted previous Head listing')
  e.C_AuctionHouse.HasFullBrowseResults=function() return true end
  e.browseRows={}; cu:StartSlotSearch({'Neck'}); e.emit('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED')
  assert(not cu.slotSearch); assert(cu.lastScan[old.link],'different slot search removed retained Head item')
  assert(cu.partialScan,'complete search of a different slot cleared partial-coverage warning')
end)
test('unknown browse metadata requests data and retains old listings',function()
  local e,cu=env(); local old=e.item(91); local unknown=e.item(92,{instant=false})
  cu.lastScan={[old.link]={price=50,equipLoc=old.loc,classID=4,subID=4}}
  e.ChupgradesDB.savedScan={time=e.now-60,items=cu.lastScan}
  e.browseRows={{itemKey={itemID=92,itemLevel=40,itemSuffix=0,battlePetSpeciesID=0},minPrice=100}}
  cu:StartSlotSearch({'Head'}); e.emit('AUCTION_HOUSE_BROWSE_RESULTS_UPDATED'); e.advance(40)
  local requested=false; for _,id in ipairs(e.requests) do if id==92 then requested=true end end
  assert(requested,'unknown browse metadata did not request numeric item data')
  assert(not cu.slotSearch,'unknown metadata search did not finish within deadline')
  assert(cu.partialScan,'unread browse row was silently marked complete')
  assert(cu.lastScan[old.link],'unread browse row caused old Head listing deletion')
end)
print(('RESULT %d passed, %d failed'):format(passed,failed)); if failed>0 then os.exit(1) end
