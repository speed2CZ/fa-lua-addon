local files        = require 'files'
local furi         = require 'file-uri'
local exportEnv    = require 'export-env'
local tableHints   = require 'table-hints'
local classSupport = require 'class-support'
local forInPairs   = require 'for-in-pairs'

--- mergeDiff (script/string-merger.lua) sorts diffs by `start`, and table.sort isn't stable
--- for ties, so two diffs that both target the same position race: which one "wins" is
--- undefined and can corrupt output (verified by hand against mergeDiff's cur/buf bookkeeping).
--- Since we run four independent scanners into one diff list, collapse any diffs that land on
--- the same `start` into one before returning, instead of trying to keep each scanner from
--- ever colliding with the others.
---@param diffs fa.diff[]
---@return fa.diff[]
local function mergeSameStartDiffs(diffs)
    local groups, order = {}, {}
    for _, d in ipairs(diffs) do
        if not groups[d.start] then
            groups[d.start] = {}
            order[#order + 1] = d.start
        end
        table.insert(groups[d.start], d)
    end

    local merged = {}
    for _, start in ipairs(order) do
        local group = groups[start]
        if #group == 1 then
            merged[#merged + 1] = group[1]
        else
            local finish = start - 1
            local text = {}
            for _, d in ipairs(group) do
                if d.finish >= start then
                    finish = math.max(finish, d.finish)
                end
                text[#text + 1] = d.text
            end
            merged[#merged + 1] = { start = start, finish = finish, text = table.concat(text) }
        end
    end
    return merged
end

-- FA's Lua preprocessor uses leading `#` for macro directives that aren't valid standard
-- Lua syntax; blank them out (byte-for-byte, so all positions stay stable) before parsing.
-- FA modules also don't `return {...}`: a file's bare top-level assignments/functions (no
-- `local` keyword) ARE its exports, resolved at runtime by import(). We reproduce that here
-- as real Lua - forward-declaring every such name as a `local` at the top of the file and
-- appending a real `return {...}` at the bottom - rather than patching the AST after parsing,
-- because forward/mutual references between them only resolve correctly if the *parser* sees
-- real `local`s; a post-parse transform is too late to change how names already resolved.
-- Table constructors can also start with `{&15 &4}`-style preallocation hints, which aren't
-- valid Lua 5.1 syntax at all - table-hints.lua blanks those out the same way. FA classes
-- (`Name = ClassFn(Bases...) { specs }`) don't register their methods as class members unless
-- the `ClassFn(...)` wrapper is stripped down to a plain `Name = { specs }` first - see
-- class-support.lua. And `for a, b in someTable do` (no pairs()/ipairs()) is valid syntax
-- SupCom's engine gives pairs()-like semantics to, but LuaLS can't type it without an actual
-- call to read a signature off of - for-in-pairs.lua rewrites it to `in pairs(someTable) do`.
---@param  uri  string
---@param  text string
---@return nil|fa.diff[]
function OnSetText(uri, text)
    local diffs = {}
    for pos in text:gmatch '()#' do
        diffs[#diffs + 1] = {
            start  = pos,
            finish = pos,
            text   = '--',
        }
    end

    for _, diff in ipairs(tableHints.stripHints(text)) do
        diffs[#diffs + 1] = diff
    end

    for _, diff in ipairs(classSupport.stripWrappers(text)) do
        diffs[#diffs + 1] = diff
    end

    for _, diff in ipairs(forInPairs.wrapBareIterators(text)) do
        diffs[#diffs + 1] = diff
    end

    local exports, hasTopReturn = exportEnv.scan(text)
    if #exports > 0 and not hasTopReturn then
        -- Every name here becomes a real `local`, and Lua 5.1 caps a chunk at 200 active
        -- locals - splitting into more `local` statements doesn't help, the cap is on the
        -- total, not per-statement. A handful of FA files (EffectTemplates.lua: 869 top-level
        -- table defs, verified) are themselves already past that, so above a safe threshold we
        -- skip the local-ification and return plain globals instead - import() consumers still
        -- resolve correctly, we just lose the in-file forward-reference benefit for that one
        -- file, which barely matters for parallel data tables (as opposed to mutually-calling
        -- functions, which is what the local-ification is really for).
        local MAX_LOCALIZED_EXPORTS = 150
        if #exports <= MAX_LOCALIZED_EXPORTS then
            diffs[#diffs + 1] = {
                start  = 1,
                finish = 0,
                text   = 'local ' .. table.concat(exports, ', ') .. '\n',
            }
        end
        local fields = {}
        for _, name in ipairs(exports) do
            fields[#fields + 1] = ('%s = %s'):format(name, name)
        end
        diffs[#diffs + 1] = {
            start  = #text + 1,
            finish = #text,
            text   = '\nreturn { ' .. table.concat(fields, ', ') .. ' }\n',
        }
    end

    return mergeSameStartDiffs(diffs)
end

-- import()/doscript() take root-relative paths like '/lua/sim/Weapon.lua', optionally without
-- the extension and with inconsistent case/slash direction. Only take over resolution for
-- names that look like a path; anything else (plain `require 'foo'`) falls through untouched
-- by returning nil.
---@param uri  string
---@param name string
---@param suri string
---@return uri[]|nil
function ResolveRequire(uri, name, suri)
    if not name:find('[/\\]') then
        return nil
    end

    local target = name:gsub('\\', '/'):gsub('^/', ''):lower()
    if not target:match('%.lua$') then
        target = target .. '.lua'
    end
    local suffix = '/' .. target

    local results = {}
    for fileUri in files.eachFile(uri) do
        local filePath = furi.decode(fileUri)
        if filePath then
            local normalized = filePath:gsub('\\', '/'):lower()
            if normalized:sub(-#suffix) == suffix then
                results[#results + 1] = fileUri
            end
        end
    end

    if #results > 0 then
        return results
    end
    return nil
end
