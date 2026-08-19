#!/usr/bin/env python3
"""marketplace.json と plugins/ の対応を検証する。

    python3 tests/check-manifests.py [<repo-root>]

終了コード:
    0  整合している
    1  不整合がある（登録漏れ・参照切れ・name/version の不一致）
    2  実行できなかった（JSON が壊れている、ファイルが無い）

ツールが増えるほど人手での管理が破綻するため CI で機械的に見る。
登録漏れを放置すると、そのツールは誰にも配布されないまま CI が緑で通る。
"""
import io
import json
import os
import sys


def fail(msg):
    print(msg, file=sys.stderr)


def load(path):
    with io.open(path, encoding="utf-8") as f:
        return json.load(f)


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else os.getcwd()
    market_path = os.path.join(root, ".claude-plugin", "marketplace.json")

    try:
        market = load(market_path)
    except FileNotFoundError:
        fail("marketplace.json が見つかりません: %s" % market_path)
        return 2
    except ValueError as e:
        fail("marketplace.json が JSON として読めません: %s" % e)
        return 2

    entries = market.get("plugins")
    if not isinstance(entries, list):
        fail("marketplace.json に plugins 配列がありません。")
        return 2

    problems = 0
    registered = set()

    # marketplace の各エントリ -> 実体があるか
    for entry in entries:
        name = entry.get("name")
        source = entry.get("source")
        if not name or not source:
            fail("plugins のエントリに name または source がありません: %r" % entry)
            problems += 1
            continue
        registered.add(name)

        plugin_dir = os.path.normpath(os.path.join(root, source))
        manifest = os.path.join(plugin_dir, ".claude-plugin", "plugin.json")
        if not os.path.isdir(plugin_dir):
            fail("%s の source が指すディレクトリがありません: %s" % (name, source))
            problems += 1
            continue
        if not os.path.isfile(manifest):
            fail("%s に plugin.json がありません: %s" % (name, manifest))
            problems += 1
            continue

        try:
            plugin = load(manifest)
        except ValueError as e:
            fail("%s の plugin.json が JSON として読めません: %s" % (name, e))
            problems += 1
            continue

        if plugin.get("name") != name:
            fail("%s: marketplace の name と plugin.json の name が違います (%r)"
                 % (name, plugin.get("name")))
            problems += 1
        if entry.get("version") is not None and plugin.get("version") != entry.get("version"):
            fail("%s: marketplace の version %r と plugin.json の version %r が違います"
                 % (name, entry.get("version"), plugin.get("version")))
            problems += 1

    # plugins/ の各ディレクトリ -> marketplace に登録されているか
    plugins_root = os.path.join(root, "plugins")
    if os.path.isdir(plugins_root):
        for name in sorted(os.listdir(plugins_root)):
            if name.startswith("."):
                continue
            if not os.path.isdir(os.path.join(plugins_root, name)):
                continue
            if name not in registered:
                fail("plugins/%s が marketplace.json に登録されていません。"
                     "このままでは誰にも配布されません。" % name)
                problems += 1

    if problems:
        fail("")
        fail("不整合が %d 件あります。" % problems)
        return 1

    print("marketplace.json と plugins/ は整合しています（プラグイン %d 件）。" % len(entries))
    return 0


if __name__ == "__main__":
    sys.exit(main())
