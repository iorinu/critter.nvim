-- critter.nvim
-- エディタに住む小さな生き物が、コードの健康状態に合わせて表情を変える
-- プラグイン。image.nvim (kitty graphics protocol) で描画する。
-- 最初の住人は "mame" (豆)。他に vscode-pets 由来のキャラも同梱。

local Sprite = require("critter.sprite")
local mood = require("critter.mood")
local critters = require("critter.critters")
local util = require("critter.util")

local M = {}
local uv = vim.uv or vim.loop

-- プラグインのルートディレクトリを取得 (.../lua/critter/init.lua から3階層上)
local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h:h:h")

-- このプラグインで使う mood の一覧 (描画/フレーム探索の対象)
local MOODS = { "idle", "happy", "sad", "celebrate", "sleep" }
-- 歩き回る mood (それ以外はその場で停止する。celebrate は跳ねるだけ / sleep は寝る)
local WALK_MOODS = { idle = true, happy = true, sad = true }

M.config = {
  enabled = true,
  critter = "crab",                -- 使うキャラ名 (critters.available のいずれか)
  base_height = 4,                 -- 描画の基準セル高さ (幅は画像のアスペクト比から自動)
  fps = 2,                         -- アニメ速度 (frames/sec)
  celebrate_ms = 2500,             -- celebrate表情の表示時間
  idle_sleep_ms = 5 * 60 * 1000,   -- これ以上無操作なら sleep
  walk_strip_cells = 20,           -- 歩き回るストリップの横幅 (cells)
  walk_velocity = 1,               -- 1ティックで進むcell数 (fps × velocity = cells/sec)
  right_margin_cells = 2,          -- 画面右端からどれだけ内側にずらすか (cells)。
                                   -- 0 にすると右端ギリギリだが、kitty graphics の描画が
                                   -- 折り返しっぽくバグることがあるので 1-2 cell 取るのが安全
  sprites = nil,                   -- 任意。指定があれば critter より優先 (mood -> { paths })
}

-- sprites/<critter>/<mood>_<N>.png を全部見つけて、N の昇順で並べたリストを返す
local function frames_for(critter_name, mood_name)
  local pattern = root .. "/sprites/" .. critter_name .. "/" .. mood_name .. "_*.png"
  local matches = vim.fn.glob(pattern, false, true)
  -- _left.png は除外する (左向きはコード側で接尾辞を付けて参照する)
  local right_only = {}
  for _, p in ipairs(matches) do
    if not p:match("_left%.png$") then right_only[#right_only + 1] = p end
  end
  table.sort(right_only, function(a, b)
    local na = tonumber(a:match("_(%d+)%.png$")) or 0
    local nb = tonumber(b:match("_(%d+)%.png$")) or 0
    return na < nb
  end)
  return right_only
end

local function build_sprites(critter_name)
  local out = {}
  for _, m in ipairs(MOODS) do
    out[m] = frames_for(critter_name, m)
    if #out[m] == 0 then
      vim.notify(("[critter] %s の %s フレームが見つかりません"):format(critter_name, m),
        vim.log.levels.WARN)
    end
  end
  return out
end

-- パス "/.../foo_3.png" を "/.../foo_3_left.png" に変換する。
-- 左向きPNGが無いケース (例: ユーザーが独自 sprites を渡したとき) は元のパスに fall back。
local function flip_path(path)
  local left = path:gsub("%.png$", "_left.png")
  if vim.fn.filereadable(left) == 1 then return left end
  return path
end

-- 現在の critter の代表フレームから、描画 footprint (cells) を割り出す
local function compute_footprint(sprites_table, base_height)
  -- 何でもいいので idle の1枚目から px を読む
  local sample = (sprites_table.idle and sprites_table.idle[1]) or nil
  if not sample then return base_height * 2, base_height end -- フォールバック
  local px_w, px_h = util.png_dims(sample)
  local w = util.fit_width_cells(px_w, px_h, base_height)
  return w, base_height
end

local state = {
  sprite     = nil,
  timer      = nil,
  cur_mood   = nil,
  frame      = 1,
  -- 歩行系の状態。hologram 移行後は floating window を動かさず、
  -- バッファ内の x 座標 (image_x) を動かす方式に変えた。
  --   image_x = 0           → strip 内の一番左にキャラが立つ
  --   image_x = max_x       → strip 内の一番右にキャラが立つ
  --   max_x                 = walk_strip_cells - footprint_w
  image_x    = 0,
  direction  = 1,    -- +1 = 右へ歩く (image_x が増える) / -1 = 左へ歩く (image_x が減る)
  footprint_w = 8,
  footprint_h = 4,
}

-- 歩く mood (idle/happy/sad) のときに image_x と direction を1ステップ進める。
--
-- 座標系: image_x は strip 内のキャラの左端 x 座標 (cells, 0始まり)。
--   image_x = 0          → strip 左端
--   image_x = max_x      → strip 右端 (画像がはみ出ないギリギリ)
-- direction:
--   direction = +1 → 右へ歩く → image_x が増える
--   direction = -1 → 左へ歩く → image_x が減る
-- 端に来たら direction を反転してバウンス。
local function step_walk()
  local max_x = math.max(0, M.config.walk_strip_cells - state.footprint_w)
  local v = M.config.walk_velocity
  local new_x = state.image_x + state.direction * v
  if new_x <= 0 then
    state.image_x = 0
    state.direction = 1   -- 左端に到達 → 次から右へ歩く
  elseif new_x >= max_x then
    state.image_x = max_x
    state.direction = -1  -- 右端に到達 → 次から左へ歩く
  else
    state.image_x = new_x
  end
end

-- 現在の mood / frame / direction から、実際に描画する画像パスを返す。
--
-- vscode-pets の元PNGはキャラが「右向き」を向いている。
--   direction = +1 (右へ歩く) → 元PNG (右向き)
--   direction = -1 (左へ歩く) → magick -flop した *_left.png (左向き)
local function current_frame_path(m)
  local frames = M.config.sprites[m] or M.config.sprites.idle
  local p = frames[state.frame] or frames[1]
  if state.direction == -1 then return flip_path(p) end
  return p
end

-- 毎ティック (fps に応じた間隔) で呼ばれる描画ルーチン。
-- 流れ:
--   1. mood.current で現在の気分を取得 (LSP診断/活動時刻/git/celebrate override)
--   2. mood が変わったら frame=1、同じなら次フレームへ
--   3. 歩く mood なら step_walk で image_x を進めて sprite に伝える
--   4. 現在フレームのPNG (右向き or 左向き) を sprite に描画させる
local function draw()
  local m = mood.current(M.config)
  local frames = M.config.sprites[m] or M.config.sprites.idle

  if m ~= state.cur_mood then
    state.cur_mood = m
    state.frame = 1
  else
    state.frame = state.frame % #frames + 1
  end

  if WALK_MOODS[m] then
    step_walk()
    state.sprite:set_image_x(state.image_x)
  end

  state.sprite:render(current_frame_path(m))
end

local function tick()
  -- hologram / nvim API はメインループでしか触れないので、libuv timer から
  -- 直接叩かず schedule で逃がす
  vim.schedule(function()
    if state.sprite then draw() end
  end)
end

function M.show()
  if not M.config.enabled then return end
  if state.sprite == nil then
    state.sprite = Sprite.new(M.config)
  end
  -- 現在の critter の footprint を計算してウィンドウに適用
  state.footprint_w, state.footprint_h = compute_footprint(M.config.sprites, M.config.base_height)
  state.sprite:set_footprint(state.footprint_w, state.footprint_h)
  -- 歩行位置と向きを初期化 (左端からスタートして右へ歩き出す)
  state.image_x = 0
  state.direction = 1
  state.sprite:set_image_x(0)
  state.sprite:open()
  draw()

  if state.timer == nil then
    state.timer = uv.new_timer()
    local interval = math.max(100, math.floor(1000 / M.config.fps))
    state.timer:start(interval, interval, tick)
  end

  mood.attach(M.config, function() tick() end)

  vim.api.nvim_create_autocmd("VimResized", {
    group = vim.api.nvim_create_augroup("CritterLayout", { clear = true }),
    callback = function()
      if state.sprite then state.sprite:reposition(); tick() end
    end,
  })
end

function M.hide()
  if state.timer then state.timer:stop(); state.timer:close(); state.timer = nil end
  if state.sprite then state.sprite:close(); state.sprite = nil end
  mood.detach() -- git fs_event のウォッチャーも止める
  state.cur_mood = nil
end

function M.toggle()
  if state.sprite then M.hide() else M.show() end
end

function M.switch(name)
  if not critters.load(name) then
    vim.notify("[critter] 知らないキャラです: " .. tostring(name), vim.log.levels.ERROR)
    return
  end
  M.config.critter = name
  M.config.sprites = build_sprites(name)
  state.cur_mood = nil
  state.frame = 1
  if state.sprite then
    -- キャラ切り替え: 古い Image の placement を消して、新しい footprint に合わせる
    state.sprite:clear_image()
    state.footprint_w, state.footprint_h = compute_footprint(M.config.sprites, M.config.base_height)
    state.sprite:set_footprint(state.footprint_w, state.footprint_h)
    state.image_x = 0
    state.direction = 1
    state.sprite:set_image_x(0)
    draw()
  end
end

function M.setup(opts)
  M.config = vim.tbl_deep_extend("force", M.config, opts or {})
  if M.config.sprites == nil then
    M.config.sprites = build_sprites(M.config.critter)
  end

  -- デバッグ用: 現在の歩行状態を見える化する
  vim.api.nvim_create_user_command("CritterState", function()
    local max_x = math.max(0, M.config.walk_strip_cells - state.footprint_w)
    local m = mood.current(M.config)
    print(("[critter] mood=%s walk?=%s image_x=%d dir=%d max_x=%d footprint_w=%d strip=%d cols=%d"):format(
      tostring(m), tostring(WALK_MOODS[m] and true or false),
      state.image_x, state.direction, max_x,
      state.footprint_w, M.config.walk_strip_cells, vim.o.columns))
  end, {})

  vim.api.nvim_create_user_command("Critter", function(a)
    local args = vim.split(a.args, "%s+", { trimempty = true })
    local sub = args[1] or "toggle"
    if sub == "switch" then
      M.switch(args[2])
    elseif M[sub] then
      M[sub]()
    else
      vim.notify("[critter] unknown: " .. sub)
    end
  end, {
    nargs = "*",
    complete = function(_, line)
      local parts = vim.split(line, "%s+", { trimempty = true })
      if #parts >= 2 and parts[2] == "switch" then
        return critters.available
      end
      return { "show", "hide", "toggle", "switch" }
    end,
  })

  if M.config.enabled then
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = function() vim.schedule(M.show) end,
    })
  end
end

return M
