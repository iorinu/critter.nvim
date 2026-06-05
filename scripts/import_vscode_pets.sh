#!/usr/bin/env bash
# vscode-pets (MIT) の GIF アニメを critter.nvim 用の PNG 連番に展開するスクリプト。
#
# 使い方:
#   1. 事前に vscode-pets を git clone しておく
#        git clone --depth 1 https://github.com/tonybaloney/vscode-pets /tmp/vscode-pets
#   2. このリポジトリのルートで実行:
#        VSCODE_PETS=/tmp/vscode-pets ./scripts/import_vscode_pets.sh
#
# 出力先: sprites/<critter>/<mood>_<N>.png
#
# critter.nvim の mood と vscode-pets のアクションの対応:
#   idle      <- idle      (アイドルアニメをそのまま)
#   happy     <- swipe     (元気な仕草に流用)
#   celebrate <- with_ball (一番派手なやつ)
#   sad       <- walk      (とぼとぼ歩くを「しょんぼり」として流用)
#   sleep     <- lie       (dog のみ。他は idle の1枚目を流用)

set -euo pipefail

: "${VSCODE_PETS:?VSCODE_PETS にローカルにcloneした vscode-pets のパスを指定してください}"

if ! command -v magick >/dev/null 2>&1; then
  echo "magick (ImageMagick) が必要です: brew install imagemagick" >&2
  exit 1
fi

# critter名, vscode-pets内のディレクトリ, デフォルトvariant
CRITTERS=(
  "dog dog akita"
  "clippy clippy brown"
  "crab crab red"
  "snake snake green"
  "rubber_duck rubber-duck yellow"
)

# critterの mood と、対応する vscode-pets のアクション名
# (sleep は別扱い: dog だけ lie、他は idle 1枚目)
declare -a MOOD_MAP=(
  "idle:idle"
  "happy:swipe"
  "celebrate:with_ball"
  "sad:walk"
)

repo_root="$(cd "$(dirname "$0")/.." && pwd)"

for spec in "${CRITTERS[@]}"; do
  read -r critter src_dir variant <<<"$spec"
  src="$VSCODE_PETS/media/$src_dir"
  out="$repo_root/sprites/$critter"
  mkdir -p "$out"
  echo "==> $critter ($src_dir/$variant) -> $out"

  for entry in "${MOOD_MAP[@]}"; do
    mood="${entry%%:*}"
    action="${entry##*:}"
    gif="$src/${variant}_${action}_8fps.gif"
    if [[ ! -f "$gif" ]]; then
      echo "  skip $mood ($gif が無い)" >&2
      continue
    fi
    # GIFを座標統一(coalesce)して連番PNGに展開。1始まりにしておくとLuaから扱いやすい
    magick "$gif" -coalesce "$out/${mood}_%d.png"
    # ImageMagickは 0 始まりなので 1 始まりにリネーム
    i=0
    for f in "$out/${mood}_"*.png; do
      i=$((i+1))
    done
    # 並び替え: 0..N-1 -> 1..N
    n=$(ls "$out/${mood}_"*.png 2>/dev/null | wc -l | tr -d ' ')
    for ((j=n-1; j>=0; j--)); do
      mv "$out/${mood}_${j}.png" "$out/${mood}_$((j+1)).png"
    done
    echo "  $mood: $n frames"
  done

  # sleep: dog は lie、他は idle の1枚目を流用
  sleep_gif="$src/${variant}_lie_8fps.gif"
  if [[ -f "$sleep_gif" ]]; then
    magick "$sleep_gif" -coalesce "$out/sleep_%d.png"
    n=$(ls "$out/sleep_"*.png 2>/dev/null | wc -l | tr -d ' ')
    for ((j=n-1; j>=0; j--)); do
      mv "$out/sleep_${j}.png" "$out/sleep_$((j+1)).png"
    done
    echo "  sleep: $n frames (lie)"
  else
    cp "$out/idle_1.png" "$out/sleep_1.png"
    echo "  sleep: 1 frame (idle_1 流用)"
  fi
done

# 左向き版を生成 (歩いて向きを変えるため)
# magick -flop で左右反転した PNG を <mood>_<N>_left.png として並べておく
echo
echo "==> 左右反転版を生成中"
for f in "$repo_root"/sprites/*/*.png; do
  base="${f%.png}"
  [[ "$base" == *_left ]] && continue
  [[ -f "${base}_left.png" ]] && continue
  magick "$f" -flop "${base}_left.png"
done

echo
echo "完了。sprites/ の下に各critterのフレームが展開されました。"
