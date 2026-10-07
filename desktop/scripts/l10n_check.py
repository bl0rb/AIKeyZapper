#!/usr/bin/env python3
"""Checks locales/en.json against the German source strings used in the code: l!("…") in Rust, t('…') in ui/*.js.
Exits 1 if a string lacks a translation or placeholders differ. --prune removes translations no longer used."""
import json, pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
RUST = re.compile(r'l!\(\s*"((?:[^"\\]|\\.)*)"')
JS = re.compile(r"""\bt\(\s*(['"])((?:(?!\1)[^\\]|\\.)*)\1""")

def unescape(s): return s.encode().decode('unicode_escape').encode('latin-1').decode('utf-8') if '\\' in s else s

used = {}
for path in list((ROOT / 'core/src').rglob('*.rs')) + list((ROOT / 'src-tauri/src').rglob('*.rs')):
    for m in RUST.finditer(path.read_text()): used.setdefault(unescape(m.group(1)), str(path.relative_to(ROOT)))
for path in (ROOT / 'ui').glob('*.js'):
    for m in JS.finditer(path.read_text()): used.setdefault(unescape(m.group(2)), str(path.relative_to(ROOT)))

table_path = ROOT / 'locales/en.json'
en = json.loads(table_path.read_text())
problems = [f"missing English: {k!r} ({w})" for k, w in sorted(used.items()) if k not in en]
problems += [f"placeholder mismatch: {k!r}" for k in used if k in en and k.count('%@') != en[k].count('%@')]
stale = sorted(k for k in en if k not in used)
if '--prune' in sys.argv:
    table_path.write_text(json.dumps({k: en[k] for k in sorted(en) if k in used}, ensure_ascii=False, indent=1) + '\n')
    print(f"pruned {len(stale)} unused translations")
print('\n'.join(problems) or f"OK: {len(used)} strings translated ({len(stale)} unused in en.json)")
sys.exit(1 if problems else 0)
