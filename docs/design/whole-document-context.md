# The whole document as context in memoQ

Design note, 23 October 2026. Approved by Michael the same day, long-document
box included, and implemented as described: `Core/DocumentContext.cs`,
`EngineContext.DocumentContextBlock`, checked by `tools/document-context-test.ps1`.

## The gap

Supervertaler for Trados puts the document's source text into every Batch
Translate request: up to 500 segments, under a `# DOCUMENT CONTENT` heading, in
the system prompt. Supervertaler for memoQ does not. A memoQ request carries the
prompt, the memory bank, the project's client/domain/subject, a few segments the
translator has already confirmed, the terms found in the rows, and the rows
themselves (memoQ hands over about 10 at a time). The model never sees the rest
of the document.

The plugin already holds the document text. It uses it only to choose which
memory-bank articles to send. This note proposes sending it as well, the way
Trados does.

## 1. Where the text comes from

There are two sources, and the plugin already reads both:

- **The live document link** (the preview tool). When it is connected, memoQ
  hands over the whole open document at once, in order. Its rows are
  *paragraphs*, not grid rows: a three-sentence paragraph is one row.
- **What memoQ has asked us to translate so far** (`CaptureStore`). It grows as
  memoQ sends rows. During the first Pre-translate of a document it starts with
  the first batch and reaches the end only when the run does. Its order is
  memoQ's order of asking, which is document order give or take a batch,
  because memoQ runs several batches at once.

**Proposal:** use the live link whenever it has rows for this document, and
the captured rows only when it has none. That happens when the preview tool is
not running, or when Pre-translate runs from Project home on documents that are
not open in the editor.

So with the live link, even the first batch sees the whole document. Without
it, the model sees **the start of the document, at least half of what memoQ has
sent so far**. During the first run that grows from the first few batches to most
of the document; after it, the model sees somewhere between half and all of it,
depending on where the last doubling fell (section 2). Closing that gap would mean
rebuilding more often, which costs cache writes. The live link has no such gap,
so the honest advice is: keep the preview tool running. It starts with memoQ.

Captured rows are used only for a document memoQ has named. When memoQ asks
without saying which document, the rows go into one bucket per language pair.
That bucket can mix documents, and a mixed bucket is not sent.

Source text only, never the target. The target changes with every edit, and
any change would cost a fresh cache write.

## 2. Where it goes: the cached part of the request

Every request has two halves. The **system** half is the same for every request
of a job: the prompt, then the memory bank, then the closing reply rules. The
**user** half changes with every request. The provider's prompt cache only
works on the system half, and only if it is **identical to the byte**: change
one character and the whole half is paid for again at the write rate (1.25×
the normal rate on Claude) rather than read from the cache (0.1×).

The document goes in the system half, after the memory bank and before the
reply rules. That is the same place as in Trados, and under the same
`# DOCUMENT CONTENT` heading with the same wording, so a library prompt that
refers to that block works in both products. Interactive lookups get the same
system half as Pre-translate, so the two share one cache entry.

How it stays identical:

| What could change it | What happens |
|---|---|
| Rows arriving during the first run without the live link | Rebuilt only when the captured text has **doubled**. This is the rule the memory bank already follows, and it uses the same doubling points, so the two change together. A 570-row run gets about five rebuilds rather than fifty-seven. |
| memoQ's parallel engines (it builds two per language pair) and parallel requests | The block is cut at a fixed point for each doubling (at the row that reaches 4,000, 8,000, 16,000… characters), never "whatever has arrived by now". The captured rows only ever grow at the end, so every engine and every request builds the same text. This cut is also why the block can lag (section 1). |
| The live link connecting halfway through a job | One rebuild, after which the block is fixed. |
| The translator editing a source paragraph | Not picked up until the next rebuild. A stale sentence costs less than a cache write on every edit. |
| A memoQ view of several files, or moving to another document | Each document has its own block, written to the cache once. |
| Editing the prompt or the memory bank | Rebuilt, as today. |

The plugin already lets the first request of a run go out alone, so the others
read the cache it writes rather than racing it (#5). That stays as it is, once
per run. A rebuild halfway through a run therefore costs up to four writes
instead of one, but at most a few cents on a run's worth of rebuilds. Re-arming
the gate on every rebuild would save those cents and make every rebuild wait for
one request. Not worth the extra locking.

The rows are numbered 1, 2, 3… as in Trados. One sentence is added: these are
positions in this list, not memoQ's row numbers. The live link's rows are
paragraphs, so its numbers never match the grid, and a `[[TC: see segment 31]]`
comment must not send you to the wrong row.

## 3. How much

**Proposal: up to 25,000 tokens of document text (about 100,000 characters,
roughly 15,000 to 18,000 words).** That is about what Trados's 500 segments come
to on a patent. The limit is in text, not rows, because a live-link row is a
paragraph and can be three grid rows.

A longer document is cut the way Trados cuts it: the first 80% of the allowance
from the start, the last 20% from the end, and a line saying how much was left
out in between. On a patent the end is the claims and the abstract, so they
stay in.

### A second box for long documents

For a translator who wants the model to see all of a much bigger job, a second
box under the document box, **off by default**:

> **Send long documents whole (up to about 130,000 words; costs more)**

Ticked, the limit rises from 25,000 tokens to **200,000 tokens** (about 800,000
characters, the length of a book). Past that, the same 80/20 cut. The model's
capacity is not the constraint: every recommended cloud model the plugin lists
(Claude Sonnet 5.5 and Opus 5.5, OpenAI's two GPT-6 models, Gemini 3.8 Flash)
holds 1 million tokens, and Claude charges no extra for long prompts. The
200,000 is there so that a document of 50,000 paragraphs cannot quietly cost
several dollars a request. An older model with a smaller window would refuse the
request, and memoQ shows that refusal under the grid. Untick the box and it
works again.

Everything in section 2 applies unchanged: the same cached position, the same
doubling, the same identical bytes for every engine. Two limits remain:

- Without the live link, the plugin keeps at most the first **5,000 rows** memoQ
  sends for a document. So "whole" means whole only with the live link, or for a
  document of up to 5,000 rows.
- It does nothing for local models (section 4). The box is greyed out when a
  local provider is selected, and when the document box above it is unticked.

Each request's line in the log says how many tokens of document it carried, so a
cost surprise can be traced to it.

## 4. Local models (Ollama, OpenAI-compatible): off

Not sent to either, and the log says so once. On your computer, without a
graphics card, Ollama reads about 17 tokens a second. 25,000 more tokens would
add about 25 minutes to the first segment of every job, and to every document
switch. Many local models have 8,000 or 32,000-token windows that cannot hold it
at all. The plugin would then refuse the request as "context too small". Ollama
also keeps only one prompt in its cache, which is why the memory bank is
already sent whole and fixed to local models.

Ollama's cloud models go through the same local Ollama, so they are off too.
This can be revisited if a translator with a graphics card asks.

## 5. The setting: the existing box, relabelled

Whether the document is sent at all needs no new option. (The only new box is
the long-document one in section 3, which changes how much.) The box **"Send
surrounding segments and project metadata to the model"** (on by default) already governs exactly this kind of thing: memoQ's
surrounding segments (which never arrive), the client/domain/subject, and the
confirmed segments. The document is the surrounding text. Relabelled in both
dialogs as:

> **Send the document, confirmed segments and project metadata to the model**

Two consequences:

- Because the box is on by default, **everyone using a cloud provider starts
  sending the document after the update.** That goes in the changelog. The
  data leaving the computer is no different in kind: Pre-translate already sends
  every row. It now leaves earlier, all at once, with the first request.
- Unticking it also stops the confirmed segments, which are cheap and useful. If
  you ever want the document off but those on, that is when a second box earns
  its place.

## 6. What it costs

Claude Sonnet 5.5, your memoQ model: $2.00 per million input tokens, a cache
read $0.20, a cache write $2.50. The example is a patent of about 570 rows, so
about 20,000 tokens of source text. These are the **extra** costs, on top of
what a job costs today.

| | With caching | Without caching |
|---|---|---|
| Pre-translate, 57 batches, live link connected | one write and 56 reads: **about $0.27** | 57 full reads: **about $2.30** |
| Pre-translate, no live link (growing document) | about five writes of a growing block, plus reads: **about $0.15 to $0.40** | **about $0.80** (the block is smaller for most of the run) |
| Working through it row by row, about 800 lookups | **about $3.20**, plus about $0.05 each time you pause for more than 5 minutes (the cache expires) | **about $32** |

Caching works for Claude (marker already sent), for OpenAI (automatic, half
price or less) and for Gemini (automatic, a quarter of the price). On Opus 5.5
the reads cost the same as on Sonnet ($0.20); the writes cost twice as much.

For interactive work, that roughly doubles what a lookup costs: from about half
a cent to about one cent, depending on the size of the memory bank. Unticking
the box brings it back down.

**A big job, with and without the long-document box.** A 3,000-row manual, about
100,000 tokens of source text, again on Sonnet 5.5, all with caching:

| | Normal limit (25,000 tokens sent) | Long-document box ticked (all 100,000 sent) |
|---|---|---|
| Pre-translate, 300 batches | **about $1.55** | **about $6.25** |
| Working through it row by row, about 4,000 lookups | **about $20** | **about $80** |
| Each pause of more than 5 minutes | $0.06 | $0.25 |

Without caching, the long-document Pre-translate alone would cost about $60.
The row-by-row figure is the one to watch: every lookup carries the whole
document, so on a long job the box costs about 2 cents a lookup. That is why it
is off by default.

## What each request sends, before and after

| | Today | After |
|---|---|---|
| System half (cached) | structure rule, prompt, memory bank, reply rules | structure rule, prompt, memory bank, **the document's source text**, reply rules |
| User half | TM match, row state, client/domain/subject, confirmed segments, terms, forbidden terms, language reminder, the rows | unchanged |
| Ollama / OpenAI-compatible | as today | as today: no document |
| Box unticked | no metadata, no confirmed segments | the same, and no document |

## Not changed

No change to core: the block is built with core's existing `DocumentContent`
list writer, and the heading text is copied. Exposing that heading from core is
a small change to propose to the Trados session, which owns core, later. Bridge
mode, AutoPrompt and the MCP tools are untouched.

## To decide

1. The live link first, the captured rows as the fallback (section 1).
2. The 25,000-token limit, cut 80/20 (section 3).
3. Off for local models (section 4).
4. The existing box, relabelled, on by default (section 5).
5. A second box, "Send long documents whole", off by default, raising the limit
   to 200,000 tokens (section 3).
