-- critter.nvim / util.lua
-- 共通の小道具。

local M = {}

-- PNG ファイルから幅と高さ (px) を読む。
-- PNG の構造: 8バイトのシグネチャ + IHDR チャンクの先頭に幅(4B BE)と高さ(4B BE)。
-- なので先頭24バイト読めば足りる。
function M.png_dims(path)
  local f = io.open(path, "rb")
  if not f then return nil, nil end
  local data = f:read(24)
  f:close()
  if not data or #data < 24 then return nil, nil end
  local b1, b2, b3, b4, b5, b6, b7, b8 = data:byte(17, 24)
  local w = b1 * 0x1000000 + b2 * 0x10000 + b3 * 0x100 + b4
  local h = b5 * 0x1000000 + b6 * 0x10000 + b7 * 0x100 + b8
  return w, h
end

-- 画像のピクセル比 (w/h) と「ターミナルのセル比 (幅/高さ ≈ 0.5)」から、
-- 高さ height cells のときに必要な幅 cells を返す。
-- 一般的な等幅フォントは「セル高さ ≈ セル幅の2倍」なので、画像の見た目を
-- 保つには cells_w = (px_w / px_h) * 2 * cells_h になる。
function M.fit_width_cells(px_w, px_h, height_cells)
  if not px_w or not px_h or px_h == 0 then return height_cells end
  local w = (px_w / px_h) * 2 * height_cells
  -- ターミナルは整数 cell しか取れないので四捨五入。最低1は確保。
  return math.max(1, math.floor(w + 0.5))
end

return M
