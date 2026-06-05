-- critter.nvim / mood.lua
-- 気分(mood)の計算ロジック。このプラグインの核心であり、ペットの表情を
-- 「コードの健康状態」に連動させる部分。

local git = require("critter.git")

local M = {}
local uv = vim.uv or vim.loop

-- transient override (e.g. celebrate for a couple seconds after a clean save)
local override = nil       -- { mood = "celebrate", until_ms = <ts> }
local last_activity = uv.now()

local function now() return uv.now() end

function M.mark_activity()
  last_activity = now()
end

function M.set_override(mood, ms)
  override = { mood = mood, expires = now() + ms }
end

local function error_count()
  -- vim.diagnostic.count exists on 0.10+, fall back to get() otherwise
  if vim.diagnostic.count then
    local c = vim.diagnostic.count(nil, { severity = vim.diagnostic.severity.ERROR })
    return c[vim.diagnostic.severity.ERROR] or 0
  end
  return #vim.diagnostic.get(nil, { severity = vim.diagnostic.severity.ERROR })
end

-- Returns one of: "idle" | "happy" | "sad" | "celebrate" | "sleep"
function M.current(cfg)
  if override and now() < override.expires then
    return override.mood
  end
  override = nil

  -- long idle / late night -> sleep
  local idle_for = now() - last_activity
  local hour = tonumber(os.date("%H"))
  local is_night = hour ~= nil and (hour >= 1 and hour < 6)
  if idle_for >= cfg.idle_sleep_ms or is_night and idle_for >= cfg.idle_sleep_ms / 5 then
    return "sleep"
  end

  if error_count() > 0 then
    return "sad"
  end
  -- no errors: happy if recently active, otherwise calm idle
  if idle_for < 4000 then
    return "happy"
  end
  return "idle"
end

-- Wire the editor events that feed mood. on_change is called whenever
-- something might have changed the mood.
function M.attach(cfg, on_change)
  local grp = vim.api.nvim_create_augroup("CritterMood", { clear = true })

  vim.api.nvim_create_autocmd("DiagnosticChanged", {
    group = grp,
    callback = function() on_change() end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = grp,
    callback = function()
      M.mark_activity()
      -- celebrate only if the save left no errors (give the LSP a beat first)
      vim.defer_fn(function()
        if error_count() == 0 then
          M.set_override("celebrate", cfg.celebrate_ms)
          on_change()
        end
      end, 300)
    end,
  })

  vim.api.nvim_create_autocmd({ "InsertCharPre", "CursorMoved", "CursorMovedI" }, {
    group = grp,
    callback = function() M.mark_activity() end,
  })

  -- git の commit / push をどこで実行しても (ターミナル / lazygit / IDE) celebrate する。
  -- .git/ 配下のファイル変化を fs_event で監視している (詳細は git.lua)。
  git.attach({
    on_commit = function()
      M.mark_activity()
      M.set_override("celebrate", cfg.celebrate_ms)
      on_change()
    end,
    on_push = function()
      M.mark_activity()
      M.set_override("celebrate", cfg.celebrate_ms)
      on_change()
    end,
  })
end

-- show→hide→show の再アタッチ時にウォッチャーを止められるよう公開しておく
function M.detach()
  git.detach()
end

return M
