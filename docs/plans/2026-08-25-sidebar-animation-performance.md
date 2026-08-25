# Why opening the sidebar was heavy, and what it actually was

**Status:** done 2026-08-25.

## What was reported

"桌面版的左右sidebar的打开和关闭的动效不够丝滑" — profile it and fix it.

## What it was

`sample` on the main thread while toggling the inspector, release build, with a
**198KB note** open (`_人工选题库.md`). The answer was not where anyone would
look for it:

| | share of main thread |
| --- | --- |
| **`InkstoneTextView.resetCursorRects`** | **54.0%** |
| `_NSFastFillAllLayoutHolesForGlyphRange` (called from it) | 31.5% |
| `EditorRenderer.draw` | 0.2% |

`resetCursorRects` enumerated `.inkstoneBlockFill` and `.inkstoneWikiLink` across
the **entire document** and asked the layout manager for a rect for each hit.
Every one of those makes TextKit fill its layout holes, so the method laid out
the whole note — and **AppKit calls it on every tracking-area update**, which a
split-view animation issues continuously.

A cursor rect outside the visible area can never be hovered, so all of that work
was for nothing. Scoped to the visible rect plus 200pt of slack:

| | before | after |
| --- | --- | --- |
| `resetCursorRects` | 54.0% | **1.6%** |

Second, smaller: `updateInsets` re-highlights whenever the text measure moves
32pt, which is the bucket the inline-image cache uses. Opening the sidebar moves
the measure about 260pt in a quarter of a second — **eight full highlight passes
over the document, seven of them for a width that was obsolete before the pass
finished.** The re-highlight now waits 120ms for the width to stop moving.

## One thing that was tried and reverted

The obvious-looking fix — narrow `EditorRenderer`'s thirteen whole-document
attribute enumerations to the visible character range — **made it worse**, and
the measurement is the only reason that is known:

| | `EditorRenderer.draw` |
| --- | --- |
| whole-document enumeration | 0.2% |
| scoped to the visible range | **38.5%**, all of it inside the scoping call itself |

The two questions are not symmetrical:

- `boundingRect(forGlyphRange:)` — what the draw passes ask — lays out the range
  it is given and nothing else.
- `glyphRange(forBoundingRect:)` — what "what is visible?" has to ask — must know
  where every line above the rect sits, so it lays out sequentially from the top
  of the document.

Thirteen cheap questions beat one expensive one. Attribute enumeration over the
whole storage is O(runs) and costs nothing; the layout is the expensive part, and
asking about it *by rect* is the expensive direction. Reverted, with the reason
written into the surviving helper so it is not tried again.

The one place the visible range is still used is `drawSelection`, and only when
the selection is over 20,000 characters — select-all on a long note otherwise
walks every line fragment in the document on every draw. Below that the scoping
costs more than it saves.

## What is left

TextKit re-typesets on every width change; that is inherent, and it is why every
TextKit app slows down resizing a huge document. What has been removed is the
work that was *not* inherent.

## HUMAN QUEUE

- Open and close the sidebar on a large note and say whether it is smooth enough
  now. A before/after comparison of total main-thread busy time was attempted and
  is not trustworthy — the two runs were not doing equivalent amounts of
  animating, and the numbers came out contradicting the per-symbol readings. The
  per-symbol figures above are the ones to believe; the overall "is it smooth"
  question needs eyes.
