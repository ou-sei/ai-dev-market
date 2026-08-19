#!/usr/bin/env bash
# push 前の検証を実行する。プロジェクト形式を検出し、標準的な検証コマンドを走らせる。
#
#   gates.sh
#
# 終了コード:
#   0  合格、または検証コマンドを判別できず実行しなかった（警告を出す）
#   10 不合格（直してコミットし再実行する対象）
#   1  ゲートの実行基盤の問題（直して再実行する対象ではない）
#
# 3 段階で決める。
#   1. <repo-root>/.claude/gh-fix-review.gates.sh があれば、それに委譲する（任意）。
#      上書きファイルはプラグインごとに独立させる（.claude/<プラグイン名>.gates.sh）。
#      共有ファイルにすると、他のプラグイン用に置いた定義がこのプラグインの動作を
#      変えてしまい、単独利用の原則が崩れる（docs/plugin-distribution.md §5）
#   2. 無ければプロジェクト形式を検出して標準的な検証コマンドを実行する
#   3. 検出できなければ警告して 0 を返す（リポジトリ側の準備を必須にしないため）
#
# 段階 1 を用意する理由は速度。実地検証した大規模 Android リポジトリで実測した
# ところ、狙い撃ちのビルド + 単体テストが 3 秒に対し、汎用の ./gradlew test は
# 250 秒だった（触らないフレーバーの kapt まで回るため）。push ごとに毎回走るので
# この差は無視できない。ただし**段階 1 は必須ではない**。無くても段階 2 で動く。
#
# 段階 3 で停止せず 0 を返すのは、プラグインを入れただけで使える状態にするため。
# ただし「何も検証していない」ことは必ず警告に出し、呼び出し側が返信本文と
# ユーザーへの報告に明記する。黙って通さない。
#
# 他のプラグイン（gh-fix-issue など）のファイルは参照しない。片方のプラグインしか
# 入れていない利用者が壊れるため。
#
# bash 3.2 で動くこと（macOS 既定。連想配列・mapfile は使わない）。
set -uo pipefail

EXIT_OK=0
EXIT_FAILED=10
EXIT_ERROR=1

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$ROOT" ]; then
  echo "Git リポジトリの中で実行してください。" >&2
  exit "$EXIT_ERROR"
fi

# 段階 1: リポジトリが専用の上書きを持っていれば、それに委譲する。
# 終了コードはそのまま返す（契約は同じ 0 / 10 / 1）。
OVERRIDE="$ROOT/.claude/gh-fix-review.gates.sh"
if [ -f "$OVERRIDE" ]; then
  echo "== ${OVERRIDE#"$ROOT/"}"
  bash "$OVERRIDE"
  exit $?
fi

# 検証コマンドを実行するディレクトリと、実行するコマンドを決める。
# Git リポジトリルートとビルドルートが異なる構成があるため、ビルドファイルを
# 探して見つかった場所を実行ディレクトリにする（例: リポジトリ直下のサブディレクトリに
# Gradle プロジェクトを置く構成）。
BUILD_DIR=""
GATE_NAME=""
GATE_CMD=""

# 探索は深さ 2 まで。それより深いものは意図した構成ではないとみなす。
find_up_to_depth2() {
  local name="$1"
  local hit
  hit="$(find "$ROOT" -maxdepth 2 -name "$name" -not -path '*/node_modules/*' 2>/dev/null | sort | head -1)"
  printf '%s\n' "$hit"
}

detect() {
  local hit

  # Gradle。test は「全バリアントのユニットテスト」で、多くの構成では
  # assemble/package も依存に含むため、これ一本でビルドとテストを兼ねる。
  hit="$(find_up_to_depth2 gradlew)"
  if [ -n "$hit" ] && [ -x "$hit" ]; then
    BUILD_DIR="$(dirname "$hit")"
    GATE_NAME="gradlew test"
    GATE_CMD="./gradlew test"
    return 0
  fi

  # Node。test スクリプトが定義されているときだけ対象にする。
  hit="$(find_up_to_depth2 package.json)"
  if [ -n "$hit" ] && grep -q '"test"[[:space:]]*:' "$hit" 2>/dev/null; then
    BUILD_DIR="$(dirname "$hit")"
    GATE_NAME="npm test"
    GATE_CMD="npm test"
    return 0
  fi

  # Python。pytest の設定がある場合のみ。
  for f in pytest.ini pyproject.toml setup.cfg tox.ini; do
    hit="$(find_up_to_depth2 "$f")"
    if [ -n "$hit" ] && grep -q 'pytest' "$hit" 2>/dev/null; then
      BUILD_DIR="$(dirname "$hit")"
      GATE_NAME="pytest"
      GATE_CMD="pytest"
      return 0
    fi
  done

  # Make。test ターゲットがある場合のみ。
  hit="$(find_up_to_depth2 Makefile)"
  if [ -n "$hit" ] && grep -qE '^test[[:space:]]*:' "$hit" 2>/dev/null; then
    BUILD_DIR="$(dirname "$hit")"
    GATE_NAME="make test"
    GATE_CMD="make test"
    return 0
  fi

  return 1
}

if ! detect; then
  echo "警告: 検証コマンドを判別できませんでした。ビルドもテストも実行していません。" >&2
  echo "このリポジトリの形式に対応していないか、テスト定義が見つかりません。" >&2
  echo "**検証していないことを返信本文とユーザーへの報告に明記してください。**" >&2
  exit "$EXIT_OK"
fi

cd "$BUILD_DIR" || exit "$EXIT_ERROR"

echo "== ${GATE_NAME} (${BUILD_DIR})"
# シェルのメタ文字を含まない単純なコマンドのみ検出しているので eval で足りる。
if eval "$GATE_CMD"; then
  echo
  echo "ゲートを通過しました: $GATE_NAME"
  exit "$EXIT_OK"
fi

echo
echo "不合格のゲート: $GATE_NAME" >&2
exit "$EXIT_FAILED"
