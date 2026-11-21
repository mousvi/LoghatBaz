"""Build words.json (400 stages x 15 unique words) from the Openjam API.

Run once, then ship words.json inside the app:
    python tools/fetch_words.py
Writes words.json and review.tsv (stage, English, Persian) to the current
directory. The API allows 60 requests/min and fails with limit=500, so words
are fetched in pages of 50 with a short pause between calls.
"""
import json, re, time, sys, urllib.request, urllib.parse, urllib.error

API = 'https://openjam.amirj4m.com/v1'
EMOJI = {'food':'🍎','drink':'🥤','body':'🫀','clothing':'👕','home':'🏠','animal':'🐾','plant':'🌿','nature':'🌦️','vehicle':'🚗','tool':'🛠️','family':'👨‍👩‍👧‍👦','person':'🧑','profession':'💼','relationship':'🤝','emotion':'😊','society':'🏙️','place':'📍','country':'🌍','city':'🌆','travel':'🧳','work':'💼','school':'🎓','sport':'⚽','arts':'🎨','religion':'🕌','media':'📺','health':'🩺','science':'🔬','technology':'💻','time':'⏰','money':'💰','quality':'✨','action':'🏃','abstract':'💡','event':'🎉'}


def get(path):
    for _ in range(6):
        try:
            req = urllib.request.Request(API + path, headers={'Accept': 'application/json', 'User-Agent': 'loghatbaz-build'})
            with urllib.request.urlopen(req, timeout=30) as r:
                d = json.load(r)
            time.sleep(1.2)
            return d
        except urllib.error.HTTPError as e:
            if e.code == 429:
                print('rate limit, 60s...')
                time.sleep(60)
            else:
                sys.exit('HTTP %s: %s' % (e.code, path))
        except Exception as e:
            print('retry:', e)
            time.sleep(5)
    sys.exit('failed: ' + path)


def page(slug, off):
    out = []
    for o in range(off, off + 500, 50):
        d = get('/categories/%s/words?lang=fa&limit=50&offset=%d' % (urllib.parse.quote(slug), o)).get('data', [])
        out += d
        if len(d) < 50:
            break
    return out


cats = [c for g in get('/categories/groups').get('groups', []) for c in g.get('children', [])]
raw = {}
off = {}
for c in cats:
    raw[c['slug']] = page(c['slug'], 0)
    off[c['slug']] = 500
    print(c['slug'], len(raw[c['slug']]))


def pools():
    seen = set()
    out = []
    for c in cats:
        pool = []
        for it in raw.get(c['slug'], []):
            en = str(it.get('english') or '').strip().lower()
            if not re.fullmatch(r"[a-z]+(?:[-'][a-z]+)*", en) or len(en) > 28 or en in seen:
                continue
            tr = next((x for x in (it.get('translations') or []) if isinstance(x, dict) and isinstance(x.get('meaning'), str) and x['meaning'].strip()), None)
            if not tr:
                continue
            m = re.sub(r'\s+', ' ', tr['meaning'].strip()).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            if len(m) > 90:
                continue
            seen.add(en)
            pool.append([en, m, '', EMOJI.get(c['slug'], '📘')])
        out.append((c, pool))
    return out


def build(ps):
    lv = []
    ws = []
    cur = [0] * len(ps)
    part = [0] * len(ps)
    while len(lv) < 400:
        adv = False
        for i, (c, pool) in enumerate(ps):
            if len(lv) >= 400:
                break
            if len(pool) - cur[i] < 15:
                continue
            ids = []
            for j in range(15):
                ids.append(len(ws))
                ws.append(pool[cur[i] + j])
            cur[i] += 15
            part[i] += 1
            adv = True
            lv.append({'title': (c.get('name_fa') or c.get('name_en') or c['slug']) + ' · بخش ' + str(part[i]), 'emoji': EMOJI.get(c['slug'], '📘'), 'category': c['slug'], 'ids': ids})
        if not adv:
            break
    return ws, lv


ws, lv = build(pools())
for c in sorted([c for c in cats if (c.get('word_count') or 0) > 500], key=lambda c: -(c.get('word_count') or 0)):
    if len(lv) >= 400:
        break
    while len(lv) < 400 and off[c['slug']] < (c.get('word_count') or 0):
        raw[c['slug']] += page(c['slug'], off[c['slug']])
        off[c['slug']] += 500
        ws, lv = build(pools())
        break
if len(ws) != 6000 or len(lv) != 400 or len({w[0] for w in ws}) != 6000:
    sys.exit('FAILED: words=%d stages=%d' % (len(ws), len(lv)))
json.dump({'version': 'loghatbaz-6000-v1', 'words': ws, 'levels': lv}, open('words.json', 'w'), ensure_ascii=False, separators=(',', ':'))
with open('review.tsv', 'w') as f:
    for n, l in enumerate(lv, 1):
        for i in l['ids']:
            f.write('%d\t%s\t%s\n' % (n, ws[i][0], ws[i][1]))
print('OK: 6000 words, 400 stages -> words.json, review.tsv')
