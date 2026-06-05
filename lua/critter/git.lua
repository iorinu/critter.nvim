-- critter.nvim / git.lua
-- git の commit / push を検知するための監視モジュール。
-- ターミナルでも IDE でもどこで git しても反応させたいので、autocmd ではなく
-- .git/ 配下のファイル変化を vim.uv.new_fs_event (libuv の fsevent) で監視する。
--
-- 検知ポイント:
--   - commit: .git/logs/HEAD が更新された (commit / amend / merge / reset すべて含む)
--   - push:   .git/logs/refs/remotes/<remote>/<branch> が更新された

local M = {}
local uv = vim.uv or vim.loop

-- 開いている fs_event ハンドルを保持しておき、detach() でまとめて止める
local watchers = {}

-- cwd から上に遡って .git を探す。worktree (.git がファイル) にも対応する。
local function find_gitdir(start)
  local dir = start or vim.fn.getcwd()
  while dir and dir ~= "/" do
    local dotgit = dir .. "/.git"
    local stat = uv.fs_stat(dotgit)
    if stat then
      if stat.type == "directory" then
        return dotgit
      elseif stat.type == "file" then
        -- worktree の場合、.git は "gitdir: <実体パス>" と書かれたテキストファイル
        local fd = io.open(dotgit, "r")
        if fd then
          local line = fd:read("*l")
          fd:close()
          local target = line and line:match("^gitdir:%s*(.+)$")
          if target then
            -- 相対パスなら絶対化する
            if not target:match("^/") then
              target = dir .. "/" .. target
            end
            return target
          end
        end
      end
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

-- 1ファイルに対して fs_event を仕掛ける。コールバックは main loop で呼ぶ。
local function watch_file(path, on_event)
  local w = uv.new_fs_event()
  if not w then return end
  local ok = pcall(function()
    w:start(path, {}, function(err)
      if err then return end
      -- libuv のコールバックから直接 nvim API は触れないので schedule で逃がす
      vim.schedule(on_event)
    end)
  end)
  if not ok then
    pcall(function() w:close() end)
    return
  end
  watchers[#watchers + 1] = w
end

-- .git/logs/refs/remotes/ を再帰的に歩いて、見つかったログファイルを全部返す
local function find_remote_logs(gitdir)
  local base = gitdir .. "/logs/refs/remotes"
  local results = {}
  local function walk(dir)
    local fd = uv.fs_scandir(dir)
    if not fd then return end
    while true do
      local name, t = uv.fs_scandir_next(fd)
      if not name then break end
      local full = dir .. "/" .. name
      if t == "directory" then
        walk(full)
      elseif t == "file" then
        results[#results + 1] = full
      end
    end
  end
  walk(base)
  return results
end

-- opts = { on_commit = fn, on_push = fn }
-- cwd が git リポジトリでなければ何もしないでだまって終わる。
function M.attach(opts)
  M.detach() -- 二重起動防止

  local gitdir = find_gitdir()
  if not gitdir then return end

  -- commit: HEAD ログ
  local head_log = gitdir .. "/logs/HEAD"
  if uv.fs_stat(head_log) then
    watch_file(head_log, function()
      if opts.on_commit then opts.on_commit() end
    end)
  end

  -- push: リモート追跡ブランチごとのログ
  for _, p in ipairs(find_remote_logs(gitdir)) do
    watch_file(p, function()
      if opts.on_push then opts.on_push() end
    end)
  end
end

function M.detach()
  for _, w in ipairs(watchers) do
    pcall(function() w:stop() end)
    pcall(function() w:close() end)
  end
  watchers = {}
end

return M
