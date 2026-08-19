#!/usr/bin/env bash
# GitHub PR の Review comment スレッドを扱う。
#
#   pr-reply.sh --check   [--pr N]
#   pr-reply.sh --list    [--pr N]
#   pr-reply.sh --verify  [--pr N]
#   pr-reply.sh --reply <comment_id> --body-file <path>
#
# 終了コード:
#   0  未返信なし / 投稿成功 / 前提確認 OK
#   10 未返信あり
#   30 gh が使えない / PR が見つからない / カレントブランチが PR の head でない
#   1  実行失敗
#
# 環境変数:
#   PR_REPLY_FIXTURE  テスト専用。gh を呼ばずこの JSON をコメント一覧として使う
#   PR_REPLY_SELF     テスト専用。gh api user の代わりに使うログイン名
#
# 判定ロジックは threads.jq に閉じ込める。このスクリプトは入出力と終了コードだけを担う。
# bash 3.2 で動かすこと（連想配列と mapfile は使わない）。
set -uo pipefail

EXIT_OK=0
EXIT_UNREPLIED=10
EXIT_UNAVAILABLE=30
EXIT_ERROR=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THREADS_JQ="$SCRIPT_DIR/threads.jq"

MODE=""
PR_NUMBER=""
REPLY_ID=""
BODY_FILE=""
PR_HEAD_REF=""

usage() {
  sed -n '4,7p' "$0" >&2
}

set_mode() {
  if [ -n "$MODE" ]; then
    echo "モードは1つだけ指定してください。" >&2
    exit "$EXIT_ERROR"
  fi
  MODE="$1"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --check)  set_mode check;  shift ;;
    --list)   set_mode list;   shift ;;
    --verify) set_mode verify; shift ;;
    --reply)
      set_mode reply; shift
      if [ $# -eq 0 ]; then
        echo "--reply には comment_id が必要です。" >&2
        exit "$EXIT_ERROR"
      fi
      REPLY_ID="$1"; shift ;;
    --pr)
      shift
      if [ $# -eq 0 ]; then
        echo "--pr には PR 番号が必要です。" >&2
        exit "$EXIT_ERROR"
      fi
      PR_NUMBER="$1"; shift ;;
    --body-file)
      shift
      if [ $# -eq 0 ]; then
        echo "--body-file にはパスが必要です。" >&2
        exit "$EXIT_ERROR"
      fi
      BODY_FILE="$1"; shift ;;
    -h|--help) usage; exit "$EXIT_OK" ;;
    *) echo "不明な引数: $1" >&2; usage; exit "$EXIT_ERROR" ;;
  esac
done

if [ -z "$MODE" ]; then
  echo "モードを指定してください。" >&2
  usage
  exit "$EXIT_ERROR"
fi

if [ "$MODE" = "reply" ] && [ -z "$BODY_FILE" ]; then
  echo "--reply には --body-file が必要です。" >&2
  exit "$EXIT_ERROR"
fi

# 自分のログイン名。テストでは PR_REPLY_SELF で差し替える。
self_login() {
  if [ -n "${PR_REPLY_SELF:-}" ]; then
    echo "警告: PR_REPLY_SELF が設定されています。この判定は実際の GitHub では検証されていません。" >&2
    printf '%s\n' "$PR_REPLY_SELF"
    return 0
  fi
  gh api user --jq .login 2>/dev/null
}

# PR 番号と head ブランチを解決する。--pr 指定があればそれを使う。
resolve_pr() {
  local json
  if [ -n "$PR_NUMBER" ]; then
    PR_HEAD_REF="$(gh pr view "$PR_NUMBER" --json headRefName --jq .headRefName 2>/dev/null)" || return 1
  else
    json="$(gh pr view --json number,headRefName 2>/dev/null)" || return 1
    PR_NUMBER="$(printf '%s' "$json" | jq -r .number)"
    PR_HEAD_REF="$(printf '%s' "$json" | jq -r .headRefName)"
  fi
  [ -n "$PR_NUMBER" ] && [ "$PR_NUMBER" != "null" ] && [ -n "$PR_HEAD_REF" ] && [ "$PR_HEAD_REF" != "null" ]
}

# PR を解決できなければ 30 を返す。同じ判定を3箇所で行うため関数にまとめる。
require_pr() {
  if ! resolve_pr; then
    echo "PR が見つかりません。--pr で番号を指定するか、PR のあるブランチで実行してください。" >&2
    return "$EXIT_UNAVAILABLE"
  fi
}

# コメント一覧を JSON 配列で返す。取得に失敗したら 1 を返す。
#
# gh api は 404 などで終了コード 1 を返しつつエラー本文を stdout に出す。それを
# そのまま jq -s に流すと中身が null のスレッドが1件でっち上がり、stdout が空の
# ケースでは jq -s が [] を返して「未返信なし(0)」になってしまう。どちらも
# --verify の保証を壊すので、gh の終了コードで判定する。
# stderr は握りつぶさない（gh のエラーメッセージは診断に必要）。
fetch_comments() {
  if [ -n "${PR_REPLY_FIXTURE:-}" ]; then
    echo "警告: PR_REPLY_FIXTURE が設定されています。この判定は実際の GitHub では検証されていません。" >&2
    cat "$PR_REPLY_FIXTURE" || return 1
    return 0
  fi
  local raw
  raw="$(gh api --paginate "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments" --jq '.[]')" || return 1
  printf '%s' "$raw" | jq -s '.'
}

# 未返信スレッドの JSON を標準出力に出す。
unreplied_json() {
  local self comments
  self="$(self_login)"
  if [ -z "$self" ]; then
    echo "自分のログイン名を取得できません。gh auth login を実行してください。" >&2
    return "$EXIT_UNAVAILABLE"
  fi
  if [ -z "${PR_REPLY_FIXTURE:-}" ]; then
    require_pr || return $?
  fi
  if ! comments="$(fetch_comments)"; then
    echo "コメント一覧を取得できません。" >&2
    return "$EXIT_UNAVAILABLE"
  fi
  if [ -z "$comments" ]; then
    echo "コメント一覧を取得できません。" >&2
    return "$EXIT_UNAVAILABLE"
  fi
  # 取得できたものが本当にコメント配列かを確かめる。gh がエラー本文を stdout に
  # 出した場合、jq -s に包まれて形は配列になるが要素が id を持たない。これを
  # 通すと中身が null のスレッドがでっち上がる。
  if ! printf '%s' "$comments" | jq -e 'type == "array" and all(.[]; has("id"))' >/dev/null 2>&1; then
    echo "コメント一覧の形式が不正です（GitHub のエラー応答の可能性があります）。" >&2
    return "$EXIT_UNAVAILABLE"
  fi
  printf '%s' "$comments" | jq --arg self "$self" -f "$THREADS_JQ"
}

cmd_list() {
  unreplied_json
}

cmd_verify() {
  local out count
  out="$(unreplied_json)" || return $?
  count="$(printf '%s' "$out" | jq 'length')"
  if [ "$count" -eq 0 ]; then
    echo "未返信スレッドはありません。"
    return "$EXIT_OK"
  fi
  echo "未返信スレッドが ${count} 件あります:" >&2
  printf '%s' "$out" | jq -r '.[] | "  #\(.thread_root_id) \(.path):\(.line)  \(.url)"' >&2
  return "$EXIT_UNREPLIED"
}

cmd_check() {
  if ! gh auth status >/dev/null 2>&1; then
    echo "gh が未認証です。gh auth login を実行してください。" >&2
    return "$EXIT_UNAVAILABLE"
  fi

  # threads.jq は INDEX を使う。バージョン文字列ではなく機能の有無を直接試す。
  if ! echo '[]' | jq 'INDEX(.id)' >/dev/null 2>&1; then
    echo "jq が使えないか古すぎます（INDEX が必要。jq 1.6 以上）。" >&2
    return "$EXIT_UNAVAILABLE"
  fi

  require_pr || return $?

  local branch
  branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  if [ "$branch" != "$PR_HEAD_REF" ]; then
    echo "カレントブランチ ($branch) が PR #$PR_NUMBER の head ($PR_HEAD_REF) と一致しません。" >&2
    return "$EXIT_UNAVAILABLE"
  fi

  if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    echo "未コミットの変更があります。コミットまたは退避してから実行してください。" >&2
    return "$EXIT_UNAVAILABLE"
  fi

  echo "PR #$PR_NUMBER ($PR_HEAD_REF) / 作業ツリーはクリーンです。"
  return "$EXIT_OK"
}

cmd_reply() {
  if [ ! -f "$BODY_FILE" ]; then
    echo "本文ファイルが見つかりません: $BODY_FILE" >&2
    return "$EXIT_ERROR"
  fi
  if [ ! -s "$BODY_FILE" ]; then
    echo "本文ファイルが空です: $BODY_FILE" >&2
    return "$EXIT_ERROR"
  fi

  if ! gh auth status >/dev/null 2>&1; then
    echo "gh が未認証です。gh auth login を実行してください。" >&2
    return "$EXIT_UNAVAILABLE"
  fi

  require_pr || return $?

  # 本文は jq -Rs で JSON 文字列に包む。gh の -F は値の型を推測するため、
  # 本文が数値や true に見える内容だったときに型が変わるのを避ける。
  if ! jq -Rs '{body: .}' < "$BODY_FILE" \
      | gh api --method POST \
          "repos/{owner}/{repo}/pulls/$PR_NUMBER/comments/$REPLY_ID/replies" \
          --input - >/dev/null; then
    echo "返信の投稿に失敗しました: comment_id=$REPLY_ID" >&2
    return "$EXIT_ERROR"
  fi

  echo "返信しました: PR #$PR_NUMBER / comment_id=$REPLY_ID"
  return "$EXIT_OK"
}

case "$MODE" in
  check)  cmd_check; exit $? ;;
  list)   cmd_list;   exit $? ;;
  verify) cmd_verify; exit $? ;;
  reply)  cmd_reply; exit $? ;;
esac
