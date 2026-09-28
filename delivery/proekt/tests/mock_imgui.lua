-- Headless-мок mimgui (Dear ImGui 1.76) для проверки вёрстки SFN Logs.
-- Повторяет реальную семантику: поток элементов двигает курсор, Dummy
-- резервирует место, SetCursorScreenPos позиционирует абсолютно,
-- GetContentRegionAvail считает от содержимого окна.
-- Все отрисованные тексты и прямоугольники записываются — по ним внешний
-- тест проверяет наложения и выход за границы окна.

local mock = {}

-- ------------------------------------------------------------- состояние --
local st = {
    frames        = 0,
    depth         = 0,      -- глубина стека Begin/BeginChild
    stack         = {},     -- регионы: {x,y,w,h,cx,cy,maxx,maxy,kind,id}
    cursor        = { x = 0, y = 0 },
    prevLineX     = 0,
    prevLineY     = 0,
    lastItemMaxX  = 0,
    winSize       = { x = 800, y = 600 },
    padX          = 12,
    fontsAdded    = {},
    fontDepth     = 0,
    padY          = 12,
    popX          = 3000,
    popY          = 3000,
    modalX        = 6000,
    modalY        = 6000,
    nextSize      = nil,
    styleColorN   = 0,
    styleVarN     = 0,
    itemWidth     = nil,
    texts         = {},
    rects         = {},
    items         = {},     -- интерактивные элементы: {id,x,y,w,h,frame}
    childLog      = {},     -- BeginChild за кадр: {id,flags,frame,x,y,w,h}
    popupLog      = {},     -- BeginPopup за кадр: {id,frame,x,y,w,h,sized}
    popAuto       = {},     -- автосайз попапов: id -> {w,h} содержимое прош. кадра
    errors        = {},
    trace         = {},
    display       = { x = 1920, y = 1080 },
    dpi           = 1.0,
    fontH         = 16,
    popupOpen     = {},     -- id -> true (имитация открытых попапов)
    comboOpen     = {},     -- id -> true (имитация раскрытого выпадающего списка)
    clicks        = {},     -- id -> true (имитация клика в этом кадре)
    hovers        = {},     -- id -> true
    inputs        = {},     -- id -> строка для InputText
    mouse         = { x = -500, y = -500 },  -- курсор для ручных hit-test'ов
    mouseClicked  = {},     -- [кнопка] = true (имитация нажатия в кадре)
    anyItemHovered = false, -- имитация IsAnyItemHovered
}
mock.st = st

local function err(msg)
    st.errors[#st.errors + 1] = string.format('кадр %d: %s', st.frames, msg)
end

-- Апроксимация CalcTextSize: Trebuchet Bold 14px, кириллица чуть шире латиницы.
local function measure(s)
    if type(s) ~= 'string' then s = tostring(s) end
    local w, i, n = 0, 1, #s
    while i <= n do
        local b = s:byte(i)
        if b < 0x80 then
            w = w + (s:sub(i, i):match('[iIlj.,:;\'`!|]') and 0.32 or
                     s:sub(i, i):match('[mwMW]') and 0.95 or 0.60)
            i = i + 1
        elseif b >= 0xC0 and b <= 0xDF then
            w = w + 0.72; i = i + 2
        elseif b >= 0xE0 and b <= 0xEF then
            w = w + 0.78; i = i + 3
        else
            w = w + 0.8; i = i + 4
        end
    end
    return w * st.fontH
end

-- ------------------------------------------------------------- векторы ----
local ImVec2 = {}
ImVec2.__index = ImVec2
local function newVec2(x, y)
    return setmetatable({ x = x or 0, y = y or 0 }, ImVec2)
end
local function newVec4(x, y, z, w)
    return setmetatable({ x = x or 0, y = y or 0, z = z or 0, w = w or 1 }, ImVec2)
end

-- -------------------------------------------------------------枚举 --------
local function enum(prefix, names)
    local t = {}
    for i, n in ipairs(names) do t[n] = i end
    return t
end

-- флаги окон и условия — настоящие битовые значения Dear ImGui
local WINFLAGS_BITS = {
    None = 0, NoTitleBar = 1, NoResize = 2, NoMove = 4, NoScrollbar = 8,
    NoScrollWithMouse = 16, HorizontalScrollbar = 32, NoCollapse = 64,
    NoFocusOnAppearing = 128, NoBringToFrontOnFocus = 256, NoBackground = 512,
}
local COND_BITS = { None = 0, Always = 1, Once = 2, FirstUseEver = 4, Appearing = 8 }

local COL_NAMES = {
    'Text', 'TextDisabled', 'WindowBg', 'ChildBg', 'PopupBg', 'Border', 'BorderShadow',
    'FrameBg', 'FrameBgHovered', 'FrameBgActive', 'TitleBg', 'TitleBgActive',
    'TitleBgCollapsed', 'MenuBarBg', 'ScrollbarBg', 'ScrollbarGrab', 'ScrollbarGrabHovered',
    'ScrollbarGrabActive', 'CheckMark', 'SliderGrab', 'SliderGrabActive', 'Button',
    'ButtonHovered', 'ButtonActive', 'Header', 'HeaderHovered', 'HeaderActive',
    'Separator', 'SeparatorHovered', 'SeparatorActive', 'ResizeGrip', 'ResizeGripHovered',
    'ResizeGripActive', 'Tab', 'TabHovered', 'TabActive', 'TabUnfocused',
    'TabUnfocusedActive', 'PlotLines', 'PlotLinesHovered', 'PlotHistogram',
    'PlotHistogramHovered', 'TextSelectedBg', 'DragDropTarget', 'NavHighlight',
    'NavWindowingHighlight', 'NavWindowingDimBg', 'ModalWindowDimBg',
}
local STYLEVAR_NAMES = {
    'Alpha', 'WindowPadding', 'WindowRounding', 'WindowBorderSize', 'WindowMinSize',
    'WindowTitleAlign', 'ChildRounding', 'ChildBorderSize', 'PopupRounding',
    'PopupBorderSize', 'FramePadding', 'FrameRounding', 'FrameBorderSize',
    'ItemSpacing', 'ItemInnerSpacing', 'IndentSpacing', 'ScrollbarSize',
    'ScrollbarRounding', 'GrabMinSize', 'GrabRounding', 'TabRounding',
    'SelectableTextAlign', 'ButtonTextAlign',
}
local WINFLAGS = WINFLAGS_BITS
local COND = COND_BITS

-- ------------------------------------------------------------- регион -----
local function region() return st.stack[#st.stack] end

local function pushRegion(kind, id, x, y, w, h)
    st.depth = st.depth + 1
    local parentPath = (st.depth > 1 and st.stack[st.depth - 1].path) or ''
    st.stack[st.depth] = { kind = kind, id = id, x = x, y = y, w = w, h = h,
                           path = parentPath .. '/' .. kind .. ':' .. tostring(id),
                           cx = x, cy = y, maxx = x, maxy = y, imaxx = x, imaxy = y,
                           lineY = y,
                           -- у каждого окна ImGui свой DC.CursorPos и свои
                           -- CursorPosPrevLine: сохраняем состояние родителя
                           savedCursorX = st.cursor.x, savedCursorY = st.cursor.y,
                           savedPrevX = st.prevLineX, savedPrevY = st.prevLineY,
                           savedLastMaxX = st.lastItemMaxX }
    st.cursor.x, st.cursor.y = x, y
    st.prevLineX, st.prevLineY, st.lastItemMaxX = x, y, x
end

local function popRegion()
    local r = st.stack[st.depth]
    if r then
        st.cursor.x, st.cursor.y = r.savedCursorX, r.savedCursorY
        st.prevLineX = r.savedPrevX
        st.prevLineY = r.savedPrevY
        st.lastItemMaxX = r.savedLastMaxX
    end
    if r then
        -- содержимое не должно вылезать за регион
        -- при HorizontalScrollbar содержимое шире региона — это норма:
        -- ImGui показывает полосу прокрутки и обрезает видимую часть
        local hscroll = ((r.flags or 0) % 64) >= 32
        if r.maxx > r.x + r.w + 1.5 and not hscroll and not r.autoX then
            err(string.format('%s %s: содержимое шире региона на %.1f px (макс. X дал: %s, maxx=%.0f, край региона=%.0f)',
                              r.kind, tostring(r.id), r.maxx - (r.x + r.w),
                              tostring(r.maxxWhat), r.maxx, r.x + r.w))
        end
        -- для прокручиваемого child «содержимого больше, чем влезает» — норма:
        -- ImGui рисует только видимую часть и добавляет полосу прокрутки
        -- попапы и тултипы в ImGui автосized: регион растягивается под
        -- содержимое, поэтому «переполнения» у них не бывает
        if r.kind == 'popup' or r.kind == 'tooltip' then
            r.h = math.max(r.h, r.maxy - r.y)
            r.w = math.max(r.w, r.maxx - r.x)
        end
        if r.maxy > r.y + r.h + 1.5 and r.kind ~= 'child' and not r.autoY then
            err(string.format('%s %s: содержимое выше региона на %.1f px (макс. Y дал: %s)',
                              r.kind, tostring(r.id), r.maxy - (r.y + r.h), tostring(r.maxyWhat)))
        end
    end
    st.depth = st.depth - 1
    st.stack[st.depth + 1] = nil
    return r
end

local function markUsed(x, y, w, h, what)
    local r = region()
    if not r then return end
    if x + w > r.maxx then r.maxx = x + w; r.maxxWhat = what or '?' end
    if y + h > r.maxy then r.maxy = y + h; r.maxyWhat = what or '?' end
    -- ContentSize окна ImGui собирается ТОЛЬКО из элементов потока (ItemAdd):
    -- примитивы drawlist (текст, rectfill, круги) его не расширяют. Без этого
    -- автосайз попапа в моке «раздувался» невидимым текстом, а в игре меню
    -- остаётся полоской (баг v2.0.8).
    local drawOnly = what and (what:sub(1, 4) == 'text' or what:sub(1, 8) == 'rectfill'
                               or what:sub(1, 6) == 'circle')
    if not drawOnly then
        if x + w > r.imaxx then r.imaxx = x + w end
        if y + h > r.imaxy then r.imaxy = y + h end
    end
    if x < r.x - 1.5 and r.kind ~= 'tooltip' then
        err(string.format('элемент левее региона %s %s: x=%.1f', r.kind, tostring(r.id), x))
    end
end

-- Поток. Точная семантика Dear ImGui (ItemSize + ItemAdd), 1.76:
--   CursorPosPrevLine = (cursor.x + size.x, cursor.y)   -- правый край элемента
--   CursorPos.x       = window->Pos.x + Indent + ColumnsOffset   -- СБРОС к левому полю
--   CursorPos.y       = cursor.y + line_height + ItemSpacing.y
--   CursorMaxPos      = max(CursorMaxPos, prevLine.x / cursor.y - spacing)
-- То есть вертикальный стек собирается сам, а вправо курсор уходит ТОЛЬКО
-- через SameLine (который берёт x из CursorPosPrevLine). SetCursorScreenPos
-- CursorPosPrevLine не трогает.
local ITEM_SPACING_X, ITEM_SPACING_Y = 8, 6

local function flowItem(w, h)
    local x, y = st.cursor.x, st.cursor.y
    markUsed(x, y, w, h, st.markTag)
    local r = region()
    if st.dbgFlow then
        st.dbgFlow(string.format('flowItem(%.0f,%.0f) at (%.0f,%.0f) -> prevLineY=%.0f cursorY=%.0f',
            w, h, x, y, y, math.max(st.cursor.y, y + h) + ITEM_SPACING_Y))
    end
    st.prevLineX = x + w                 -- правый край элемента
    st.prevLineY = y                     -- ВЕРХ текущей строки, а не низ!
    st.lastItemMaxX = x + w
    st.cursor.x = r and r.x or x
    st.cursor.y = math.max(st.cursor.y, y + h) + ITEM_SPACING_Y
    if r then r.cx, r.cy = st.cursor.x, st.cursor.y; r.lineY = y end
    return x, y
end

local function recordItem(id, x, y, w, h)
    st.items[#st.items + 1] = { id = id, x = x, y = y, w = w, h = h, frame = st.frames }
end

-- ------------------------------------------------------------- imgui ------
local imgui = {}
mock.imgui = imgui

imgui.new = setmetatable({}, { __index = function(_, key)
    if key == 'bool' then
        return function(v) return { [0] = v and true or false } end
    elseif key == 'int' then
        return function(v) return { [0] = v or 0 } end
    elseif key == 'float' then
        return function(v) return { [0] = v or 0 } end
    end
    if key == 'ImWchar' then
        return setmetatable({}, { __index = function(_, sz)
            return function() return { n = sz } end
        end })
    end
    -- new.char[N] / new.int[N]
    local base
    if key == 'char' then base = function(n) return { [0] = 0, n = n } end
    elseif key == 'int' then base = function(n) return { [0] = 0, n = n } end
    else base = function(n) return { [0] = 0, n = n } end end
    return setmetatable({}, {
        __index = function(_, sz) return function() return base(sz) end end,
        __call  = function(_, sz) return base(sz) end,
    })
end })

imgui.ImVec2  = newVec2
imgui.ImVec4  = newVec4
imgui.Col     = enum('ImGuiCol_', COL_NAMES)
imgui.StyleVar = enum('ImGuiStyleVar_', STYLEVAR_NAMES)
imgui.WindowFlags = WINFLAGS
imgui.Cond    = COND
imgui.SelectableFlags = { None = 0 }
imgui.InputTextFlags  = { None = 0 }

imgui.lib = {}
imgui.GetDpiScale = function() return st.dpi end

imgui.GetIO = function()
    return {
        IniFilename = 'set-me',
        DisplaySize = newVec2(st.display.x, st.display.y),
        Fonts = {
            GetGlyphRangesCyrillic = function() return nil end,
            AddFontFromFileTTF = function(self, path, size, cfg, ranges)
                st.fontsAdded[#st.fontsAdded + 1] = { path = path, size = size }
                return { name = path, size = size }
            end,
            AddFontFromMemoryCompressedBase85TTF = function(self, data, size, cfg, ranges)
                st.fontsAdded[#st.fontsAdded + 1] = { base85 = true, size = size }
                return { name = 'base85', size = size }
            end,
            AddFontDefault = function(self) return { name = 'default' } end,
        },
        FontGlobalScale = 1,
    }
end
imgui.ImFontConfig = function() return { MergeMode = false, SizePixels = 0 } end
imgui.PushFont = function(f) st.fontDepth = st.fontDepth + 1 end
imgui.PopFont = function() st.fontDepth = st.fontDepth - 1
    if st.fontDepth < 0 then err('PopFont без PushFont'); st.fontDepth = 0 end end
imgui.GetFontSize = function() return st.fontH end
imgui.GetStyle = function()
    return { Colors = {}, ScaleAllSizes = function() end, WindowPadding = newVec2(8, 8) }
end

imgui.CalcTextSize = function(s)
    local w = measure(s)
    return newVec2(w, st.fontH)
end
imgui.GetColorU32 = function(v)
    if type(v) == 'number' then return v end
    if type(v) == 'table' and v.x then
        return math.floor((v.w or 1) * 255) * 16777216
             + math.floor((v.z or 0) * 255) * 65536
             + math.floor((v.y or 0) * 255) * 256
             + math.floor((v.x or 0) * 255)
    end
    err('GetColorU32 получил не ImVec4: ' .. type(v))
    return 0
end
imgui.ColorConvertFloat4ToU32 = function(v)
    if type(v) == 'number' then return v end
    if type(v) == 'table' and v.x then
        return math.floor((v.w or 1) * 255) * 16777216
             + math.floor((v.z or 0) * 255) * 65536
             + math.floor((v.y or 0) * 255) * 256
             + math.floor((v.x or 0) * 255)
    end
    err('GetColorU32 получил не ImVec4: ' .. type(v))
    return 0
end
imgui.GetColorU32Vec4 = function(v)
    if type(v) == 'number' then return v end
    if type(v) == 'table' and v.x then
        return math.floor((v.w or 1) * 255) * 16777216
             + math.floor((v.z or 0) * 255) * 65536
             + math.floor((v.y or 0) * 255) * 256
             + math.floor((v.x or 0) * 255)
    end
    err('GetColorU32 получил не ImVec4: ' .. type(v))
    return 0
end

-- ------------------------------------------------------------- окна -------
local function beginWindow(title, openRef, flags, kind)
    flags = flags or 0
    if st.dbgBegin then
        st.dbgBegin(string.format('Begin(%s) nextSize=%s', kind,
            st.nextSize and string.format('%.0fx%.0f', st.nextSize.x, st.nextSize.y) or 'nil'))
    end
    local size = st.nextSize or st.winSize
    if st.dbgSize then st.dbgSize(string.format('  Begin(%s) применяет %.0fx%.0f', kind, size.x, size.y)) end
    st.nextSize = nil
    local x, y = 40, 40
    local w, h = size.x, size.y
    st.winSize = { x = w, y = h }
    st.frames = st.frames + 1
    st.textsThisFrame = {}
    pushRegion(kind or 'window', title, x + 12, y + 30, w - 24, h - 42)
    return true
end

imgui.SetNextWindowSize = function(size, cond)
    if not size or not size.x then err('SetNextWindowSize без размера') return end
    if st.dbgSize then st.dbgSize(string.format('SetNextWindowSize %.0fx%.0f cond=%s', size.x, size.y, tostring(cond))) end
    st.nextSize = { x = size.x, y = size.y }
end
imgui.Begin = function(title, openRef, flags) return beginWindow(title, openRef, flags, 'window') end
imgui.End = function()
    local r = popRegion()
    if not r then err('End без Begin') return end
    st.lastWinContent = { w = r.w, h = r.h, x = r.x, y = r.y, maxx = r.maxx, maxy = r.maxy }
end

imgui.BeginChild = function(id, size, border, flags)
    st.childScroll = {}
    local r = region()
    if not r then err('BeginChild вне окна') return false end
    size = size or newVec2(r.w, 100)
    local w = (size.x == 0) and (r.x + r.w - st.cursor.x) or size.x
    local h = (size.y == 0) and (r.y + r.h - st.cursor.y) or size.y
    pushRegion('child', id, st.cursor.x, st.cursor.y, w, h)
    st.stack[st.depth].flags = flags or 0
    -- журнал child-регионов кадра: тесты проверяют, что HorizontalScrollbar
    -- (чёрная полоса-граббер) включается только при настоящем оверфлоу
    st.childLog[#st.childLog + 1] = { id = id, flags = flags or 0, frame = st.frames,
                                      x = st.cursor.x, y = st.cursor.y, w = w, h = h }
    return true
end
imgui.EndChild = function()
    local c = st.stack[st.depth]
    if not c then err('EndChild без BeginChild') return end
    local cx, cy, cw, ch = c.x, c.y, c.w, c.h
    popRegion()
    -- child — полноценный элемент потока родителя: курсор встаёт под него,
    -- а CursorPosPrevLine получает его прямоугольник. Благодаря этому
    -- SameLine(0,0) после EndChild ставит следующий child СПРАВА на той же
    -- строке (именно так собран сайдбар + тело нашего окна).
    local p = region()
    st.cursor.x = p and p.x or cx
    st.cursor.y = cy + ch
    st.prevLineX = cx + cw
    st.prevLineY = cy
    markUsed(cx, cy, cw, ch, 'child')
end

-- Dear ImGui 1.76, BeginPopupEx: размер попапа берётся из NextWindowData
-- (SetNextWindowSize), который Begin съедает при входе. ВАЖНО: закрытый попап
-- тоже съедает next-window-data (иначе размер «утечёт» в следующее окно).
-- Без явного размера попап автосайзится: кадр строится по ContentSize
-- ПРОШЛОГО кадра. Содержимое, чья ширина сама берётся из GetContentRegionAvail()
-- (кнопки наших меню), попап не расширяет — поэтому без SetNextWindowSize
-- ДО BeginPopup меню вырождается в тонкую вертикальную полоску (баг 26.09.2026,
-- исправлен в v2.0.8).
local POPUP_CHROME = 12   -- 2*WindowPadding(S5) + 2*PopupBorderSize(S1) при S=1
imgui.BeginPopup = function(id)
    local size = st.nextSize
    st.nextSize = nil
    if not st.popupOpen[id] then return false end
    local auto = st.popAuto[id]
    local chrome = POPUP_CHROME * (st.dpi or 1)
    local autoX = not (size and size.x > 0)
    local autoY = not (size and size.y > 0)
    local w = autoX and (auto and auto.w or 0) or (size.x - chrome)
    local h = autoY and (auto and auto.h or 0) or (size.y - chrome)
    pushRegion('popup', id, st.popX, st.popY, w, h)
    local r = st.stack[st.depth]
    r.autoX, r.autoY = autoX, autoY
    st.popupLog[#st.popupLog + 1] = { id = id, frame = st.frames, x = st.popX, y = st.popY,
                                      w = w, h = h, sized = not autoX }
    st.popY = st.popY + 40
    return true
end
imgui.EndPopup = function()
    local r = st.stack[st.depth]
    if not r or (r.kind ~= 'popup' and r.kind ~= 'modal') then
        err('EndPopup без BeginPopup') return
    end
    -- запоминаем содержимое: из него соберётся автосайз следующего кадра
    st.popAuto[r.id] = { w = math.max(r.imaxx - r.x, 0), h = math.max(r.imaxy - r.y, 0) }
    popRegion()
end
imgui.OpenPopup = function(id) st.popupOpen[id] = true end
imgui.CloseCurrentPopup = function()
    local r = region()
    if r and r.kind == 'popup' then st.popupOpen[r.id] = nil end
end
imgui.BeginPopupModal = function(title, openRef, flags)
    -- как BeginPopupEx: next-window-data съедается даже если модалка закрыта
    local size = st.nextSize or newVec2(400, 200)
    st.nextSize = nil
    if not st.popupOpen[title] then return false end
    pushRegion('modal', title, st.modalX, st.modalY, size.x - 16, size.y - 38)
    if openRef then openRef[0] = true end
    return true
end

-- ------------------------------------------------------------- курсор -----
imgui.GetCursorScreenPos = function() return newVec2(st.cursor.x, st.cursor.y) end
imgui.SetCursorScreenPos = function(p)
    if not p then err('SetCursorScreenPos(nil)') return end
    -- в ImGui CursorPosPrevLine при этом НЕ меняется
    st.cursor.x, st.cursor.y = p.x, p.y
end
imgui.GetWindowPos = function()
    local r = st.stack[1]
    return newVec2((r and r.x or 40) - st.padX, (r and r.y or 70) - st.padY - 30)
end
imgui.GetContentRegionAvail = function()
    local r = region()
    if not r then return newVec2(0, 0) end
    return newVec2(r.x + r.w - st.cursor.x, r.y + r.h - st.cursor.y)
end
imgui.Dummy = function(size)
    -- Dummy = ItemSize(size) + ItemAdd(bb, 0): место в потоке занимает,
    -- в том числе по X (CursorMaxPos.x растёт до правого края).
    flowItem(size.x, size.y)
end
imgui.Spacing = function() st.cursor.y = st.cursor.y + 6 end
imgui.Separator = function()
    local r = region()
    if r then r.lineY = st.cursor.y end
    if r then
        st.rects[#st.rects + 1] = { x = st.cursor.x, y = st.cursor.y, w = r.w, h = 1,
                                    kind = 'sep', frame = st.frames }
    end
    st.cursor.y = st.cursor.y + 7
end
-- ImGui::SameLine: cursor.x = window->Pos.x + offset_from_start_x,
-- cursor.y = CursorPosPrevLine.y.
-- ImGui::SameLine(offset_from_start_x, spacing):
--   x = offset>0 ? window->Pos.x + offset : CursorPosPrevLine.x + spacing
--   y = CursorPosPrevLine.y
imgui.SameLine = function(offset, spacing)
    local r = region()
    if not r then return end
    if st.dbgSame then
        st.dbgSame(string.format('SameLine(off=%s,sp=%s) prevLine=(%.0f,%.0f) cursor before=(%.0f,%.0f)',
            tostring(offset), tostring(spacing), st.prevLineX, st.prevLineY, st.cursor.x, st.cursor.y))
    end
    if offset and offset > 0 then
        st.cursor.x = r.x - st.padX + offset
    else
        st.cursor.x = st.prevLineX + (spacing or ITEM_SPACING_X)
    end
    st.cursor.y = st.prevLineY
end
imgui.Indent = function() end
imgui.SetTooltip = function(s) end
local TOOLTIP_ORIGIN = { x = 4000, y = 4000 }
-- Как в mimgui (cimgui): BeginTooltip — void, возвращает НИЧЕГО (nil).
-- Код скрипта обязан пережить nil: проверка «if not BeginTooltip()» оставила
-- бы окно тултипа открытым и съела бы остаток кадра (реальный баг v2.0.6).
imgui.BeginTooltip = function()
    pushRegion('tooltip', 'tip', TOOLTIP_ORIGIN.x, TOOLTIP_ORIGIN.y, 420, 160)
end
imgui.EndTooltip = function() popRegion() end
imgui.PushItemWidth = function(w) st.itemWidth = w end
imgui.PopItemWidth = function() st.itemWidth = nil end

-- ------------------------------------------------------------- отрисовка --
local function makeDrawList(kind)
    local dl = {}
    dl.AddText = function(self, pos, col, text)
        if type(pos) ~= 'table' then err('AddText: позиция не ImVec2') return end
        local w = measure(text)
        local r = region()
        st.texts[#st.texts + 1] = {
            x = pos.x, y = pos.y, w = w, h = st.fontH, text = text,
            frame = st.frames, region = kind, col = col,
            path = r and r.path or ('/' .. kind),
            clipped = dl._clipW,
        }
        -- текст, обрезанный клипом, физически не выходит за границу колонки
        markUsed(pos.x, pos.y, dl._clipW or w, st.fontH,
                 'text «' .. tostring(text):sub(1, 20) .. '»')
    end
    dl.AddRectFilled = function(self, a, b, col, rounding)
        st.rects[#st.rects + 1] = { x = a.x, y = a.y, w = b.x - a.x, h = b.y - a.y,
                                    kind = 'fill', frame = st.frames, col = col,
                                    rounding = rounding }
        markUsed(a.x, a.y, b.x - a.x, b.y - a.y, 'rectfill x=' .. string.format('%.0f..%.0f', a.x, b.x))
    end
    dl.AddRect = function(self, a, b, col, rounding, flags, thick)
        st.rects[#st.rects + 1] = { x = a.x, y = a.y, w = b.x - a.x, h = b.y - a.y,
                                    kind = 'stroke', frame = st.frames, col = col,
                                    rounding = rounding, thick = thick }
    end
    dl.AddRectFilledMultiColor = function(self, a, b, c1, c2, c3, c4)
        st.rects[#st.rects + 1] = { x = a.x, y = a.y, w = b.x - a.x, h = b.y - a.y,
                                    kind = 'grad', frame = st.frames, col = c1, col2 = c2 }
        markUsed(a.x, a.y, b.x - a.x, b.y - a.y, 'stroke')
    end
    dl.AddLine = function(self, a, b, col, thick)
        st.rects[#st.rects + 1] = { x = math.min(a.x, b.x), y = math.min(a.y, b.y),
                                    w = math.abs(b.x - a.x), h = math.abs(b.y - a.y),
                                    kind = 'line', frame = st.frames, col = col,
                                    ax = a.x, ay = a.y, bx = b.x, by = b.y, thick = thick }
    end
    dl.AddCircleFilled = function(self, c, r, col, seg)
        st.rects[#st.rects + 1] = { x = c.x - r, y = c.y - r, w = r * 2, h = r * 2,
                                    kind = 'circle', frame = st.frames, col = col,
                                    cx = c.x, cy = c.y, r = r }
        markUsed(c.x - r, c.y - r, r * 2, r * 2, 'circle')
    end
    dl.AddCircle = dl.AddCircleFilled
    dl.PushClipRect = function(self, a, b, intersect)
        dl._clip = { a.x, a.y, b.x, b.y }
        dl._clipW = b.x - a.x
    end
    dl.PopClipRect = function(self) dl._clip = nil; dl._clipW = nil end
    return dl
end

local windowDL = makeDrawList('window')
imgui.GetWindowDrawList = function() return windowDL end
imgui.GetForegroundDrawList = function() return makeDrawList('fg') end
imgui.GetBackgroundDrawList = function() return makeDrawList('bg') end

-- ------------------------------------------------------------- виджеты ---
imgui.Text = function(s)
    local w = measure(s)
    st.texts[#st.texts + 1] = { x = st.cursor.x, y = st.cursor.y, w = w, h = st.fontH,
                                text = s, frame = st.frames, region = 'flow' }
    flowItem(w, st.fontH)
end
imgui.TextColored = function(col, s) imgui.Text(s) end
imgui.Button = function(label, size)
    local vis = label:gsub('##.*$', '')
    local w = (size and size.x) or (measure(vis) + 16)
    local h = (size and size.y) or (st.fontH + 8)
    local x, y = flowItem(w, h)
    recordItem(label, x, y, w, h)
    if vis ~= '' then
        st.texts[#st.texts + 1] = { x = x + (w - measure(vis)) * 0.5, y = y + (h - st.fontH) * 0.5,
            w = measure(vis), h = st.fontH, text = vis, frame = st.frames,
            region = 'button', path = (region() and region().path) or '/button' }
    end
    return st.clicks[label] and true or false
end
imgui.SmallButton = function(label)
    local w = measure(label) + 12
    local x, y = flowItem(w, st.fontH + 6)
    recordItem(label, x, y, w, st.fontH + 6)
    return st.clicks[label] and true or false
end
imgui.InvisibleButton = function(id, size)
    local x, y = flowItem(size.x, size.y)
    recordItem(id, x, y, size.x, size.y)
    return st.clicks[id] and true or false
end
imgui.Selectable = function(label, selected, flags, size)
    local w = (size and size.x) or measure(label) + 8
    local h = (size and size.y) or st.fontH + 4
    local x, y = flowItem(w, h)
    recordItem(label, x, y, w, h)
    st.texts[#st.texts + 1] = { x = x + 4, y = y + 2, w = measure(label), h = st.fontH,
                                text = label, frame = st.frames, region = 'selectable' }
    return st.clicks[label] and true or false
end
-- Выпадающий список: BeginCombo рисует кнопку с превью и возвращает, раскрыт
-- ли он (в тестах раскрытие имитирует st.comboOpen[id], как popupOpen).
-- SetNextItemWidth задаёт ширину кнопки списка и сбрасывается после применения.
imgui.SetNextItemWidth = function(w) st.itemWidth = w end
imgui.BeginCombo = function(label, preview, flags)
    local vis = tostring(preview or '')
    local w = st.itemWidth or (measure(vis) + 24)
    local h = st.fontH + 8
    local x, y = flowItem(w, h)
    recordItem(label, x, y, w, h)
    st.texts[#st.texts + 1] = { x = x + 6, y = y + 4, w = measure(vis), h = st.fontH,
                                text = vis, frame = st.frames, region = 'combo' }
    st.itemWidth = nil
    return st.comboOpen[label] and true or false
end
imgui.EndCombo = function() end
imgui.SetItemDefaultFocus = function() end
imgui.Checkbox = function(label, ref)
    local vis = label:gsub('##.*$', '')
    local x, y = flowItem(st.fontH + 6 + measure(vis), st.fontH + 4)
    recordItem(label, x, y, st.fontH + 6 + measure(label), st.fontH + 4)
    if label ~= '' and not label:match('^##') then
        st.texts[#st.texts + 1] = { x = x + st.fontH + 6, y = y + 2, w = measure(label),
                                    h = st.fontH, text = label, frame = st.frames, region = 'cb' }
    end
    return false
end
imgui.InputText = function(label, buf, n, flags)
    local w = st.itemWidth or 200
    local h = st.fontH + 8
    local x, y = flowItem(w, h)
    recordItem(label, x, y, w, h)
    local v = st.inputs[label]
    if v then for i = 1, math.min(#v, n - 1) do buf[i - 1] = v:byte(i) end
              buf[math.min(#v, n - 1)] = 0 end
    return false
end
imgui.InputTextWithHint = function(label, hint, buf, n, flags)
    return imgui.InputText(label, buf, n, flags)
end
imgui.InputInt = function(label, ref, step, flags)
    local w = st.itemWidth or 100
    local x, y = flowItem(w, st.fontH + 8)
    recordItem(label, x, y, w, st.fontH + 8)
    return false
end
imgui.Columns = function() err('использован устаревший imgui.Columns') end
imgui.BeginTabBar = function() return true end
imgui.BeginTabItem = function() return false end

-- ------------------------------------------------------------- стиль -----
imgui.PushStyleColor = function(idx, col)
    if type(idx) ~= 'number' then err('PushStyleColor: не числовой индекс (' .. type(idx) .. ')') return end
    st.styleColorN = st.styleColorN + 1
end
imgui.PopStyleColor = function(n)
    n = n or 1
    st.styleColorN = st.styleColorN - n
    if st.styleColorN < 0 then err('PopStyleColor больше, чем Push') st.styleColorN = 0 end
end
imgui.PushStyleVar = function(idx, a, b)
    if type(idx) ~= 'number' then err('PushStyleVar: не числовой индекс (' .. type(idx) .. ')') return end
    st.styleVarN = st.styleVarN + 1
    -- WindowPadding влияет на начало области содержимого
    if idx == imgui.StyleVar.WindowPadding and type(a) == 'number' then
        st.padX, st.padY = a, (b or a)
    end
end
imgui.PopStyleVar = function(n)
    n = n or 1
    st.styleVarN = st.styleVarN - n
    if st.styleVarN < 0 then err('PopStyleVar больше, чем Push') st.styleVarN = 0 end
end

imgui.IsItemHovered = function()
    local it = st.items[#st.items]
    return it and st.hovers[it.id] and true or false
end
imgui.IsItemClicked = function(btn)
    local it = st.items[#st.items]
    return it and st.clicks[it.id] and true or false
end
imgui.GetWindowSize = function()
    local r = st.stack[1]
    return newVec2(r and r.w or 0, r and r.h or 0)
end
imgui.GetMousePos = function() return newVec2(st.mouse.x, st.mouse.y) end
imgui.IsMouseClicked = function(btn)
    return st.mouseClicked[btn or 0] and true or false
end
imgui.IsAnyItemHovered = function() return st.anyItemHovered and true or false
end

-- ------------------------------------------------------------- подписки --
mock.subscriptions = { init = {}, frame = {} }
imgui.OnInitialize = function(cb) mock.subscriptions.init[#mock.subscriptions.init + 1] = cb end
imgui.OnFrame = function(cond, cb) mock.subscriptions.frame[#mock.subscriptions.frame + 1] = { cond = cond, draw = cb } end

-- ------------------------------------------------------------- управление --
function mock.trace(tag)
    local r = region()
    st.trace[#st.trace + 1] = string.format('%-28s cursor=(%.0f,%.0f) region=%s %s [%.0f,%.0f %.0fx%.0f]',
        tag, st.cursor.x, st.cursor.y, r and r.kind or '-', tostring(r and r.id),
        r and r.x or 0, r and r.y or 0, r and r.w or 0, r and r.h or 0)
end

function mock.reset()
    st.frames = 0; st.depth = 0; st.stack = {}
    st.cursor = { x = 0, y = 0 }
    st.prevLineX, st.prevLineY, st.lastItemMaxX = 0, 0, 0
    st.fontsAdded = {}
    st.fontDepth = 0
    st.nextSize = nil; st.styleColorN = 0; st.styleVarN = 0
    st.texts = {}; st.rects = {}; st.items = {}; st.errors = {}
    st.childLog = {}
    st.popupLog = {}; st.popAuto = {}; st.popY = 3000
    st.popupOpen = {}; st.clicks = {}; st.hovers = {}; st.inputs = {}
    st.comboOpen = {}
    st.trace = {}
    st.winSize = { x = 800, y = 600 }
end

function mock.frame(opts)
    opts = opts or {}
    st.clicks = opts.clicks or {}
    st.hovers = opts.hovers or {}
    st.inputs = opts.inputs or {}
    local startText = #st.texts
    for _, sub in ipairs(mock.subscriptions.frame) do
        if sub.cond() then sub.draw({ HideCursor = false, LockPlayer = false }) end
    end
    if st.depth ~= 0 then
        err(string.format('незакрытые Begin/End: глубина %d', st.depth))
        st.depth = 0; st.stack = {}
    end
    if st.styleColorN ~= 0 then err('несбалансированный PushStyleColor: ' .. st.styleColorN) end
    if st.styleVarN ~= 0 then err('несбалансированный PushStyleVar: ' .. st.styleVarN) end
    return { from = startText + 1, to = #st.texts, win = st.winSize,
             content = st.lastWinContent }
end

function mock.runInit()
    for _, cb in ipairs(mock.subscriptions.init) do cb() end
end

return mock
