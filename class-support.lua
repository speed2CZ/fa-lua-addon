-- FA classes are defined as `Name = ClassFn(Base1, Base2, ...) { specs }` (or the no-base
-- `Name = ClassFn { specs }` form), per lua/system/class.lua. Even though class.lua carries
-- `---@generic T / @param specs T / @return T` annotations aimed at propagating the spec
-- table's fields through the call, LuaLS's class-doc-to-declaration binding only reliably
-- merges fields from a table constructor assigned *directly* - not one arriving through an
-- opaque (if generically-annotated) function call. So we strip the `ClassFn(...)` wrapper
-- text entirely, leaving a plain `Name = { specs }`, and inject a `---@class Name: Bases`
-- doc comment when the file doesn't already have one for that name - both are things LuaLS
-- already handles natively and reliably once the call is out of the way.
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

---@param text string
---@return fa.diff[]
function M.stripWrappers(text)
    local n = #text
    local i = 1
    local diffs = {}
    local lastWord = nil
    local prevChar = nil

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
                        bases = splitTopLevelArgs(text:sub(k + 1, j - 1))
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
                    if className and not existingClassDocs[className] then
                        local doc
                        if bases and #bases > 0 then
                            doc = '---@class ' .. className .. ': ' .. table.concat(bases, ', ') .. '\n'
                        else
                            doc = '---@class ' .. className .. '\n'
                        end
                        diffs[#diffs + 1] = {
                            start  = nameStart,
                            finish = nameStart - 1,
                            text   = doc,
                        }
                        existingClassDocs[className] = true
                    end
                end
            end

            lastWord = word
            prevChar = nil

        else
            prevChar = (c == '.' or c == ':') and c or nil
            lastWord = nil
            i = i + 1
        end
    end

    return diffs
end

return M
