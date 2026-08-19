#!/usr/bin/env node
// ktlint の CHECKSTYLE レポートと git diff を突き合わせ、
// 「変更ファイルの追加行」に該当する違反だけを報告する。
//
//   node ktlint-diff.mjs --report-dir <dir> --base <ref> [--diff-file <path>] [--repo-root <path>]
//
// 終了コード: 0 = 違反なし / 10 = 違反あり / 1 = 実行失敗
//
// Gradle 側で ignoreFailures.set(true) になっているリポジトリでは
// ktlintCheck の終了コードは使えない。既存違反も無視する必要がある。

import { readdirSync, readFileSync } from "node:fs";
import { join, relative, isAbsolute } from "node:path";
import { execFileSync } from "node:child_process";

function parseArgs(argv) {
  const opts = {};
  for (let i = 0; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key || !key.startsWith("--")) continue;
    opts[key.slice(2)] = value;
  }
  return opts;
}

function collectXmlFiles(dir) {
  const out = [];
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return out;
  }
  for (const entry of entries) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...collectXmlFiles(full));
    else if (entry.name.endsWith(".xml")) out.push(full);
  }
  return out;
}

function parseCheckstyle(xml) {
  const violations = [];
  const fileRe = /<file name="([^"]+)">([\s\S]*?)<\/file>/g;
  const errorRe = /<error\b([^>]*?)\/>/g;
  const attrRe = /([\w-]+)="([^"]*)"/g;

  let fileMatch;
  while ((fileMatch = fileRe.exec(xml)) !== null) {
    const file = fileMatch[1];
    const body = fileMatch[2];
    let errorMatch;
    while ((errorMatch = errorRe.exec(body)) !== null) {
      const attrs = {};
      let attrMatch;
      while ((attrMatch = attrRe.exec(errorMatch[1])) !== null) {
        attrs[attrMatch[1]] = attrMatch[2];
      }
      violations.push({
        file,
        line: Number(attrs.line || 0),
        message: attrs.message || "",
        source: attrs.source || ""
      });
    }
  }
  return violations;
}

// git diff -U0 の出力から「ファイル -> 追加された行番号の集合」を作る
function parseAddedLines(diffText) {
  const map = new Map();
  let current = null;
  for (const line of diffText.split("\n")) {
    if (line.startsWith("+++ ")) {
      const target = line.slice(4).trim();
      current = target === "/dev/null" ? null : target.replace(/^b\//, "");
      if (current) map.set(current, new Set());
      continue;
    }
    if (line.startsWith("@@") && current) {
      const m = /\+(\d+)(?:,(\d+))?/.exec(line);
      if (!m) continue;
      const start = Number(m[1]);
      const count = m[2] === undefined ? 1 : Number(m[2]);
      const set = map.get(current);
      for (let i = 0; i < count; i += 1) set.add(start + i);
    }
  }
  return map;
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  const reportDir = opts["report-dir"];
  const repoRoot = opts["repo-root"] || process.cwd();

  if (!reportDir) {
    console.error("--report-dir は必須です");
    return 1;
  }

  let diffText;
  if (opts["diff-file"]) {
    diffText = readFileSync(opts["diff-file"], "utf8");
  } else {
    if (!opts.base) {
      console.error("--base または --diff-file が必要です");
      return 1;
    }
    diffText = execFileSync("git", ["diff", "-U0", `${opts.base}...HEAD`], {
      cwd: repoRoot,
      encoding: "utf8",
      maxBuffer: 64 * 1024 * 1024
    });
  }

  const addedLines = parseAddedLines(diffText);

  const xmlFiles = collectXmlFiles(reportDir);
  if (xmlFiles.length === 0) {
    console.error(`ktlint レポートが見つかりません: ${reportDir}`);
    return 1;
  }

  const violations = [];
  for (const xmlPath of xmlFiles) {
    violations.push(...parseCheckstyle(readFileSync(xmlPath, "utf8")));
  }

  // checkstyle の絶対パスを --repo-root で相対化する。--repo-root が正しければ
  // 結果はリポジトリ内の相対パス（"app/src/..." のように "." や ".." で始まらない）になる。
  // --repo-root が噛み合っていなければ "../" で始まる（または絶対パスのまま）になる。
  // これは diff の内容には依存しない判定なので、diff が空でも Kotlin を
  // 触っていない diff でも誤検知しない。
  const normalized = violations.map((v) => {
    const rel = isAbsolute(v.file) ? relative(repoRoot, v.file) : v.file;
    const outsideRepoRoot = isAbsolute(v.file) && (rel.startsWith("..") || isAbsolute(rel));
    return { ...v, rel, outsideRepoRoot };
  });

  if (normalized.length > 0 && normalized.every((v) => v.outsideRepoRoot)) {
    const sample = normalized[0];
    console.error(
      "checkstyle のパスが --repo-root の配下に収まりません。--repo-root を確認してください"
    );
    console.error(`  checkstyle 側の例: ${sample.file}`);
    console.error(`  --repo-root:       ${repoRoot}`);
    console.error(`  相対化結果:        ${sample.rel}`);
    return 1;
  }

  const hits = [];
  for (const v of normalized) {
    const lines = addedLines.get(v.rel);
    if (!lines) continue;
    if (!lines.has(v.line)) continue;
    hits.push(v);
  }

  if (hits.length === 0) {
    console.log("ktlint: 追加行に新規違反はありません。");
    return 0;
  }

  console.log(`ktlint: 追加行に ${hits.length} 件の違反があります。`);
  for (const h of hits) {
    console.log(`  ${h.rel}:${h.line} ${h.message} (${h.source})`);
  }
  return 10;
}

process.exit(main());
