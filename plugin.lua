-- Orchestrates every SupCom-Lua-to-standard-Lua translation this addon performs, and wires the
-- addon into LuaLS as a workspace plugin.
--
-- Each dialect quirk (comments, table hints, classes, bare iteration, the implicit module
-- system, mod hook files) has its own scanner module, each returning a list of
-- `{start, finish, text}` diffs against the *original* source text - see that module's own
-- header for what it solves and why. `OnSetText` below runs every scanner over each file LuaLS
-- opens, merges their diffs into one list, and hands LuaLS the merged result to parse instead
-- of the raw file. Merging independently-computed diffs safely - two scanners agreeing on the
-- same position, or one scanner's diff accidentally overlapping another's - turned out to need
-- real care of its own; see `mergeSameStartDiffs` and `resolveOverlappingDiffs` below.
-- `ResolveRequire` separately teaches LuaLS to follow FA's root-relative `import()`/
-- `doscript()` paths.

local files        = require 'files'
local furi         = require 'file-uri'
local smerger      = require 'string-merger'
local exportEnv    = require 'export-env'
local tableHints   = require 'table-hints'
local classSupport = require 'class-support'
local forInPairs   = require 'for-in-pairs'
local hookFiles    = require 'hook-files'
local hashComments = require 'hash-comments'

--- Finds every file in the workspace whose path ends with `/<relPath>` (extension-optional,
--- case-insensitive) - shared by ResolveRequire and the hook-file target lookup below.
---@param uri     string
---@param relPath string
---@return string[]
local function findUrisBySuffix(uri, relPath)
    local target = relPath:gsub('\\', '/'):gsub('^/', ''):lower()
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
    return results
end

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

--- mergeDiff tracks a single `cur` position through diffs *sorted by `start`*, advancing
--- `cur = diff.finish + 1` after each - it assumes diffs never overlap in range.
--- mergeSameStartDiffs only ever collapsed diffs sharing the exact same `start`; it never
--- handled two diffs with *different* starts whose ranges overlap (e.g. class-support.lua's
--- diff blanking out an entire `ClassFn(Bases...)` call, and a nested diff landing on a
--- base-class argument that happens to reference another export of the same file - a real
--- FA pattern: a file defining a base class, then deriving another class from it). When that
--- happens, the nested diff's `finish` is *less* than what `cur` already advanced to from the
--- wider diff, so `cur` moves backward - the next `text:sub(cur, nextDiff.start - 1)` then
--- re-emits already-consumed source text, corrupting everything processed afterward in that
--- file (confirmed by hand against mergeDiff's cur/buf bookkeeping, and reproduced/fixed in
--- the scratchpad Python port before writing this).
--- Resolves this by dropping any diff whose `start` falls at or before the highest `finish`
--- an already-accepted diff claimed - safe unconditionally, since that range's original
--- content is being replaced by the wider diff regardless, so a nested insertion inside it is
--- always moot, never wanted. Call this *after* mergeSameStartDiffs, so same-start collisions
--- (e.g. a `---@class` doc and an `M.` prefix landing on the same position) still combine into
--- one diff first, in append order, before this resolves genuinely overlapping ranges.
---@param diffs fa.diff[]
---@return fa.diff[]
local function resolveOverlappingDiffs(diffs)
    table.sort(diffs, function(a, b) return a.start < b.start end)
    local result = {}
    local claimedUntil = 0
    for _, d in ipairs(diffs) do
        if d.start > claimedUntil then
            result[#result + 1] = d
            claimedUntil = math.max(claimedUntil, d.finish)
        end
    end
    return result
end

--- Runs every scanner over `text` (hash-comments, table-hints, class-support, for-in-pairs, in
--- that order - see each module's own header for what it fixes), then export-env's module-wrap
--- pass, then merges everything into one diff list for LuaLS to apply. Order only matters where
--- two scanners could plausibly touch the same text; otherwise each runs independently against
--- the *original* `text`, never against another scanner's output.
---@param  uri  string
---@param  text string
---@return nil|fa.diff[]
function OnSetText(uri, text)
    -- Computed up front, before classSupport runs, because it needs to know which bare names
    -- are this file's own exports - see the comment on the base-class keep-alive inside
    -- class-support.lua's stripWrappers for why.
    local exports, hasTopReturn, topLevelLocalCount, unsafeNames = exportEnv.scan(text)
    local safeNames = {}
    local unsafeList = {}
    for _, name in ipairs(exports) do
        if unsafeNames[name] then
            unsafeList[#unsafeList + 1] = name
        else
            safeNames[name] = true
        end
    end

    local diffs = {}
    for _, diff in ipairs(hashComments.stripHashComments(text)) do
        diffs[#diffs + 1] = diff
    end

    for _, diff in ipairs(tableHints.stripHints(text)) do
        diffs[#diffs + 1] = diff
    end

    for _, diff in ipairs(classSupport.stripWrappers(text, safeNames)) do
        diffs[#diffs + 1] = diff
    end

    for _, diff in ipairs(forInPairs.wrapBareIterators(text)) do
        diffs[#diffs + 1] = diff
    end

    -- Hook files (MODS.LUA:150-198): the mod's file is concatenated to the END of the target
    -- at runtime, sharing its top-level scope. We reproduce that by prepending the target's
    -- content here. Deliberately use the target's RAW text (files.getOriginText), not its own
    -- transformed text: the target's own export-env pass would have turned its top-level names
    -- into locals scoped to nothing but itself, plus appended a `return {...}` - concatenated
    -- in front of the hook's own code, a mid-chunk `return` is an actual syntax error. Raw text
    -- keeps the target's names as the real globals the hook is supposed to see, and we still
    -- run the (non-scope-changing) table-hints/class-support/for-in-pairs passes over it so
    -- `Cls = Class(oldCls) {...}`-style overrides still get proper class typing.
    local hookTarget = hookFiles.findTarget(uri, text)
    if hookTarget then
        local targetUri
        for _, candidate in ipairs(findUrisBySuffix(uri, hookTarget)) do
            if candidate ~= uri then
                targetUri = candidate
                break
            end
        end
        local targetText = targetUri and files.getOriginText(targetUri)
        if targetText then
            -- script/encoder/init.lua's decode() is a no-op for utf8, so a target file with a
            -- literal UTF-8 BOM (confirmed on loc/*/strings_db.lua, e.g.) keeps those 3 raw
            -- bytes in files.getOriginText's result. Harmless at a real position-1 file start
            -- (editors strip it before it ever reaches didOpen), but here it'd land mid-stream,
            -- right where the target's first real line is expected - not valid Lua syntax
            -- anywhere but the very start of a file, so it has to go.
            targetText = targetText:gsub('^\239\187\191', '')
            local targetDiffs = {}
            for _, d in ipairs(hashComments.stripHashComments(targetText)) do
                targetDiffs[#targetDiffs + 1] = d
            end
            for _, d in ipairs(tableHints.stripHints(targetText)) do
                targetDiffs[#targetDiffs + 1] = d
            end
            for _, d in ipairs(classSupport.stripWrappers(targetText)) do
                targetDiffs[#targetDiffs + 1] = d
            end
            for _, d in ipairs(forInPairs.wrapBareIterators(targetText)) do
                targetDiffs[#targetDiffs + 1] = d
            end
            local transformedTarget = smerger.mergeDiff(targetText, resolveOverlappingDiffs(mergeSameStartDiffs(targetDiffs)))
            diffs[#diffs + 1] = {
                start  = 1,
                finish = 0,
                text   = '---@diagnostic disable\n' .. transformedTarget .. '\n---@diagnostic enable\n',
            }
        end
    end

    if #exports > 0 and not hasTopReturn then
        -- Turn the file into a classic module: `local M = {}`, every export becomes
        -- `M.Name = ...`, `return M`. Unlike forward-declared locals, `M.Name` field
        -- resolution isn't restricted to "last assignment before this textual position" - it
        -- resolves correctly from inside an earlier-defined function's body too, and doesn't
        -- consume any of Lua 5.1's 200-local-per-chunk budget (see export-env.lua's header for
        -- the full reasoning and the vm.getTableValue verification behind it).
        --
        -- A name that's shadowed anywhere in the file (a local/param/loop-var of the same
        -- name - `unsafeNames`, from exportEnv.scan) can't safely have every *reference*
        -- rewritten to `M.Name`, since a text scanner can't otherwise tell which bare
        -- occurrence means what inside that shadowing scope (confirmed real, not just
        -- theoretical: lua/system/profile.lua's `checkpoint` export is shadowed by
        -- `function checkpoint_to_table(checkpoint)`'s own parameter). Those names keep
        -- today's exact behaviour instead - forward-declared as a real `local`, then bridged
        -- into `M` with one `M.Name = Name` assignment before `return M` - so import()
        -- consumers still see a single, consistent table either way. Verified empirically
        -- negligible: 57 names total, across 24 files, in the whole fa repo's 102,668
        -- top-level exports.
        --
        -- `safeNames`/`unsafeList` were already computed at the top of this function (before
        -- classSupport ran, which needs `safeNames` too).

        -- Appended to `diffs` BEFORE the reference-rewrite diffs below, not after: if the file's
        -- very first byte is itself the start of a safe export's name (no leading comment/blank
        -- line), both this diff and that name's own `M.`-prefix diff target the same position-1
        -- insertion point, and mergeSameStartDiffs concatenates same-start diffs in append order -
        -- this header must land first, or the output would start with `M.local M = {}...`.
        local header = 'local M = {}\n'
        if #unsafeList > 0 then
            -- Same 200-local-cap safety margin as before, now scoped to just the unsafe
            -- subset - in practice always small enough that this never trips.
            local MAX_TOTAL_TOP_LEVEL_LOCALS = 190
            if (#unsafeList + topLevelLocalCount) <= MAX_TOTAL_TOP_LEVEL_LOCALS then
                header = header .. 'local ' .. table.concat(unsafeList, ', ') .. '\n'
            end
        end
        diffs[#diffs + 1] = {
            start  = 1,
            finish = 0,
            text   = header,
        }

        for _, diff in ipairs(exportEnv.rewriteReferences(text, safeNames)) do
            diffs[#diffs + 1] = diff
        end

        local footer = { '\n' }
        for _, name in ipairs(unsafeList) do
            footer[#footer + 1] = ('M.%s = %s\n'):format(name, name)
        end
        footer[#footer + 1] = 'return M\n'
        diffs[#diffs + 1] = {
            start  = #text + 1,
            finish = #text,
            text   = table.concat(footer),
        }
    end

    return resolveOverlappingDiffs(mergeSameStartDiffs(diffs))
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

    local results = findUrisBySuffix(uri, name)
    if #results > 0 then
        return results
    end
    return nil
end
