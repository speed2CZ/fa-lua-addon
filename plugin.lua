local files      = require 'files'
local furi       = require 'file-uri'
local exportEnv  = require 'export-env'

-- FA's Lua preprocessor uses leading `#` for macro directives that aren't valid standard
-- Lua syntax; blank them out (byte-for-byte, so all positions stay stable) before parsing.
-- FA modules also don't `return {...}`: a file's bare top-level assignments/functions (no
-- `local` keyword) ARE its exports, resolved at runtime by import(). We reproduce that here
-- as real Lua - forward-declaring every such name as a `local` at the top of the file and
-- appending a real `return {...}` at the bottom - rather than patching the AST after parsing,
-- because forward/mutual references between them only resolve correctly if the *parser* sees
-- real `local`s; a post-parse transform is too late to change how names already resolved.
---@param  uri  string
---@param  text string
---@return nil|diff[]
function OnSetText(uri, text)
    local diffs = {}
    for pos in text:gmatch '()#' do
        diffs[#diffs + 1] = {
            start  = pos,
            finish = pos,
            text   = '--',
        }
    end

    local exports, hasTopReturn = exportEnv.scan(text)
    if #exports > 0 and not hasTopReturn then
        -- mergeDiff sorts all diffs by `start`, and table.sort isn't stable for ties, so a
        -- plain `{start=1, finish=0}` insertion here would race the '#' diff above whenever
        -- the file's first byte is itself '#' (undefined which one wins -> corrupted output).
        -- Merge into that diff instead of adding a second one at the same position.
        local prependText = 'local ' .. table.concat(exports, ', ') .. '\n'
        if diffs[1] and diffs[1].start == 1 then
            diffs[1].text = prependText .. diffs[1].text
        else
            table.insert(diffs, 1, {
                start  = 1,
                finish = 0,
                text   = prependText,
            })
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

    return diffs
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
