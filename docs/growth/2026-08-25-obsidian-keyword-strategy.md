# Where Obsidian's search traffic actually is, and which slice Inkstone can take

**Measured 2026-08-25** via Ahrefs (waimaoxia shared account, US database).
Every number below is a reading, not an estimate. Credits used: 11 of the 30/day
budget.

## 1 — Obsidian's organic traffic is almost entirely its own name

`obsidian.md` (subdomains, US):

| | |
| --- | --- |
| Organic traffic | **96.7K/mo** (−15.2K) |
| Traffic value | $43.9K |
| Organic keywords | 6.3K, of which 2.4K in positions 1–3 |
| Referring domains | 24.5K |

Its top keywords, by traffic:

| keyword | pos | volume | KD | traffic |
| --- | --- | --- | --- | --- |
| obsidian | 5 | 267K | 59 | 26,352 |
| obsidian notes | 3 | 46K | 27 | 15,973 |
| obsidian app | 6 | 6.8K | 50 | 1,688 |
| obsidian plugins | 4 | 2.8K | 28 | 1,624 |
| obsidian note taking | 6 | 5.6K | 27 | 1,577 |
| **obsidian sync** | 3 | 2.3K | **5** | 1,155 |
| obsidian themes | 4 | 1.1K | 2 | 597 |
| obsidian vault | 3 | 1.5K | 4 | 560 |

Nearly every row carries Ahrefs' **Branded** tag. Read that plainly: **you cannot
take Obsidian's traffic, because Obsidian's traffic is people typing its name.**
Chasing "obsidian" (KD 59, and half the volume is the mineral, the Minecraft
block and the Pokémon set) is a waste of a small site's time.

What is takeable is the **modifier layer** — the queries where someone already
knows Obsidian and is looking for something it does not give them.

## 2 — The two clusters worth having

### obsidian alternative — KD 0

| | |
| --- | --- |
| Volume | 500 US / 2.6K global |
| Difficulty | **0** — "very few ref. domains to rank in top 10" |
| CPC | $1.30 |
| Growth | +18%, forecast +10% |
| Who ranks #1 today | **a Reddit thread** |

A KD of 0 with a Reddit thread at the top means no one has built a page that
deserves the position. Terms in the cluster:

| keyword | volume |
| --- | --- |
| obsidian alternatives | 600 |
| **is obsidian open source** | 500 |
| obsidian alternative | 500 |
| joplin vs obsidian | 350 |
| alternative to obsidian | 150 |
| obsidian open source alternative | 150 |
| open source obsidian alternative | 150 |
| obsidian canvas alternative | 70 |

146 terms-match keywords in total.

### obsidian sync — KD 5

| | |
| --- | --- |
| Volume | 2.1K US / 10K global |
| Difficulty | **5** — "~6 ref. domains to rank in top 10" |
| CPC | $0.70 |
| Growth | **+22%**, forecast +14% |

And the cluster under it is *commercial-intent*, which is the interesting part:

| keyword | volume |
| --- | --- |
| obsidian github | 900 |
| obsidian pricing | 700 |
| is obsidian free | 600 |
| obsidian sync pricing 2026 | 500 |
| obsidian git | 450 |
| obsidian sync pricing | 300 |
| obsidian sync price / pricing official | 250 each |
| how much is obsidian sync | 150 |
| is obsidian sync free | 100 |
| is obsidian sync worth it | 100 |
| how to sync obsidian for free | 80 |
| how to sync obsidian with google drive | 70 |

1,758 terms-match keywords, 105 of them questions.

**Every one of those is someone deciding whether to pay for Obsidian Sync.**
Obsidian's own price, read off its pricing page on 2026-08-25: Sync is **$4 per
user per month billed annually, $5 billed monthly**. The app itself is free —
that matters, and any page that implies otherwise is both wrong and less
persuasive than the truth.

Inkstone syncs through a GitHub repository, at no charge. That is not a
positioning exercise; it is the literal difference, and it lands on a 3K-volume
cluster at KD ≤ 5.

## 3 — What was published

Two pages, in `site/static/`, outside the eight-language system on purpose:
these target English queries and a forced translation into seven other languages
would be seven pages of thin content.

| page | primary | secondary |
| --- | --- | --- |
| `/obsidian-alternative.html` | obsidian alternative, obsidian alternatives | is obsidian open source, obsidian open source alternative, alternative to obsidian |
| `/obsidian-sync-free.html` | how to sync obsidian for free, is obsidian sync free | obsidian sync pricing/price, how much is obsidian sync, obsidian git, obsidian github |

Both carry `FAQPage` structured data built from the question keywords above,
because those questions are literally what people typed.

## 4 — One thing that constrains the copy

**Inkstone has no LICENSE file**, so it is source-available, not open source. The
`obsidian open source alternative` keyword is in the cluster, and the page ranks
for it by *answering* the question honestly — plain files, no lock-in, source you
can read — and saying outright that the source is public but not yet under an
OSI licence. It does not claim to be open source.

If a licence is ever added, that page gets materially stronger and the
`is obsidian open source` (500/mo) traffic becomes properly winnable. That is a
business decision, not one to make from here.

## HUMAN QUEUE

- Decide whether to put an OSI licence on the repository. It is worth about 650
  searches a month of exactly-qualified traffic, and it is the one claim these
  pages currently have to talk around.
- The Semrush session inside waimaoxia had expired (`登录已过期，请从【个人中心】重新打开当前工具`).
  Re-open it from 个人中心 if you want the Semrush-side expansion as well; the
  Ahrefs numbers above stand on their own.
- Ahrefs credits after this run: **241/300**, 11 used today of the 30/day cap.
