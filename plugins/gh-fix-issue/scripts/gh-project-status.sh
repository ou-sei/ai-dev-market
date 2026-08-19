#!/usr/bin/env bash
# GitHub Projects (v2) の Status を Issue / PR に対して設定する。
#
#   gh-project-status.sh --check
#   gh-project-status.sh --issue <N> --project <名前> --status <名前> [--dry-run]
#   gh-project-status.sh --pr <N>    --project <名前> --status <名前> [--dry-run]
#
# 終了コード:
#   0  設定できた（--dry-run なら解決できた）
#   30 gh トークンに project スコープが無い
#   1  実行失敗（Project 名・Status 名が見つからない、API エラーなど）
#
# Project ID / フィールド ID / 選択肢 ID は実行時に名前から解決する。
# ハードコードすると Project の選択肢が編集された瞬間に壊れ、しかも
# 「Status が変わらないだけ」で気づけないため。
#
# Status 名は完全一致で探し、見つからなければ絵文字と大小文字を無視して再照合する。
# 同じ組織内でも表記が揺れているため（Android Issues は "🏗 In progress"、
# Android Pull Requests は "In Progress"）。
#
# GraphQL 変数のうち String! / ID! は必ず -f（raw-field）で渡す。-F は "true"/"false"/
# "null"/全桁数字を JSON の型へ変換するため、8桁hex の option ID がたまたま全数字だと
# String! に Int が渡って mutation が型エラーで落ちる。Int! の number だけ -F を使う。
#
# 環境変数（詳細は .claude/scripts/README_ja.md）:
#   GH_PROJECT_ITEMS_FIXTURE   テスト専用。projectItems クエリの応答を差し替える
#                              （設定時はスコープ確認と mutation も行わない）
#   GH_PROJECT_FIELDS_FIXTURE  テスト専用。fields クエリの応答を差し替える
#   GH_BIN                     テスト専用。gh の代わりに実行するコマンド
set -uo pipefail

GH_BIN="${GH_BIN:-gh}"

EXIT_OK=0
EXIT_ERROR=1
EXIT_NO_SCOPE=30

usage() {
  cat >&2 <<'USAGE'
使い方:
  gh-project-status.sh --check
  gh-project-status.sh --issue <N> --project <名前> --status <名前> [--dry-run]
  gh-project-status.sh --pr <N>    --project <名前> --status <名前> [--dry-run]
USAGE
}

has_project_scope() {
  "$GH_BIN" auth status 2>&1 | grep -q "Token scopes:.*'project'"
}

cmd_check() {
  if ! has_project_scope; then
    echo "gh トークンに project スコープがありません。次を実行してください: gh auth refresh -h github.com -s project" >&2
    return "$EXIT_NO_SCOPE"
  fi
  echo "project スコープあり"
  return "$EXIT_OK"
}

# 対象の Issue / PR が所属する Project アイテムを取得する
fetch_items() {
  local kind="$1" number="$2"

  if [ -n "${GH_PROJECT_ITEMS_FIXTURE:-}" ]; then
    cat "$GH_PROJECT_ITEMS_FIXTURE"
    return $?
  fi

  local field="issue"
  [ "$kind" = "pr" ] && field="pullRequest"

  local repo_json owner repo err
  if ! repo_json="$("$GH_BIN" repo view --json owner,name 2>/dev/null)"; then
    echo "リポジトリ情報を取得できませんでした。" >&2
    return 1
  fi
  owner="$(printf '%s' "$repo_json" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).owner.login))')"
  repo="$(printf '%s' "$repo_json" | node -e 'let s="";process.stdin.on("data",d=>s+=d);process.stdin.on("end",()=>process.stdout.write(JSON.parse(s).name))')"

  local out
  if ! out="$("$GH_BIN" api graphql -f query="
query(\$owner:String!,\$repo:String!,\$number:Int!){
  repository(owner:\$owner,name:\$repo){
    $field(number:\$number){
      projectItems(first:20){
        nodes{ id project{ id title } }
      }
    }
  }
}" -f owner="$owner" -f repo="$repo" -F number="$number" 2>/tmp/gh-project-status-err.$$)"; then
    err="$(cat /tmp/gh-project-status-err.$$ 2>/dev/null)"
    rm -f /tmp/gh-project-status-err.$$
    echo "Project 情報の取得に失敗しました: ${err}" >&2
    return 1
  fi
  rm -f /tmp/gh-project-status-err.$$
  printf '%s' "$out"
}

# Project の単一選択フィールド（Status）を取得する
fetch_fields() {
  local project_id="$1"

  if [ -n "${GH_PROJECT_FIELDS_FIXTURE:-}" ]; then
    cat "$GH_PROJECT_FIELDS_FIXTURE"
    return $?
  fi

  local out err
  if ! out="$("$GH_BIN" api graphql -f query='
query($id:ID!){
  node(id:$id){
    ... on ProjectV2 {
      fields(first:50){
        nodes{
          ... on ProjectV2SingleSelectField { id name options { id name } }
        }
      }
    }
  }
}' -f id="$project_id" 2>/tmp/gh-project-status-err.$$)"; then
    err="$(cat /tmp/gh-project-status-err.$$ 2>/dev/null)"
    rm -f /tmp/gh-project-status-err.$$
    echo "フィールド情報の取得に失敗しました: ${err}" >&2
    return 1
  fi
  rm -f /tmp/gh-project-status-err.$$
  printf '%s' "$out"
}

# projectItems の応答から、指定した Project 名に一致するアイテムを選ぶ。
# 出力: "<item-id>\t<project-id>"
pick_item() {
  local wanted="$1"
  node -e '
const wanted = process.argv[1];
let raw = "";
process.stdin.on("data", (d) => { raw += d; });
process.stdin.on("end", () => {
  let data;
  try { data = JSON.parse(raw); } catch (e) {
    console.error("Project 情報の JSON を解釈できませんでした。");
    process.exit(1);
  }
  const container = data?.data?.repository?.issue ?? data?.data?.repository?.pullRequest;
  // 「見つからない」と「どこにも登録されていない」を分ける。前者は番号の取り違え
  // （issue 番号を --pr に渡した等）で起きるため、原因が違えば文言も分ける。
  if (!container) {
    console.error("指定された番号の issue / pull request が見つかりません。--issue と --pr を取り違えていませんか。");
    process.exit(1);
  }
  const nodes = container?.projectItems?.nodes ?? [];
  if (nodes.length === 0) {
    console.error("対象はどの Project にも登録されていません。作成直後は自動追加が完了していない場合があります。");
    process.exit(1);
  }
  const hit = nodes.find((n) => n.project?.title === wanted);
  if (!hit) {
    console.error(`Project "${wanted}" に登録されていません。所属: ${nodes.map((n) => n.project?.title).join(" / ")}`);
    process.exit(1);
  }
  process.stdout.write(`${hit.id}\t${hit.project.id}`);
});' "$wanted"
}

# fields の応答から Status フィールドと選択肢を解決する。
# 出力: "<field-id>\t<option-id>"
pick_option() {
  local wanted="$1"
  node -e '
const wanted = process.argv[1];
// 絵文字・記号・大小文字の揺れを吸収する（"🏗 In progress" と "In Progress" を同一視）
const norm = (s) => String(s).toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
let raw = "";
process.stdin.on("data", (d) => { raw += d; });
process.stdin.on("end", () => {
  let data;
  try { data = JSON.parse(raw); } catch (e) {
    console.error("フィールド情報の JSON を解釈できませんでした。");
    process.exit(1);
  }
  const fields = (data?.data?.node?.fields?.nodes ?? []).filter((f) => f && f.name);
  const status = fields.find((f) => f.name === "Status") ?? fields.find((f) => norm(f.name) === "status");
  if (!status) {
    console.error(`Status フィールドが見つかりません。存在するフィールド: ${fields.map((f) => f.name).join(" / ")}`);
    process.exit(1);
  }
  const options = status.options ?? [];
  let hit = options.find((o) => o.name === wanted);
  // 正規化が空文字に潰れる入力（絵文字のみ等）でフォールバックすると、
  // 名前を指定していないのに1件だけ一致して選ばれてしまう。完全一致のみ許す。
  if (!hit && norm(wanted) === "") {
    console.error(`Status "${wanted}" が見つかりません。選択肢: ${options.map((o) => o.name).join(" / ")}`);
    process.exit(1);
  }
  if (!hit) {
    const matches = options.filter((o) => norm(o.name) === norm(wanted));
    if (matches.length > 1) {
      console.error(`Status "${wanted}" が複数の選択肢に一致しました: ${matches.map((o) => o.name).join(" / ")}`);
      process.exit(1);
    }
    hit = matches[0];
  }
  if (!hit) {
    console.error(`Status "${wanted}" が見つかりません。選択肢: ${options.map((o) => o.name).join(" / ")}`);
    process.exit(1);
  }
  process.stdout.write(`${status.id}\t${hit.id}`);
});' "$wanted"
}

set_status() {
  local project_id="$1" item_id="$2" field_id="$3" option_id="$4"

  # fixture 使用時に本物の gh へ mutation を投げてしまう事故を防ぐ。
  # ただし GH_BIN が差し替えられている場合はモックが受けるので通す
  # （mutation の引数そのものを検証するテストのため）。
  if [ -n "${GH_PROJECT_ITEMS_FIXTURE:-}" ] && [ "$GH_BIN" = "gh" ]; then
    return 0
  fi

  # stderr は捨てない。無人実行では、この文字列だけが失敗原因の手がかりになる。
  local err
  if ! err="$("$GH_BIN" api graphql -f query='
mutation($project:ID!,$item:ID!,$field:ID!,$option:String!){
  updateProjectV2ItemFieldValue(input:{
    projectId:$project, itemId:$item, fieldId:$field,
    value:{ singleSelectOptionId:$option }
  }){ projectV2Item { id } }
}' -f project="$project_id" -f item="$item_id" -f field="$field_id" -f option="$option_id" 2>&1 >/dev/null)"; then
    printf '%s' "$err"
    return 1
  fi
  return 0
}

main() {
  local kind="" number="" project="" status="" dry_run=""

  # 値を必ず伴うフラグ。値が無いまま shift 2 すると、bash は何も言わずに失敗するため、
  # 「終了コード 1 だけで理由が無い」状態になる。それを防ぐ。
  need_value() {
    if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
      echo "$1 には値が必要です。" >&2
      return 1
    fi
    return 0
  }

  local do_check=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --check) do_check="1"; shift ;;
      --issue) need_value "$@" || return "$EXIT_ERROR"; kind="issue"; number="$2"; shift 2 ;;
      --pr)    need_value "$@" || return "$EXIT_ERROR"; kind="pr";    number="$2"; shift 2 ;;
      --project) need_value "$@" || return "$EXIT_ERROR"; project="$2"; shift 2 ;;
      --status)  need_value "$@" || return "$EXIT_ERROR"; status="$2";  shift 2 ;;
      --dry-run) dry_run="1"; shift ;;
      *) echo "不明な引数: $1" >&2; usage; return "$EXIT_ERROR" ;;
    esac
  done

  if [ -n "$do_check" ]; then
    cmd_check
    return $?
  fi

  if [ -z "$kind" ] || [ -z "$number" ] || [ -z "$project" ] || [ -z "$status" ]; then
    usage
    return "$EXIT_ERROR"
  fi
  if ! [[ "$number" =~ ^[0-9]+$ ]]; then
    echo "番号は数値で指定してください: $number" >&2
    return "$EXIT_ERROR"
  fi

  # fixture 使用時はスコープ確認を飛ばす（テストは API を呼ばないため）
  if [ -z "${GH_PROJECT_ITEMS_FIXTURE:-}" ] && ! has_project_scope; then
    echo "gh トークンに project スコープがありません。次を実行してください: gh auth refresh -h github.com -s project" >&2
    return "$EXIT_NO_SCOPE"
  fi

  local items_json
  if ! items_json="$(fetch_items "$kind" "$number")"; then
    return "$EXIT_ERROR"
  fi

  local picked item_id project_id
  if ! picked="$(printf '%s' "$items_json" | pick_item "$project")"; then
    return "$EXIT_ERROR"
  fi
  item_id="${picked%%$'\t'*}"
  project_id="${picked##*$'\t'}"

  local fields_json
  if ! fields_json="$(fetch_fields "$project_id")"; then
    return "$EXIT_ERROR"
  fi

  local resolved field_id option_id
  if ! resolved="$(printf '%s' "$fields_json" | pick_option "$status")"; then
    return "$EXIT_ERROR"
  fi
  field_id="${resolved%%$'\t'*}"
  option_id="${resolved##*$'\t'}"

  if [ -n "$dry_run" ]; then
    echo "item=$item_id project=$project_id field=$field_id option=$option_id"
    return "$EXIT_OK"
  fi

  local mutation_err
  if ! mutation_err="$(set_status "$project_id" "$item_id" "$field_id" "$option_id")"; then
    echo "Status の更新に失敗しました（${project} → ${status}）: ${mutation_err}" >&2
    return "$EXIT_ERROR"
  fi

  # 変数は必ず ${} で囲む。全角文字が直後に続くと変数名に取り込まれ、
  # set -u と組み合わさって "unbound variable" で落ちる。
  echo "${project} の Status を「${status}」に設定しました (#${number})。"
  return "$EXIT_OK"
}

main "$@"
exit $?
