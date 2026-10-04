#!/usr/bin/env python3
"""Lists the localization keys used in Sources/ (German source strings) in .strings format notation.

Covers SwiftUI literal initialisers (Text, Button, Label, …) and the L("…") helper. Interpolations become
%lld for integer expressions listed in INT_EXPRS and %@ otherwise. Used by scripts/l10n_check.py."""
import pathlib, re, sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CALLS = r'(?<![\w.])(?:Text|Button|Label|LabeledContent|TextField|SecureField|Picker|Link|GroupBox|WindowGroup|' \
        r'LocalizedStringKey|ContentUnavailableView|L|modelField)\(\s*' \
        r'|(?<![\w.])(?:step\(\d+,|hint\("[^"]*",|node\("[^"]*",)\s*' \
        r'|\.(?:help|alert|confirmationDialog|navigationTitle)\(\s*'
INT_EXPRS = {"backup.profiles.count", "backup.bindings.count", "bindings.count", "restored", "skipped",
             "EncryptedBackup.minimumPasswordLength", "profileCount", "keyCount", "projectCount", "skippedCount",
             "gatewayModels.count"}

def literal(src, i):
    """Parses a Swift string literal starting at src[i] == '"'. Returns (key, end index)."""
    assert src[i] == '"'
    i += 1; out = []
    while src[i] != '"':
        if src.startswith('\\(', i):
            depth, j = 1, i + 2
            while depth:
                if src[j] == '"': j = literal(src, j)[1]; continue
                depth += {'(': 1, ')': -1}.get(src[j], 0); j += 1
            out.append('%lld' if src[i + 2:j - 1].strip() in INT_EXPRS else '%@'); i = j
        elif src[i] == '\\': out.append(src[i:i + 2]); i += 2
        else: out.append(src[i]); i += 1
    return ''.join(out), i + 1

def keys():
    found = {}
    for path in sorted((ROOT / 'Sources').rglob('*.swift')):
        src = path.read_text()
        for m in re.finditer(CALLS, src):
            i = m.end()
            if src.startswith('verbatim:', i) or i >= len(src) or src[i] != '"': continue
            key, end = literal(src, i)
            found.setdefault(key, f"{path.relative_to(ROOT)}:{src.count(chr(10), 0, i) + 1}")
            # second literal argument of step/node (title, text)
            rest = src[end:end + 3]
            if m.group(0).startswith(('step', 'node')) and rest.lstrip(', ').startswith('"'):
                j = src.index('"', end)
                found.setdefault(literal(src, j)[0], f"{path.relative_to(ROOT)}")
    return found

if __name__ == '__main__':
    for key, where in keys().items(): print(f"{where}\t{key}")
