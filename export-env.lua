-- Heuristic pre-parse scanner (not a real parser): finds FA's bare top-level
-- declarations (`Name = ...` / `function Name(...)`, no `local` keyword) so
-- OnSetText can forward-declare them as real locals before the actual parser
-- ever sees the file. That's what makes forward/mutual references between
-- them resolve correctly - a post-parse AST patch can't do that, since Lua's
-- local-scoping is itself order-dependent and has to be decided by the real
-- parser, which means it has to happen in the source text, before parsing.
--
-- Depth tracks both block keywords (function/if/do/repeat...end/until) AND `{`/`}`, since
-- FA classes are one big table constructor (`Unit = ClassUnit(...) { Foo = function(self)
-- ... end, ... }`) - without counting braces too, every `Key = function(...) end,` entry
-- inside it looks exactly like a bare top-level export the moment its own function/end
-- balances back to depth 0, and gets wrongly captured (verified against real FA files:
-- lua/sim/Unit.lua alone went from 3 genuine top-level names to 329 false ones without this).
--
-- Known limitations (acceptable trade-off for a regex/state-machine scanner
-- instead of a full parser): a bare multi-target assignment (`A, B = x, y`)
-- only captures `A`; spaced-out member access (`t . Name = x`) isn't
-- recognised as a member access and could false-positive.

local M = {}

local BLOCK_OPEN  = { ['function'] = true, ['if'] = true, ['do'] = true, ['repeat'] = true }
local BLOCK_CLOSE = { ['end'] = true, ['until'] = true }
local LOOP_HEADER = { ['for'] = true, ['while'] = true }

-- Files marked `---@declare-global` (or `---@meta`) are declaring real globals, not FA
-- module exports - e.g. the engine API stubs. Leave them as plain, untransformed Lua.
local function optsOut(text)
    return text:find('%-%-%-@declare%-global') ~= nil
        or text:find('%-%-%-@meta') ~= nil
end

---@param text string
---@return string[] exports  ordered, de-duplicated bare top-level names
---@return boolean  hasTopReturn  whether the file already has a top-level `return`
function M.scan(text)
    if optsOut(text) then
        return {}, false
    end

    local n = #text
    local i = 1
    local depth = 0
    local loopHeaderDepth = 0
    local lastWord = nil
    local prevChar = nil
    local hasTopReturn = false

    local exportsSet = {}
    local exports = {}
    local function addExport(name)
        if not exportsSet[name] then
            exportsSet[name] = true
            exports[#exports + 1] = name
        end
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

        elseif c == '"' or c == "'" then
            local quote = c
            local j = i + 1
            while j <= n do
                local cj = text:sub(j, j)
                if cj == '\\' then
                    j = j + 2
                elseif cj == quote then
                    j = j + 1
                    break
                else
                    j = j + 1
                end
            end
            i = j
            prevChar = quote
            lastWord = nil

        elseif c == '[' then
            local eqs = text:match('^%[(=*)%[', i)
            if eqs then
                local _, closeEnd = text:find(']' .. eqs .. ']', i + 2 + #eqs, true)
                i = closeEnd and (closeEnd + 1) or (n + 1)
            else
                i = i + 1
            end
            prevChar = ']'
            lastWord = nil

        elseif c:match('%s') then
            i = i + 1

        elseif c:match('[%a_]') then
            local _, e, word = text:find('^([%a_][%w_]*)', i)
            i = e + 1

            local k = i
            while k <= n and text:sub(k, k):match('%s') do
                k = k + 1
            end
            local nextChar = text:sub(k, k)

            if word == 'function' then
                depth = depth + 1
                if depth == 1 and loopHeaderDepth == 0 and lastWord ~= 'local' then
                    local ns, _, fname = text:find('^%s*([%a_][%w_]*)%s*%(', i)
                    if ns then
                        addExport(fname)
                    end
                end
            elseif BLOCK_OPEN[word] then
                depth = depth + 1
                if word == 'do' and loopHeaderDepth > 0 then
                    loopHeaderDepth = loopHeaderDepth - 1
                end
            elseif BLOCK_CLOSE[word] then
                depth = math.max(0, depth - 1)
            elseif LOOP_HEADER[word] then
                loopHeaderDepth = loopHeaderDepth + 1
            elseif word == 'return' then
                if depth == 0 and loopHeaderDepth == 0 then
                    hasTopReturn = true
                end
            elseif depth == 0 and loopHeaderDepth == 0
               and prevChar ~= '.' and prevChar ~= ':'
               and lastWord ~= 'local' then
                if nextChar == '=' and text:sub(k, k + 1) ~= '==' then
                    addExport(word)
                end
            end

            lastWord = word
            prevChar = nil

        elseif c == '{' then
            depth = depth + 1
            prevChar = nil
            lastWord = nil
            i = i + 1

        elseif c == '}' then
            depth = math.max(0, depth - 1)
            prevChar = nil
            lastWord = nil
            i = i + 1

        else
            prevChar = (c == '.' or c == ':') and c or nil
            lastWord = nil
            i = i + 1
        end
    end

    return exports, hasTopReturn
end

return M
