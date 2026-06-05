-- critter.nvim / critters/init.lua
-- キャラクターのレジストリ。新しい子を追加するときは、
--   1. sprites/<name>/ に PNG を置く
--   2. lua/critter/critters/<name>.lua を作る
--   3. この available テーブルに名前を足す
-- の3ステップだけで済む。

local M = {}

-- 使えるキャラ名のリスト (識別子なのでファイル名と一致させる)
M.available = {
  "mame",
  "dog",
  "clippy",
  "crab",
  "snake",
  "rubber_duck",
}

-- 名前から仕様 (frames テーブル等) を取り出す。未知の名前なら nil。
function M.load(name)
  local ok, spec = pcall(require, "critter.critters." .. name)
  if not ok then return nil end
  return spec
end

return M
