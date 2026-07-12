--[[--
Arabic/Latin search-text normalizer — the Lua half of the norm() contract
(norm_version = 1) shared with the quran-explorer extract
(kb/export/quran_text_extract.py, which builds text-vN.sqlite's FTS
columns). The two implementations MUST transform text identically: the
extract normalizes what gets indexed, this module normalizes what gets
queried. Parity is locked by scripts/dev_checks/norm_fixture.lua
(regenerated with every extract run) — never change one side alone; bump
norm_version on BOTH sides and rebuild/re-ship the text package when the
mapping changes.

Per codepoint, in this order:
 1. FOLD  alef variants (0622/0623/0625/0671 -> 0627), 0624 -> 0648,
          0626/0649 -> 064A, 0629 -> 0647
 2. SPACE ASCII punct (21-2F, 3A-40, 5B-60, 7B-7E), 00A0, 00AB, 00BB,
          060C, 061B, 061F, 066D, 06DE, 06E9, 2000-2027
 3. DROP  0621, 0640, 0610-061A, 064B-065F, 0670, 06D6-06ED, 08D3-08FF,
          FE00-FE0F, 200B-200F, FEFF
 4. SPACE digits 0030-0039, 0660-0669, 06F0-06F9
 5. LOWER ASCII A-Z only (non-ASCII case is the FTS tokenizer's job)
 6. anything else copied verbatim,
then collapse ASCII whitespace runs to one space and trim.
--]]

local M = { NORM_VERSION = 1 }

local ALEF, WAW, YA, HA = "\216\167", "\217\136", "\217\138", "\217\135"
local FOLD = {
    [0x0622] = ALEF, [0x0623] = ALEF, [0x0625] = ALEF, [0x0671] = ALEF,
    [0x0624] = WAW, [0x0626] = YA, [0x0649] = YA, [0x0629] = HA,
}
local SPACE_CP = {
    [0x00A0] = true, [0x00AB] = true, [0x00BB] = true, [0x060C] = true,
    [0x061B] = true, [0x061F] = true, [0x066D] = true, [0x06DE] = true,
    [0x06E9] = true,
}

local function isSpaceCp(cp)
    return (cp >= 0x21 and cp <= 0x2F) or (cp >= 0x3A and cp <= 0x40)
        or (cp >= 0x5B and cp <= 0x60) or (cp >= 0x7B and cp <= 0x7E)
        or SPACE_CP[cp] or (cp >= 0x2000 and cp <= 0x2027)
end

local function isRemovedCp(cp)
    return cp == 0x0621 or cp == 0x0640 or cp == 0xFEFF
        or (cp >= 0x0610 and cp <= 0x061A)
        or (cp >= 0x064B and cp <= 0x065F) or cp == 0x0670
        or (cp >= 0x06D6 and cp <= 0x06ED)
        or (cp >= 0x08D3 and cp <= 0x08FF)
        or (cp >= 0xFE00 and cp <= 0xFE0F)
        or (cp >= 0x200B and cp <= 0x200F)
end

local function isDigitCp(cp)
    return (cp >= 0x30 and cp <= 0x39)
        or (cp >= 0x0660 and cp <= 0x0669)
        or (cp >= 0x06F0 and cp <= 0x06F9)
end

local function cont(b) return (b or 0) % 64 end

--- Normalize text for FTS matching (query side of the contract).
function M.norm(s)
    if not s or s == "" then return "" end
    local out, i, n = {}, 1, #s
    while i <= n do
        local b1 = s:byte(i)
        local cp, len
        if b1 < 0x80 then
            cp, len = b1, 1
        elseif b1 >= 0xF0 then
            cp = (b1 % 8) * 262144 + cont(s:byte(i + 1)) * 4096
                + cont(s:byte(i + 2)) * 64 + cont(s:byte(i + 3))
            len = 4
        elseif b1 >= 0xE0 then
            cp = (b1 % 16) * 4096 + cont(s:byte(i + 1)) * 64 + cont(s:byte(i + 2))
            len = 3
        else
            cp = (b1 % 32) * 64 + cont(s:byte(i + 1))
            len = 2
        end
        if FOLD[cp] then
            out[#out + 1] = FOLD[cp]
        elseif isSpaceCp(cp) then
            out[#out + 1] = " "
        elseif isRemovedCp(cp) then -- luacheck: ignore 542
        elseif isDigitCp(cp) then
            out[#out + 1] = " "
        elseif cp >= 0x41 and cp <= 0x5A then
            out[#out + 1] = string.char(cp + 0x20)
        else
            out[#out + 1] = s:sub(i, i + len - 1)
        end
        i = i + len
    end
    local res = table.concat(out):gsub("%s+", " ")
    return (res:gsub("^ ", ""):gsub(" $", ""))
end

return M
