import json, sys, collections
d = sys.argv[1]
ink = {r['path']: r['c'] for r in map(json.loads, open(d + '/inkstone.jsonl', encoding='utf-8'))}
# Same rules on both sides: a task is also a list item (Inkstone emits only
# the task token); links of every kind incl. embeds/images are one bucket.
for c in ink.values():
    c['li'] = c.get('li', 0) + c.get('task', 0)
def links(c): return c.get('ilink', 0) + c.get('xlink', 0) + c.get('embed', 0)
obs = {}
for line in open(d + '/obsidian.jsonl', encoding='utf-8'):
    r = json.loads(line)
    if 'c' in r: obs[r['path']] = r['c']
for c in list(ink.values()) + list(obs.values()): c['links'] = links(c)
keys = ['h','li','task','links','code','table','tag','callout','hr','math','mark','del','fn']
both = [p for p in obs if p in ink]
print(f"notes compared: {len(both)}")
print(f"{'cat':8}{'match':>7}{'ink>obs':>9}{'ink<obs':>9}{'ink total':>11}{'obs total':>11}")
examples = collections.defaultdict(list)
for k in keys:
    m = gt = lt = ti = to = 0
    for p in both:
        a, b = ink[p].get(k, 0), obs[p].get(k, 0)
        ti += a; to += b
        if a == b: m += 1
        elif a > b: gt += 1; examples[k].append((a - b, p, a, b))
        else: lt += 1; examples[k].append((a - b, p, a, b))
    print(f"{k:8}{m:7}{gt:9}{lt:9}{ti:11}{to:11}")
if len(sys.argv) > 2:
    k = sys.argv[2]
    for diff, p, a, b in sorted(examples[k], key=lambda x: -abs(x[0]))[:int(sys.argv[3]) if len(sys.argv) > 3 else 8]:
        print(f"  {k} ink={a} obs={b}  {p}")
