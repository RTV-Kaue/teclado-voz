#!/usr/bin/env python3
"""
Gera Keyboard/bigramas.txt: para cada palavra, as próximas palavras mais comuns (com contagem).
Uso: build_bigrams.py palavras.txt saida.txt arquivo1 [arquivo2 ...]
Arquivos aceitos: Tatoeba (*.tsv.bz2, frase na 3ª coluna) ou Leipzig (*-sentences.txt, frase na 2ª coluna).
"""
import bz2, collections, re, sys

vocab_path, out_path, sources = sys.argv[1], sys.argv[2], sys.argv[3:]
vocab = set()
for line in open(vocab_path, encoding='utf-8'):
    p = line.split()
    if p: vocab.add(p[0].lower())
# o Tatoeba usa "Tom" e "Mary" em milhares de frases de exemplo; não queremos prever esses nomes
vocab -= {'tom', 'mary', 'john', 'ken'}

word = re.compile(r"[a-záàâãéêíóôõúüç]+(?:-[a-záàâãéêíóôõúüç]+)*")
pairs = collections.defaultdict(collections.Counter)
n_sent = 0

def feed(text):
    global n_sent
    for sent in re.split(r'[.!?;:()"“”\n]+', text.lower()):
        toks = word.findall(sent)
        if not toks: continue
        n_sent += 1
        prev = '^'
        for t in toks:
            if t in vocab:
                pairs[prev][t] += 1
                prev = t
            else:
                prev = '#'          # palavra desconhecida quebra a sequência

for src in sources:
    try:
        opener = bz2.open if src.endswith('.bz2') else open
        col = 2 if src.endswith('.bz2') else 1
        with opener(src, 'rt', encoding='utf-8', errors='ignore') as f:
            for line in f:
                parts = line.rstrip('\n').split('\t')
                if len(parts) > col:
                    feed(parts[col])
        print('lido:', src, 'frases até agora:', n_sent)
    except Exception as e:
        print('falhou:', src, e)

pairs.pop('#', None)
totals = {w: sum(c.values()) for w, c in pairs.items()}
keep = sorted(totals, key=lambda w: -totals[w])[:30000]
with open(out_path, 'w', encoding='utf-8') as out:
    n = 0
    for w in keep:
        top = [(x, k) for x, k in pairs[w].most_common(12) if k >= 2 and x != '#']
        if top and totals[w] >= 5:
            out.write(w + '\t' + ' '.join(f'{x}:{k}' for x, k in top) + '\n')
            n += 1
print('frases:', n_sent, 'palavras com previsão:', n)
