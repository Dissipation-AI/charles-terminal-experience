python3 -c "
import pipeline
s = pipeline.load(); t = {}
for sh in s.shards.values():
    rows = [r for r in sh if s.status_codes[r[1]] == 'refunded']
    t[sh.key] = (sum(r[2] for r in rows), len(rows))
k = max(t, key=lambda k: t[k][0]); open('answer.txt', 'w').write(f'{k} {t[k][1]}\n')"
