-- critter.nvim / sprite.lua
-- 画面下端の固定 floating window と、その中で動く画像 (キャラ) を管理する。
--
-- 描画は hologram.nvim を経由して kitty graphics protocol を喋る。
-- image.nvim から hologram に乗り換えた理由:
--   - image.nvim は floating window を毎ティック動かすと描画位置が遅れたり
--     古いフレームがゴーストとして残る問題があった (image.nvim #34, #245)。
--   - hologram は Image:new でPNGを1回だけ転送して image_id で覚え、
--     その後は Image:display(row, col, buf) を呼ぶたびに同じ placement_id で
--     位置を更新するため、kitty 側でアトミックに移動扱いになりゴーストが残らない。
--
-- 本ファイル内での座標系:
--   floating window 自体は固定位置 (画面右下)、サイズは walk_strip_cells × height。
--   キャラ画像は buf 内の (row=0, col=image_x) に表示する。
--   image_x を変えるとキャラが strip 内を左右に移動して見える。

local Image = require("hologram.image")
-- hologram の Image:display は内部で bufwinid/getwininfo/set_vpad などを呼んで
-- バッファ→スクリーン座標変換と「画像の上に空白行を確保」処理をする。
-- これが minimal な floating window 相手だと失敗するケースがあり、画像が
-- ターミナル絶対座標 (1, image_x) = 画面左上 に出てしまう症状を踏んだ。
-- そこで display は使わず、terminal モジュールの move_cursor + send_graphics_command
-- を直叩きしてスクリーン座標を自前で指定する方式に切り替えた。
local terminal = require("hologram.terminal")

local Sprite = {}
Sprite.__index = Sprite

-- ==== モジュール初期化: 透過用のハイライトグループを用意 ==========
-- floating window の背景に NormalFloat が出てしまうと PNG の透過部分に
-- 色が出るので、bg=NONE のグループを用意して当てる。
local function ensure_transparent_hl()
  vim.api.nvim_set_hl(0, "CritterFloat", { bg = "NONE", ctermbg = "NONE" })
end
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup("CritterHL", { clear = true }),
  callback = ensure_transparent_hl,
})
ensure_transparent_hl()

-- ==== Image キャッシュ (パスごとに1つの Image インスタンス) ==========
-- hologram の Image:new は PNG データをターミナルに転送する重い操作なので、
-- 同じパスは1回しか new しない。表示するときは display() を呼ぶだけ。
local image_cache = {}
local function get_image(path)
  if not image_cache[path] then
    image_cache[path] = Image:new(path, {})
  end
  return image_cache[path]
end

-- ==== Sprite クラス ==========

function Sprite.new(cfg)
  local self = setmetatable({}, Sprite)
  self.cfg = cfg
  self.win = nil
  self.buf = nil
  -- 現在表示中の Image オブジェクト。新しいパスを描画するときに delete する
  self.current_img = nil
  -- 現在の描画サイズ (cells)。キャラを切り替えると更新される
  self.footprint_w = cfg.width  or 8
  self.footprint_h = cfg.height or 4
  -- 画像のバッファ内 x 座標 (cells)。0 が strip の左端、(strip_w - footprint_w) が右端。
  self.image_x = 0
  return self
end

-- ストリップ floating window の config を組み立てる。
-- ウィンドウ自体は固定 (画面右下にぴったり)、サイズは strip_cells × footprint_h。
local function window_config(self)
  local statusline_rows = (vim.o.laststatus > 0) and 1 or 0
  local bottom_row = vim.o.lines - vim.o.cmdheight - statusline_rows - 1
  local right_margin = self.cfg.right_margin_cells or 0
  local strip_w = self.cfg.walk_strip_cells or 20
  return {
    relative = "editor",
    anchor   = "SE",  -- (row, col) はウィンドウの右下隅
    row      = bottom_row,
    col      = vim.o.columns - right_margin,
    width    = strip_w,
    height   = self.footprint_h,
    style    = "minimal",
    focusable = false,
    zindex   = 200,
    noautocmd = true,
  }
end

function Sprite:open()
  -- 透明なキャンバス用バッファ。strip_w 幅の空白で埋めて描画領域を確保する。
  if self.buf == nil or not vim.api.nvim_buf_is_valid(self.buf) then
    self.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[self.buf].bufhidden = "wipe"
  end
  local strip_w = self.cfg.walk_strip_cells or 20
  local blank = {}
  for _ = 1, self.footprint_h do
    blank[#blank + 1] = string.rep(" ", strip_w)
  end
  vim.api.nvim_buf_set_lines(self.buf, 0, -1, false, blank)

  local cfg = window_config(self)
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    vim.api.nvim_win_set_config(self.win, cfg)
  else
    self.win = vim.api.nvim_open_win(self.buf, false, cfg)
    vim.wo[self.win].winblend = 0
    vim.wo[self.win].winhighlight = "Normal:CritterFloat,FloatBorder:CritterFloat,EndOfBuffer:CritterFloat"
    vim.wo[self.win].cursorline = false
    vim.wo[self.win].number = false
    vim.wo[self.win].relativenumber = false
  end
end

-- 描画サイズ (cells) を変更する。キャラ切り替え時に呼ぶ。
-- footprint が変わったら window の高さも揃え直す必要がある。
function Sprite:set_footprint(w, h)
  if w == self.footprint_w and h == self.footprint_h then return end
  self.footprint_w = w
  self.footprint_h = h
  if self.win and vim.api.nvim_win_is_valid(self.win) then self:open() end
end

-- 画像の strip 内 x 位置を変える。歩行ループから毎ティック呼ばれる。
function Sprite:set_image_x(x)
  self.image_x = x
end

-- 現在表示中の画像 (image_id 指定の placement) を画面から消す。
-- delete_action='i' (小文字) = 「画面から消すだけで、転送済みデータは残す」モード。
-- 後でまた表示するときに再転送 (Image:new) が不要になる。
local function delete_placement(img)
  if not img then return end
  terminal.send_graphics_command({
    action = "d",
    delete_action = "i",
    image_id = img.transmit_keys.image_id,
  })
end

function Sprite:clear_image()
  if self.current_img then
    delete_placement(self.current_img)
    self.current_img = nil
  end
end

-- 1フレーム描画。hologram の display を使わず、自前で:
--   1. floating window のスクリーン座標を getwininfo で取る (winrow, wincol は 1始まり)
--   2. image_x ぶん右にずらした位置を計算
--   3. terminal.move_cursor で kitty cursor を移動
--   4. send_graphics_command で「既存 image_id を placement_id=1 で配置」 (action='p')
--   5. cols/rows を渡して footprint サイズに kitty 側でスケール
--
-- 同じ image_id + placement_id で 'p' を送ると、kitty は既存の placement を
-- 新しい位置に上書き = アトミックな移動として扱う。これがゴーストを防ぐ要。
function Sprite:render(path)
  if not (self.win and vim.api.nvim_win_is_valid(self.win)) then
    self:open()
  end

  local img = get_image(path)
  -- 違う Image (= 違う image_id) に切り替わるときは古い placement を消す
  if self.current_img and self.current_img ~= img then
    delete_placement(self.current_img)
  end

  -- floating window のスクリーン座標を取得
  local info = vim.fn.getwininfo(self.win)[1]
  if not info then return end
  local screen_row = info.winrow                  -- 1始まりの top row
  local screen_col = info.wincol + self.image_x   -- window 左端 + image_x のオフセット

  -- !!! 注意: hologram の terminal.move_cursor は内部で
  -- !!!   '\x1b['..row..':'..col..'H'   (←コロン区切り)
  -- !!! を送っているが、ANSI CUP の標準は **セミコロン区切り** (CSI row;colH)。
  -- !!! kitty/ghostty/wezterm のいずれもコロン区切りは認識せず、col 引数が無視されて
  -- !!! カーソルが (row, 1) または (1, 1) に飛ぶ → 画像が左上に張り付く原因。
  -- !!! ここでは hologram の関数は使わず、正しいエスケープを terminal.write で直接送る。
  -- !!! (terminal.write は hologram が握っている tty ハンドルへの薄いラッパー)
  terminal.write("\x1b[s")                                              -- save cursor
  terminal.write(string.format("\x1b[%d;%dH", screen_row, screen_col))  -- CUP (セミコロン)
  terminal.send_graphics_command({
    action          = "p",
    image_id        = img.transmit_keys.image_id,
    placement_id    = 1,                  -- 固定: 同じ id で再 place → アトミック移動
    cols            = self.footprint_w,   -- kitty 側でこのセル幅にスケール
    rows            = self.footprint_h,
    cursor_movement = 1,                  -- 配置後にカーソル位置を動かさない
    quiet           = 2,                  -- 応答抑制 (画面汚れ防止)
  })
  terminal.write("\x1b[u")                                              -- restore cursor

  self.current_img = img
end

-- 画面リサイズ等で位置だけ直したいとき
function Sprite:reposition()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    self:open()
  end
end

function Sprite:close()
  self:clear_image()
  if self.win and vim.api.nvim_win_is_valid(self.win) then
    pcall(vim.api.nvim_win_close, self.win, true)
  end
  self.win = nil
end

return Sprite
