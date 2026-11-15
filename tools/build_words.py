#!/usr/bin/env python3
"""
Gera Keyboard/palavras.txt: palavras do português com frequência de uso.
- frequência: lista de legendas (FrequencyWords, pt_br_full)
- filtro: só palavras que existem no dicionário ortográfico pt-BR (VERO/LibreOffice, Hunspell),
  expandido com as regras de prefixo/sufixo; palavras muito usadas fora do dicionário (pra, tá, né) ficam.
Uso: build_words.py pt_br_full.txt index.aff index.dic saida.txt [max_palavras]
"""
import re, sys

freq_path, aff_path, dic_path, out_path = sys.argv[1:5]
max_words = int(sys.argv[5]) if len(sys.argv) > 5 else 90000

freq = {}
with open(freq_path, encoding='utf-8') as f:
    for line in f:
        p = line.split()
        if len(p) != 2: continue
        w, c = p[0].lower(), int(p[1])
        if c < 3: break
        if not re.fullmatch(r"[a-záàâãéêíóôõúüç]+(?:-[a-záàâãéêíóôõúüç]+)*", w): continue
        freq[w] = max(freq.get(w, 0), c)
print('palavras na lista de frequência:', len(freq))

# --- regras do Hunspell
rules = {}   # flag -> (tipo, cross, [(strip, add, contflags, regex)])
with open(aff_path, encoding='utf-8') as f:
    lines = f.read().split('\n')
i = 0
while i < len(lines):
    p = lines[i].split()
    if len(p) >= 4 and p[0] in ('SFX', 'PFX') and p[3].isdigit():
        kind, flag, cross, n = p[0], p[1], p[2] == 'Y', int(p[3])
        lst = []
        for j in range(1, n + 1):
            q = lines[i + j].split()
            if len(q) < 4: continue
            strip = '' if q[2] == '0' else q[2]
            add = q[3]
            cont = ''
            if '/' in add:
                add, cont = add.split('/', 1)
            if add == '0': add = ''
            cond = q[4] if len(q) > 4 else '.'
            rx = re.compile((cond + '$') if kind == 'SFX' else ('^' + cond))
            lst.append((strip, add, cont, rx))
        rules[flag] = (kind, cross, lst)
        i += n + 1
        continue
    i += 1

def apply(word, flag):
    r = rules.get(flag)
    if not r: return []
    kind, cross, lst = r
    out = []
    for strip, add, cont, rx in lst:
        if not rx.search(word): continue
        if kind == 'SFX':
            if strip and not word.endswith(strip): continue
            base = word[:len(word) - len(strip)] if strip else word
            out.append((base + add, cont, kind, cross))
        else:
            if strip and not word.startswith(strip): continue
            base = word[len(strip):] if strip else word
            out.append((add + base, cont, kind, cross))
    return out

valid = set()
names = {}   # nomes próprios do dicionário (Pedro, Brasil...) com a grafia original
def keep(w):
    lw = w.lower()
    if lw in freq: valid.add(lw)

with open(dic_path, encoding='utf-8') as f:
    next(f)
    for line in f:
        line = line.rstrip('\n')
        if not line: continue
        word, _, flags = line.partition('/')
        word = word.split('\t')[0].split(' ')[0]
        flags = flags.split('\t')[0].split(' ')[0]
        if 'ý' in flags: continue          # palavra proibida
        if word[:1].isupper() and not word.isupper():
            lw = word.lower()              # nome próprio: só se for bem usado
            if lw in freq and freq[lw] >= 300 and '.' not in word:
                names[lw] = word
            continue
        keep(word)
        sfx_forms = []
        for fl in flags:
            for form, cont, kind, cross in apply(word, fl):
                keep(form)
                if kind == 'SFX':
                    sfx_forms.append((form, cross))
                    for fl2 in cont:      # segundo nível de sufixo
                        for form2, _, _, _ in apply(form, fl2):
                            keep(form2)
        # prefixo combinado com sufixo
        for fl in flags:
            r = rules.get(fl)
            if r and r[0] == 'PFX' and r[1]:
                for form, cross in sfx_forms:
                    if cross:
                        for f2, _, _, _ in apply(form, fl):
                            keep(f2)
print('palavras confirmadas pelo dicionário:', len(valid))

# palavras informais muito usadas que não estão no dicionário ortográfico
informal = {w for w in ['pra', 'pro', 'pros', 'pras', 'tá', 'tô', 'tava', 'tavam', 'tamo', 'né', 'vc', 'vcs',
            'pq', 'tb', 'tbm', 'blz', 'vlw', 'valeu', 'hein', 'aí', 'cadê', 'ok', 'okay', 'oi', 'olá', 'tchau',
            'uau', 'putz', 'poxa', 'opa', 'eita', 'pô', 'beleza', 'kkk', 'kkkk', 'haha', 'rs', 'msg', 'whats',
            'zap', 'ia', 'app', 'apps', 'online', 'offline', 'email', 'e-mail', 'site', 'link', 'ok'] if w in freq}
extras = {}
import os
extra_path = os.path.join(os.path.dirname(__file__), 'extras.txt')
if os.path.exists(extra_path):
    for line in open(extra_path, encoding='utf-8'):
        w = line.strip()
        if w and not w.startswith('#'):
            extras[w.lower()] = w
            freq[w.lower()] = max(freq.get(w.lower(), 0), 400)
final = valid | informal | set(names) | set(extras)
ranked = sorted(final, key=lambda w: -freq[w])[:max_words]
with open(out_path, 'w', encoding='utf-8') as out:
    for w in ranked:
        shown = extras.get(w) or names.get(w) or w
        out.write(f'{shown} {freq[w]}\n')
print('palavras no arquivo final:', len(ranked))
