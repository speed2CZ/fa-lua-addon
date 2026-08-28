-- if not set, the folder name will be used
name    = 'Forged Alliance'
-- match any word to load
words   = {'.'}
-- list of settings to be changed
---@type config.change[]
configs = {
    {
        key    = 'Lua.runtime.version',
        action = 'set',
        value  = 'Lua 5.1',
    },
    {
        key    = 'Lua.runtime.path',
        action = 'add',
        value  = '/?',
    },
    {
        key    = 'Lua.completion.showWord',
        action = 'set',
        value  = 'Disable',
    },
    {
        key    = 'Lua.runtime.special',
        action = 'prop',
        prop   = 'import',
        value  = 'require',
    },
    {
        key    = 'Lua.runtime.special',
        action = 'prop',
        prop   = 'doscript',
        value  = 'require',
    },
    {
        key    = 'Lua.runtime.nonstandardSymbol',
        action = 'add',
        value  = 'continue',
    },
    {
        key    = 'Lua.runtime.nonstandardSymbol',
        action = 'add',
        value  = '!=',
    },
    {
        key    = 'Lua.completion.requireSeparator',
        action = 'set',
        value  = '/',
    },
    {
        key    = 'Lua.runtime.pathStrict',
        action = 'set',
        value  = false,
    },
    {
        -- `<<`/`>>` (bitwise shift) are version-gated in script/parser/compile.lua to
        -- Lua 5.3+/LuaJIT, not controllable via nonstandardSymbol - but SupCom's engine
        -- supports them despite everything else here needing Lua.runtime.version = 'Lua 5.1'.
        -- Parsing itself isn't affected (the version check only pushes a diagnostic, parsing
        -- continues either way), so just silence it.
        key    = 'Lua.diagnostics.disable',
        action = 'add',
        value  = 'unsupport-symbol',
    },
}
for _, name in ipairs {'moho'} do
    configs[#configs+1] = {
        key    = 'Lua.diagnostics.globals',
        action = 'add',
        value  = name,
    }
end
