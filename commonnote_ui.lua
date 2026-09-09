-- commonnote_ui.lua
-- Unified commonnote Import/Export Plugin for VOCALOID3 & VOCALOID4

function manifest()
    return {
        name          = "commonnote",
        comment       = "Import/export for the original commonnote format by ExpressiveLabs",
        author        = "Sashian",
        pluginID      = "{5B3E9A21-7C4D-4F1A-9E2B-3D6C8F1A4B7E}",
        pluginVersion = "2.0.0.0",
        apiVersion    = "3.0.1.0"
    }
end

-- Localizations
local L = {
    -- Main menu
    main_title     = "commonnote",
    main_prompt    = "Select an operation:",
    opt_export_all = "Export All Notes",
    opt_export_range = "Export Selected Range",
    opt_export_phonemes_all = "Export All VOCALOID Phonemes",
    opt_export_phonemes_range = "Export Selected Range Phonemes",
    opt_import_all = "Import commonnote (Append)",
    opt_import_replace = "Import commonnote (Replace)",
    opt_cancel     = "Cancel",

    -- Export
    export_confirm    = "This will export {count} notes to the original commonnote format and copy to clipboard.",
    export_success    = "✅ Export completed\n\n• Notes exported: {count}\n• Resolution: {resolution}\n\nData copied to clipboard.",
    export_range_info = "Selected range: {start} - {end} ticks",
    
    -- Import
    import_confirm    = "Import commonnote data from clipboard?\n\nStart tick: {start}",
    import_success    = "✅ Import completed\n\n• Notes imported: {count}\n• Start tick: {start}",
    import_warning    = "⚠️ The part already contains notes. They will be replaced.",
    import_error      = "Error: {msg}",
    
    -- Messages
    no_notes      = "❌ No notes found.",
    no_clipboard  = "❌ No commonnote data found in clipboard.",
    dll_error     = "❌ Could not load commonnote.dll",
    cancel        = "Operation cancelled."
}

-- Core utility
local Core = {}

function Core.normalizeLabel(label)
    local value = tostring(label or "")
    value = value:gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" or value == "-" or value == "+" then
        return "-"
    end
    return value
end

function Core.clampPitch(value)
    local pitch = tonumber(value) or 0
    if pitch < 0 then return 0 end
    if pitch > 127 then return 127 end
    return pitch
end

function Core.convertTick(value, sourceResolution, targetResolution)
    local source = tonumber(sourceResolution) or 0
    local target = tonumber(targetResolution) or 0
    local tick = tonumber(value) or 0
    if source <= 0 or target <= 0 then
        return math.floor(tick + 0.5)
    end
    local factor = target / source
    return math.floor(tick * factor + 0.5)
end

function Core.maxEndTick(notes)
    local last = 0
    for _, note in ipairs(notes or {}) do
        if note and note.posTick and note.durTick then
            last = math.max(last, note.posTick + note.durTick)
        end
    end
    return last
end

function Core.updateMusicalPartPlayTime(requiredTick)
    local retCode, musicalPart = VSGetMusicalPart()
    if retCode ~= 1 then
        return false
    end
    if (musicalPart.playTime or 0) < requiredTick then
        musicalPart.playTime = requiredTick
        return VSUpdateMusicalPart(musicalPart) == 1
    end
    return true
end

function Core.createNoteFromCommonNote(cn_note, posTick, durTick)
    local lyric = Core.normalizeLabel(cn_note.label)
    local phonemes = lyric
    if phonemes == "-" then
        phonemes = "a"
    end
    return {
        posTick  = posTick,
        durTick  = durTick,
        noteNum  = Core.clampPitch(cn_note.pitch),
        velocity = 64,
        lyric    = lyric,
        phonemes = phonemes,
        phLock   = 0
    }
end

-- ============================================================
-- CSV parsing
-- ============================================================
local function parse_csv_line(line)
    local values = {}
    local current = ""
    local in_quotes = false
    local i = 1
    while i <= #line do
        local ch = line:sub(i, i)
        if ch == '"' then
            if in_quotes and i + 1 <= #line and line:sub(i + 1, i + 1) == '"' then
                current = current .. '"'
                i = i + 2
            else
                in_quotes = not in_quotes
                i = i + 1
            end
        elseif ch == ',' and not in_quotes then
            table.insert(values, current)
            current = ""
            i = i + 1
        else
            current = current .. ch
            i = i + 1
        end
    end
    table.insert(values, current)
    return values
end

local function parse_commonnote_ini(ini_str)
    local result = { notes = {} }
    local lines = {}
    for line in ini_str:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end
    if #lines < 2 then
        return nil, "Invalid INI format: too few lines"
    end
    local res = lines[1]:match("^resolution=(%d+)$")
    if not res then
        return nil, "Missing 'resolution' in first line"
    end
    result.resolution = tonumber(res)
    local headers = parse_csv_line(lines[2])
    if #headers < 4 then
        return nil, "Insufficient headers"
    end
    for i = 3, #lines do
        local values = parse_csv_line(lines[i])
        if #values >= 4 then
            local note = {
                start  = tonumber(values[1]),
                length = tonumber(values[2]),
                pitch  = tonumber(values[3]),
                label  = values[4]
            }
            if note.start and note.length and note.pitch then
                table.insert(result.notes, note)
            end
        end
    end
    return result
end

-- ============================================================
-- Export functions
-- ============================================================
local function getAllNotes()
    local notes = {}
    VSSeekToBeginNote()
    local retCode, note = VSGetNextNote()
    while retCode == 1 do
        table.insert(notes, note)
        retCode, note = VSGetNextNote()
    end
    return notes
end

local function getNotesInRange(beginTick, endTick)
    local notes = {}
    local rangeStart = math.min(beginTick or 0, endTick or 0)
    local rangeEnd = math.max(beginTick or 0, endTick or 0)

    VSSeekToBeginNote()
    local retCode, note = VSGetNextNote()
    while retCode == 1 do
        local noteStart = note.posTick
        local noteEnd = note.posTick + (note.durTick or 0)
        if noteStart >= rangeStart and noteStart < rangeEnd then
            table.insert(notes, note)
        elseif noteStart == rangeStart and noteEnd > rangeStart and noteEnd <= rangeEnd then
            table.insert(notes, note)
        end
        retCode, note = VSGetNextNote()
    end
    return notes
end

local function exportNotes(notes, scriptDir, exportMode)
    if #notes == 0 then
        VSMessageBox(L.no_notes, 0)
        return false
    end
    
    local resolution = VSGetResolution()
    local firstNotePos = notes[1].posTick
    local notesData = {}
    for _, note in ipairs(notes) do
        local labelValue
        if exportMode == "phonemes" then
            labelValue = note.phonemes or note.lyric or ""
        else
            labelValue = note.lyric or ""
        end
        table.insert(notesData, {
            start  = note.posTick - firstNotePos,
            length = note.durTick,
            pitch  = note.noteNum,
            label  = Core.normalizeLabel(labelValue)
        })
    end
    
    local dllPath = (scriptDir and scriptDir ~= "") and (scriptDir .. "commonnote.dll") or "commonnote.dll"
    local rust_dll = package.loadlib(dllPath, "process_notes_table_lua")
    if not rust_dll then
        VSMessageBox(L.dll_error, 0)
        return false
    end
    
    local intermediate = {
        resolution = resolution,
        notes      = notesData
    }
    
    local success = rust_dll(intermediate)
    if success == 1 then
        local msg = L.export_success
            :gsub("{count}", #notes)
            :gsub("{resolution}", resolution)
        VSMessageBox(msg, 0)
        return true
    else
        VSMessageBox(L.export_error:gsub("{msg}", "Rust processing failed"), 0)
        return false
    end
end

-- ============================================================
-- Import functions
-- ============================================================
local function importNotes(ini_str, startTick, replaceExisting)
    local data, err = parse_commonnote_ini(ini_str)
    if not data then
        VSMessageBox(L.import_error:gsub("{msg}", tostring(err)), 0)
        return false
    end
    
    local cn_resolution = data.resolution
    local notes_data = data.notes
    if #notes_data == 0 then
        VSMessageBox(L.no_clipboard, 0)
        return false
    end
    
    local seq_resolution = VSGetResolution()
    local factor = 1
    if cn_resolution ~= seq_resolution then
        factor = seq_resolution / cn_resolution
        local warn = "⚠️ Resolution mismatch!\n\nSource: " .. cn_resolution .. "\nTarget: " .. seq_resolution .. "\n\nNotes will be scaled."
        VSMessageBox(warn, 0)
    end
    
    -- Get existing notes (plain notes, matching VSRemoveNote's expected pairing)
    local existingNotes = {}
    VSSeekToBeginNote()
    while true do
        local retCode, note = VSGetNextNote()
        if retCode == 0 then break end
        table.insert(existingNotes, note)
    end
    
    -- If replacing, confirm and delete
    if replaceExisting and #existingNotes > 0 then
        local answer = VSMessageBox(L.import_warning, 4)
        if answer ~= 6 then
            return false
        end
        for _, note in ipairs(existingNotes) do
            VSRemoveNote(note)
        end
    end
    
    -- Insert new notes
    local inserted = 0
    local maxEndTick = 0
    for _, note in ipairs(notes_data) do
        local pos = startTick + math.floor(note.start * factor + 0.5)
        local dur = math.floor(note.length * factor + 0.5)
        local pitch = Core.clampPitch(note.pitch)
        if pos >= 0 and dur > 0 and pitch >= 0 and pitch <= 127 then
            local newNote = Core.createNoteFromCommonNote({ label = note.label, pitch = pitch }, pos, dur)
            local retCode = VSInsertNote(newNote)
            if retCode == 1 then
                inserted = inserted + 1
                maxEndTick = math.max(maxEndTick, pos + dur)
            end
        end
    end
    
    if maxEndTick > 0 then
        Core.updateMusicalPartPlayTime(maxEndTick)
    end
    
    local msg = L.import_success
        :gsub("{count}", inserted)
        :gsub("{start}", startTick)
    VSMessageBox(msg, 0)
    return true
end

-- ============================================================
-- UI Helper: Show main menu dialog
-- ============================================================
local function showMainMenu()
    local field = {
        name = "operation",
        caption = L.main_prompt,
        initialVal = L.opt_export_all .. "," .. L.opt_export_range .. "," .. L.opt_export_phonemes_all .. "," .. L.opt_export_phonemes_range .. "," .. L.opt_import_all .. "," .. L.opt_import_replace,
        type = 4 -- FT_STRING_LIST (combo box)
    }
    VSDlgSetDialogTitle(L.main_title)
    VSDlgAddField(field)
    
    local ret = VSDlgDoModal()
    if ret ~= 1 then return nil end
    
    local ok, value = VSDlgGetStringValue("operation")
    if not ok then return nil end
    
    if value == L.opt_export_all then
        return "export_all"
    elseif value == L.opt_export_range then
        return "export_range"
    elseif value == L.opt_export_phonemes_all then
        return "export_phonemes_all"
    elseif value == L.opt_export_phonemes_range then
        return "export_phonemes_range"
    elseif value == L.opt_import_all then
        return "import_all"
    elseif value == L.opt_import_replace then
        return "import_replace"
    end
    return nil
end

-- ============================================================
-- Main entry point
-- ============================================================
function main(processParam, envParam)
    local scriptDir = (envParam and envParam.scriptDir) or ""
    if scriptDir == "" then
        VSMessageBox("Error: scriptDir not available.", 0)
        return 1
    end
    
    -- Show main menu
    local mode = showMainMenu()
    if not mode then
        return 0
    end
    
    if mode == "export_all" then
        -- Confirm
        local ret = VSMessageBox("Export all notes to commonnote format?", 4)
        if ret ~= 6 then return 0 end
        
        local notes = getAllNotes()
        if #notes == 0 then
            VSMessageBox(L.no_notes, 0)
            return 0
        end
        
        exportNotes(notes, scriptDir, "lyric")
        
    elseif mode == "export_range" then
        -- Use selection range
        local beginTick = processParam.beginPosTick
        local endTick = processParam.endPosTick
        
        local msg = string.format("%s\n\nSelected range: %d - %d ticks", L.export_range_info, beginTick, endTick)
        local ret = VSMessageBox(msg, 4)
        if ret ~= 6 then return 0 end
        
        local notes = getNotesInRange(beginTick, endTick)
        if #notes == 0 then
            VSMessageBox(L.no_notes, 0)
            return 0
        end
        
        exportNotes(notes, scriptDir, "lyric")

    elseif mode == "export_phonemes_all" then
        local ret = VSMessageBox("Export all VOCALOID phonemes to commonnote format?", 4)
        if ret ~= 6 then return 0 end

        local notes = getAllNotes()
        if #notes == 0 then
            VSMessageBox(L.no_notes, 0)
            return 0
        end

        exportNotes(notes, scriptDir, "phonemes")

    elseif mode == "export_phonemes_range" then
        local beginTick = processParam.beginPosTick
        local endTick = processParam.endPosTick

        local msg = string.format("%s\n\nSelected range: %d - %d ticks", L.export_range_info, beginTick, endTick)
        local ret = VSMessageBox(msg, 4)
        if ret ~= 6 then return 0 end

        local notes = getNotesInRange(beginTick, endTick)
        if #notes == 0 then
            VSMessageBox(L.no_notes, 0)
            return 0
        end

        exportNotes(notes, scriptDir, "phonemes")
        
    elseif mode == "import_all" then
        -- Ask for start tick
        local field = {
            name = "startTick",
            caption = "Start tick (0 = beginning of part):",
            initialVal = tostring(processParam.beginPosTick),
            type = 0
        }
        VSDlgSetDialogTitle("Commonnote Import")
        VSDlgAddField(field)
        local ret = VSDlgDoModal()
        if ret ~= 1 then return 0 end
        
        local ok, startTick = VSDlgGetIntValue("startTick")
        if not ok then return 0 end
        
        -- Load Rust DLL for clipboard
        local rust_dll = package.loadlib(scriptDir .. "commonnote.dll", "get_commonnote_from_clipboard")
        if not rust_dll then
            VSMessageBox(L.dll_error, 0)
            return 1
        end
        
        local ok2, ini_str = rust_dll()
        if not ok2 then
            VSMessageBox(L.import_error:gsub("{msg}", ini_str or "unknown error"), 0)
            return 1
        end
        
        importNotes(ini_str, startTick, false)
        
    elseif mode == "import_replace" then
        -- Ask for start tick
        local field = {
            name = "startTick",
            caption = "Start tick (0 = beginning of part):",
            initialVal = tostring(processParam.beginPosTick),
            type = 0
        }
        VSDlgSetDialogTitle("Commonnote Import (Replace)")
        VSDlgAddField(field)
        local ret = VSDlgDoModal()
        if ret ~= 1 then return 0 end
        
        local ok, startTick = VSDlgGetIntValue("startTick")
        if not ok then return 0 end
        
        -- Load Rust DLL for clipboard
        local rust_dll = package.loadlib(scriptDir .. "commonnote.dll", "get_commonnote_from_clipboard")
        if not rust_dll then
            VSMessageBox(L.dll_error, 0)
            return 1
        end
        
        local ok2, ini_str = rust_dll()
        if not ok2 then
            VSMessageBox(L.import_error:gsub("{msg}", ini_str or "unknown error"), 0)
            return 1
        end
        
        importNotes(ini_str, startTick, true)
    end
    
    return 0
end