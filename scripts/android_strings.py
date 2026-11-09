#!/usr/bin/env python3
"""Copies translations from Shared/Localizable.xcstrings into the Android app as one JSON table per language.
Keys stay the English source strings, as on iOS. Run: python3 scripts/android_strings.py"""
import json, os, re

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = json.load(open(f'{root}/Shared/Localizable.xcstrings', encoding='utf-8'))['strings']
out = f'{root}/Android/app/src/main/assets/strings'
os.makedirs(out, exist_ok=True)
fmt = lambda s: re.sub(r'%(\d+\$)?lld', r'%\1d', re.sub(r'%(\d+\$)?@', r'%\1s', s))
tables = {}
for key, v in src.items():
    for lang, loc in v.get('localizations', {}).items():
        unit = loc.get('stringUnit') or loc.get('variations', {}).get('plural', {}).get('other', {}).get('stringUnit')
        if unit and unit.get('value'):
            tables.setdefault(lang, {})[fmt(key)] = fmt(unit['value'])
for lang, t in tables.items():
    if lang != 'en':
        json.dump(t, open(f'{out}/{lang}.json', 'w', encoding='utf-8'), ensure_ascii=False, indent=0, sort_keys=True)
print(sorted(tables))
