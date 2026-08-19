# 未返信の Review comment スレッドを返す。
#
#   jq --arg self "<ログイン名>" -f threads.jq <コメント配列>
#
# 入力は GitHub REST の /pulls/{n}/comments のレスポンス（配列）。
#
# in_reply_to_id が起点を指すか直前のコメントを指すかは保証されていないため、
# 推移的に辿って起点に集約する。どちらでも同じ結果になる。
#
# 未返信の定義:
#   - 起点コメントの author が自分のスレッドは対象外（自分の指摘に自分で返信させない）
#   - スレッド内で created_at が最大のコメントの author が自分でなければ未返信
#
# outdated（position が null）なスレッドも対象に含める。差分がずれても指摘は指摘であり、
# 返信自体は可能なため。line は null になるので original_line にフォールバックする。

INDEX(.id | tostring) as $map
| def root_id($c; $depth):
    if $depth > 100 then error("in_reply_to_id が循環しています: id=\($c.id)")
    elif ($c.in_reply_to_id == null) then $c.id
    else ($map[($c.in_reply_to_id | tostring)]) as $p
      | if $p == null then $c.id else root_id($p; $depth + 1) end
    end;
  [ .[] | . + {_root: root_id(.; 0)} ]
| group_by(._root)
| map(
    sort_by(.created_at) as $cs
    | ($cs[0]._root) as $rid
    # root_id は親が見つからなければ自分自身の id を返すため、起点は必ずグループ内に
    # 存在する。この // $cs[0] は到達不能（フォールバック先が無いことの明示）。
    | (($cs | map(select(.id == $rid)) | first) // $cs[0]) as $root
    | ($cs | last) as $lastc
    | {
        thread_root_id: $rid,
        path: $root.path,
        line: ($root.line // $root.original_line),
        outdated: ($root.position == null),
        url: $root.html_url,
        root_author: $root.user.login,
        last_author: $lastc.user.login,
        body: $root.body,
        comments: ($cs | map({id: .id, author: .user.login, created_at: .created_at, body: .body}))
      }
  )
| map(select(.root_author != $self))
| map(select(.last_author != $self))
