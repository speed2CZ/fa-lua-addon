-- Makes FA's `Class()`-family OOP sugar readable as a real class to LuaLS, by stripping the
-- wrapper call down to a plain table and adding the `---@class` doc it implies.
--
-- FA classes are defined as `Name = ClassFn(Base1, Base2, ...) { specs }` (or the no-base
-- `Name = ClassFn { specs }` form), per lua/system/class.lua. Even though class.lua carries
-- `---@generic T / @param specs T / @return T` annotations aimed at propagating the spec
-- table's fields through the call, LuaLS's class-doc-to-declaration binding only reliably
-- merges fields from a table constructor assigned *directly* - not one arriving through an
-- opaque (if generically-annotated) function call. So we strip the `ClassFn(...)` wrapper
-- text entirely, leaving a plain `Name = { specs }`, and inject a `---@class Name: Bases`
-- doc comment when the file doesn't already have one for that name - both are things LuaLS
-- already handles natively and reliably once the call is out of the way. Blanking the wrapper
-- also erases the only reference to any bare-identifier base argument (`Class(NullShell) {}`),
-- which would otherwise make its `local NullShell = ...` declaration look unused - a harmless
-- `local _ = NullShell` keep-alive line is inserted alongside to prevent that (see the
-- comment at its call site for why `_` specifically).
--
-- Known limitations: only the `Name = ClassFn(...) { ... }` assignment shape is handled
-- (bare identifier target only, no dotted targets like `t.Name = ...`); an anonymous
-- `ClassFn(...) {}` with nothing assignable to its left is left untouched.

local M = {}

local CLASS_FUNCTIONS = {
    Class = true, ClassSimple = true, ClassUI = true, ClassShield = true,
    ClassProjectile = true, ClassDummyProjectile = true, ClassUnit = true,
    ClassDummyUnit = true, ClassWeapon = true, ClassTrashBag = true, State = true,
}

---@param text string
---@param i integer  position of '['
---@param n integer
---@return integer? closeEnd
local function skipLongBracket(text, i, n)
    local eqs = text:match('^%[(=*)%[', i)
    if not eqs then
        return nil
    end
    local _, closeEnd = text:find(']' .. eqs .. ']', i + 2 + #eqs, true)
    return closeEnd and (closeEnd + 1) or (n + 1)
end

---@param text string
---@param j integer  index to start skipping a string at (points at the closing quote's opener)
---@param n integer
---@param quote string
---@return integer  position right after the closing quote
local function skipString(text, j, n, quote)
    j = j + 1
    while j <= n do
        local cj = text:sub(j, j)
        if cj == '\\' then
            j = j + 2
        elseif cj == quote then
            return j + 1
        else
            j = j + 1
        end
    end
    return j
end

--- Finds the bare identifier immediately assigned right before `pos` (i.e. `Name =` ending
--- right at `pos`, skipping whitespace, and rejecting `==`/`~=`/`<=`/`>=`).
---@param text string
---@param pos integer
---@return integer? nameStart
---@return string?  name
local function findPrecedingName(text, pos)
    local j = pos - 1
    while j >= 1 and text:sub(j, j):match('%s') do
        j = j - 1
    end
    if j < 1 or text:sub(j, j) ~= '=' then
        return nil
    end
    j = j - 1
    if j >= 1 and text:sub(j, j):match('[=~<>]') then
        return nil
    end
    while j >= 1 and text:sub(j, j):match('%s') do
        j = j - 1
    end
    local nameEnd = j
    while j >= 1 and text:sub(j, j):match('[%w_]') do
        j = j - 1
    end
    local nameStart = j + 1
    if nameStart > nameEnd or not text:sub(nameStart, nameStart):match('[%a_]') then
        return nil
    end
    return nameStart, text:sub(nameStart, nameEnd)
end

--- If `local` immediately precedes `nameStart` as a whole word (i.e. `local Name = ...`),
--- returns the position of that `local` instead - the TRUE start of the statement. Otherwise
--- returns `nameStart` unchanged. Needed because findPrecedingName only ever returns the bare
--- name's own position, never accounting for an optional `local` prefix - inserting a new
--- statement right at `nameStart` when `local` precedes it produces `local <inserted>Name = ...`,
--- i.e. a literal double `local` and a real syntax error (reproduced on
--- lua/maui/layouthelpers.lua's `local LayouterAttributeEditor = Class(LayouterAttributeFont)
--- {` - an internal, local-scoped helper class, not FA's usual bare-global export).
---@param text      string
---@param nameStart integer
---@return integer
local function findStatementStart(text, nameStart)
    local j = nameStart - 1
    while j >= 1 and text:sub(j, j):match('%s') do
        j = j - 1
    end
    if j >= 5 and text:sub(j - 4, j) == 'local' then
        local before = j - 5
        if before < 1 or not text:sub(before, before):match('[%w_]') then
            return j - 4
        end
    end
    return nameStart
end

--- Walks backward from `pos` through a contiguous run of `--` comment lines (stopping at a
--- blank line or real code - same walk as hasImmediatePrecedingClassDoc below), returning the
--- start position of the topmost comment line in that run, or `pos` itself if no such block
--- immediately precedes it. Lets a synthetic statement be inserted BEFORE any doc-comment block
--- (hand-written or injected) instead of between it and the statement it documents, which would
--- break a LuaDoc annotation's "immediately precedes" binding requirement - see the base-class
--- keep-alive in stripWrappers below for why that matters here.
---@param text string
---@param pos  integer
---@return integer
local function findCommentBlockStart(text, pos)
    local boundary = pos
    local lineEnd = pos - 2
    while lineEnd >= 1 do
        local lineStart = text:sub(1, lineEnd):match('.*\n()') or 1
        local line = text:sub(lineStart, lineEnd)
        local trimmed = line:match('^%s*(.-)%s*$')
        if trimmed == '' then
            break
        elseif trimmed:match('^%-%-') then
            boundary = lineStart
            lineEnd = lineStart - 2
        else
            break
        end
    end
    return boundary
end

--- Checks whether a `---@class` line (any name) already sits in the contiguous block of
--- comment lines immediately above `pos` - i.e. whether *this* statement already has a class
--- doc, regardless of what name it uses. FA often names the doc differently than the
--- assigned variable on purpose (e.g. `---@class EasyAIBrain: ...` directly above
--- `AIBrain = Class(...) {...}`, specifically so multiple files' generic `AIBrain` locals
--- don't collide globally) - relying only on "does a doc named after the variable exist
--- anywhere in the file" misses that and injects a second, conflicting same-named class that
--- merges fields across every file that hits this pattern. Walks backward line by line: a
--- blank line or real code stops the scan (no doc found); a comment line that isn't
--- `---@class` keeps walking (covers `---@field`/description lines that sit between
--- `---@class` and the code, as in the real examples above).
---@param text string
---@param pos  integer
---@return boolean
local function hasImmediatePrecedingClassDoc(text, pos)
    -- pos-1 is the newline separating the preceding line from `pos`'s own line; start the
    -- scan at pos-2, the last character *of* that preceding line (off-by-one verified by hand:
    -- text:sub(1, pos-1) always ends in that same separating newline, so `.*\n()` matches it
    -- and returns pos itself, making text:sub(pos, pos-1) - the "current line" - empty).
    local lineEnd = pos - 2
    while lineEnd >= 1 do
        local lineStart = text:sub(1, lineEnd):match('.*\n()') or 1
        local line = text:sub(lineStart, lineEnd)
        local trimmed = line:match('^%s*(.-)%s*$')
        if trimmed == '' then
            return false
        elseif trimmed:match('^%-%-%-@class') then
            return true
        elseif trimmed:match('^%-%-') then
            lineEnd = lineStart - 2
        else
            return false
        end
    end
    return false
end

--- Splits a `(...)` argument-list body on top-level commas (paren/string aware).
---@param argsText string
---@return string[]
local function splitTopLevelArgs(argsText)
    local parts = {}
    local n = #argsText
    local depth = 0
    local start = 1
    local j = 1
    while j <= n do
        local c = argsText:sub(j, j)
        if c == '"' or c == "'" then
            j = skipString(argsText, j, n, c) - 1
        elseif c == '(' then
            depth = depth + 1
        elseif c == ')' then
            depth = depth - 1
        elseif c == ',' and depth == 0 then
            parts[#parts + 1] = argsText:sub(start, j - 1):match('^%s*(.-)%s*$')
            start = j + 1
        end
        j = j + 1
    end
    local last = argsText:sub(start):match('^%s*(.-)%s*$')
    if last ~= '' then
        parts[#parts + 1] = last
    end
    return parts
end

---@param s string
---@return boolean
local function isSimpleTypeName(s)
    if s == '' then
        return false
    end
    for segment in (s .. '.'):gmatch('([^.]*)%.') do
        if not segment:match('^[%a_][%w_]*$') then
            return false
        end
    end
    return true
end

--- Classifies a raw `Class(...)` base-argument's source text into something usable in a
--- `---@class X: Base` doc. Only a bare type-name (dotted-identifier chain, e.g.
--- `moho.unit_methods`) is a valid LuaLS type reference; anything else - a call, indexing on a
--- call result, etc. - isn't, and dropping the raw text in verbatim (e.g.
--- `import("/lua/sim/prop.lua").Prop`) produces a malformed reference LuaLS reports as an
--- undefined class (confirmed: env/*/Props/*/*_script.lua's recurring `Class(import(path).Name)`
--- pattern). That specific shape is common enough to special-case: extract just `Name` and use
--- that - correct whenever the target file kept its default, unrenamed class name, which fails
--- safe even when wrong (a missing inherited-member completion, not a new diagnostic). Anything
--- else unrecognised is dropped rather than guessed at.
---@param baseText string
---@return string?
local function sanitizeBase(baseText)
    if isSimpleTypeName(baseText) then
        return baseText
    end
    return baseText:match('^import%s*%b()%.([%a_][%w_]*)$')
end

---@param text string
---@return fa.diff[]
function M.stripWrappers(text)
    local n = #text
    local i = 1
    local diffs = {}
    local lastWord = nil
    local prevChar = nil
    -- Counts ONLY '{'/'}' - tells us whether we're inside some table constructor's field list,
    -- where a synthetic *statement* (the base-class keep-alive below) can never legally go, vs
    -- a real statement context (top level, or inside a function/if/for/while/do body - all of
    -- which allow statements). The blanking/doc-injection logic below stays depth-independent
    -- on purpose (already correct for nested classes, e.g. a class nested in another's spec
    -- table); only the keep-alive needs this.
    local braceDepth = 0

    local existingClassDocs = {}
    for name in text:gmatch('%-%-%-@class%s+([%a_][%w_%.]*)') do
        existingClassDocs[name] = true
    end

    while i <= n do
        local c = text:sub(i, i)

        if c == '-' and text:sub(i, i + 1) == '--' then
            local afterDashes = i + 2
            local eqs = text:match('^%[(=*)%[', afterDashes)
            if eqs then
                local _, closeEnd = text:find(']' .. eqs .. ']', afterDashes + 2 + #eqs, true)
                i = closeEnd and (closeEnd + 1) or (n + 1)
            else
                local nl = text:find('\n', i, true)
                i = nl and (nl + 1) or (n + 1)
            end
            lastWord = nil
            prevChar = nil

        elseif c == '"' or c == "'" then
            i = skipString(text, i, n, c)
            prevChar = c
            lastWord = nil

        elseif c == '[' then
            i = skipLongBracket(text, i, n) or (i + 1)
            prevChar = ']'
            lastWord = nil

        elseif c:match('%s') then
            i = i + 1

        elseif c:match('[%a_]') then
            local wordStart = i
            local _, e, word = text:find('^([%a_][%w_]*)', i)
            i = e + 1

            if CLASS_FUNCTIONS[word] and prevChar ~= '.' and prevChar ~= ':' and lastWord ~= 'function' then
                local k = i
                local _, we1 = text:find('^%s*', k)
                k = we1 + 1

                local bases = nil
                local rawBases = nil
                if text:sub(k, k) == '(' then
                    local depth = 0
                    local j = k
                    while j <= n do
                        local cj = text:sub(j, j)
                        if cj == '"' or cj == "'" then
                            j = skipString(text, j, n, cj) - 1
                        elseif cj == '(' then
                            depth = depth + 1
                        elseif cj == ')' then
                            depth = depth - 1
                            if depth == 0 then
                                break
                            end
                        end
                        j = j + 1
                    end
                    if j <= n then
                        rawBases = splitTopLevelArgs(text:sub(k + 1, j - 1))
                        bases = {}
                        for _, raw in ipairs(rawBases) do
                            local sanitized = sanitizeBase(raw)
                            if sanitized then
                                bases[#bases + 1] = sanitized
                            end
                        end
                        k = j + 1
                        local _, we2 = text:find('^%s*', k)
                        k = we2 + 1
                    else
                        k = nil -- unbalanced parens, bail on this occurrence
                    end
                end

                if k and text:sub(k, k) == '{' then
                    diffs[#diffs + 1] = {
                        start  = wordStart,
                        finish = k - 1,
                        text   = (' '):rep(k - wordStart),
                    }

                    local nameStart, className = findPrecedingName(text, wordStart)
                    -- The TRUE start of the statement - accounts for an optional `local` prefix
                    -- (`local Name = ClassFn(...)`, e.g. lua/maui/layouthelpers.lua's internal
                    -- helper classes) that `nameStart` alone doesn't. Both insertions below use
                    -- this, not `nameStart` directly, to avoid landing between `local` and the
                    -- name it declares.
                    local statementStart = nameStart and findStatementStart(text, nameStart)

                    -- Blanking `ClassFn(Bases...)` above erases the only reference to a
                    -- bare-identifier base like `NullShell` from LuaLS's view - if it came from
                    -- a `local NullShell = ...` declaration, that local now looks unused
                    -- (confirmed real: effects/**/*_script.lua files routinely do
                    -- `local NullShell = import(...).NullShell` then `Class(NullShell) {...}` -
                    -- and it's common: 324/600 files in a random fa-repo sample hit this). A
                    -- harmless `local _ = NullShell` right before the class statement "reads" it
                    -- again - `_` is itself exempt from the unused-local check
                    -- (script/core/diagnostics/unused-local.lua checks `name == '_'` and skips),
                    -- so this satisfies the original local without ever tripping its own
                    -- warning. Inserted at the *top* of any immediately-preceding comment block
                    -- (findCommentBlockStart), not at statementStart directly - otherwise it
                    -- would land between an existing hand-written `---@class` doc and the class
                    -- statement it documents, breaking that doc's binding.
                    --
                    -- Only at braceDepth 0: `OnState = State(Shield.OnState) {...}` nested as a
                    -- FIELD inside an outer class's own table constructor (a self-referential
                    -- state-override pattern, confirmed real: lua/shield.lua:1135) has no legal
                    -- place for a synthetic *statement* - a table constructor's field list only
                    -- accepts `[expr]=v`/`name=v`/`v` entries, never a `local` statement.
                    -- Reproduced: inserting one there produced "<keyword> cannot be used as
                    -- name" (the parser hitting `local` where a field name was expected). Nested
                    -- bases also don't need the keep-alive in the first place - they're
                    -- typically dotted references into the very class being defined
                    -- (`Shield.OnState`), not a separate local at risk of going unused.
                    if statementStart and rawBases and braceDepth == 0 then
                        local keepAlive = {}
                        for _, raw in ipairs(rawBases) do
                            if isSimpleTypeName(raw) then
                                keepAlive[#keepAlive + 1] = 'local _ = ' .. raw
                            end
                        end
                        if #keepAlive > 0 then
                            local insertAt = findCommentBlockStart(text, statementStart)
                            diffs[#diffs + 1] = {
                                start  = insertAt,
                                finish = insertAt - 1,
                                text   = table.concat(keepAlive, '; ') .. '\n',
                            }
                        end
                    end

                    if className
                    and statementStart
                    and not existingClassDocs[className]
                    and not hasImmediatePrecedingClassDoc(text, statementStart) then
                        local doc
                        if bases and #bases > 0 then
                            doc = '---@class ' .. className .. ': ' .. table.concat(bases, ', ') .. '\n'
                        else
                            doc = '---@class ' .. className .. '\n'
                        end
                        diffs[#diffs + 1] = {
                            start  = statementStart,
                            finish = statementStart - 1,
                            text   = doc,
                        }
                        existingClassDocs[className] = true
                    end
                end
            end

            lastWord = word
            prevChar = nil

        elseif c == '{' then
            braceDepth = braceDepth + 1
            prevChar = nil
            lastWord = nil
            i = i + 1

        elseif c == '}' then
            braceDepth = math.max(0, braceDepth - 1)
            prevChar = nil
            lastWord = nil
            i = i + 1

        else
            prevChar = (c == '.' or c == ':') and c or nil
            lastWord = nil
            i = i + 1
        end
    end

    return diffs
end

return M
