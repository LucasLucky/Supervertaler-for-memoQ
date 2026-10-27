# Supervertaler for memoQ – Claude Context

## What this project is

A memoQ add-in that brings Supervertaler's AI translation into memoQ. It is **not**
a port of Supervertaler for Trados — memoQ's plugin model is far narrower, and the
feature set has to be re-shaped around it rather than carried across.

Status: **released**, first as v0.1.0 on 2026-09-28. For **memoQ 11 and 12** since
v0.1.3 (2026-09-29); memoQ 10 and older are untested, and the installer leaves them
alone. See "memoQ 11" under Tech stack. The current version is in CHANGELOG.md and on
GitHub's releases/latest. It is unsigned; signing with memoQ has not started. How a
release is cut is under "Releasing" in the Distribution section.

## The constraint that shapes everything

memoQ gives an add-in **no UI surface**. No view part, no dockable panel, no ribbon
button, no menu item, no keyboard shortcut. The only UI an add-in owns is the
options dialog reached from *Resources > Settings > MT*.

An add-in is also **only ever called** — it can never reach out. There is no project
object model, no segment grid access, no way to read or write the active segment.
Everything the plugin knows arrives as arguments to a translation request.

Consequence: anything in Supervertaler that *is* a panel (prompt library, AI
assistant, SuperSearch, terminology editor) cannot live inside memoQ. It goes in a
companion application. That is not a workaround; it is the architecture.

## The five memoQ SDKs

All ship as interface assemblies in the memoQ install directory. Only the first is
used so far.

| Assembly | Contract | Use |
|---|---|---|
| `MemoQ.MTInterfaces` | `IPluginDirector2` → `IEngine2` → `ISession` / `IRichSession2` | **in use** — translation |
| `MemoQ.TBInterfaces` | `IPluginDirector` → `IEngine` → `ISession.Lookup(Segment)` | TermLens lands here |
| `MemoQ.TMInterfaces` | `ISession.Lookup` + `Concordance` | Supervertaler TM provider |
| `MemoQ.QAInterfaces` | `IBatchQAChecker` / `ISegmentLevelQAChecker` | QA over mqxliff streams |
| `MemoQ.GCInterfaces` | `ISession.CheckGrammar` | inline LLM proofreading |

### Contract facts recovered from the SDK packages (2026-09-02)

All five packages were read in full: specification, assembly surface, sample
source. The full write-up is private, in `D:\SynologyDrive\Skills\memoQ SDK
findings 2026-09-02.md`. The facts below change how this plugin must be written.

**MT SDK**

- **The rich session path never runs.** memoQ creates a rich lookup session
  only for the plugin whose id is `MemoQAGT`. `SupervertalerRichSession` and
  everything behind `CreateRichLookupSession` is unreachable inside memoQ. This
  is why `ContextKinds.Terminology` never arrived. Claiming the `AGT`
  capability only removes the plugin from the pre-translate list.
- **memoQ will forward the best fuzzy TM match** if `SupportFuzzyForwarding`
  is true and the user routes it to us under *Send best fuzzy TM match to*. It
  arrives as the second and third arguments of `TranslateCorrectSegment`. We
  currently discard it.
- **`MaxDegreeOfParallelism` is read once, when the MT settings resource is
  created, and stored in the .mqres.** Changing it later does nothing until the
  resource is recreated. The "Parallel requests" setting is therefore inert for
  an existing resource.
- **Saving MT settings calls `CreateEngine("eng","ger")`.** The engine
  constructor must be side-effect free; ours starts and re-aims the bridge,
  which is the root cause of the earlier eng-ger staging bug. Start the bridge
  from the director's `Initialize`, aim it from real traffic.
- Exceptions must be `MTException`; memoQ shows the message under the grid.
  `StoreTranslation(TranslationUnit[])` must return the indices stored, not
  flags. `SetProperty` is never called by memoQ desktop.
- `MTRequestMetadata.SegmentLevelMetadata` carries each row's GUID, its
  translation state (`TranslationStates`: 0 NotStarted, 1000 PreTranslated,
  2000 PartiallyEdited, 3000 ManuallyConfirmed, 5000 Proofread, 6000
  MachineTranslated, 7000 Rejected) and its index in the batch. The batch is a
  contiguous slice of the document, so array neighbours are real neighbours.
- memoQ calls the synchronous session on `Parallel.ForEach` workers; our extra
  `Task.Run` per call doubles the thread count. There is no cancellation on that
  path, so the LLM client must have its own timeout.
- Setting `TranslationResult.Confidence` and `ConfidenceProviderName` makes
  memoQ show "AIQE: <name> (n%)" under the hit.

**TB SDK**

- `GetAddTermsUrl(externalId, sourceLang, sourceTerm, targetLang, targetTerm)`
  is called with the user's *selected* source and target text and memoQ opens
  the URL returned. A localhost page served by the bridge makes it a quick-add
  dialog. The existing plugin disables it on a mistaken belief.
- `IEnvironment.BuildWordsOfSegment` is memoQ's own tokeniser.
- `TerminologyResult` also carries `Confidence` (0–101, 101 = exact with
  context), `ExternalId` and four metadata lists memoQ renders itself.
- **`PluginConfigured` is asked once per language pair per session.** On the
  first term lookup for a pair, memoQ builds that pair's engine list from the
  plugins answering yes and keeps it until it closes; only
  `IEnvironment.PluginAvailabilityChanged()` or toggling Enable plugin clears it
  (`TBAddinManager.getEnginesForLanguages`, same in memoQ 11 and 12). So it must
  never depend on per-project state: answering "this project has no termbases"
  shut the plugin out until a restart (fixed 2026-10-10). Ours is always true.

**TM SDK**

- Read-only: `Lookup(segment, preceding, following, threshold)` and
  `Concordance`. memoQ never stores a confirmed segment into a plugin TM.
  Learning from confirmations stays in the MT plugin's
  `ISessionForStoringTranslations`.
- Every lookup carries the neighbouring segments. Hits carry match rate,
  fragment ranges, plugin name and full entry metadata; concordance answers
  Ctrl+K with highlight ranges.

**QA SDK**

- Batch checks run under a modal progress dialog on a worker: no UI freeze,
  but no cancel, progress or timeout. Findings are target-range only, no
  auto-fix, no info level; errors and non-ignorable warnings block export.
  Trans-units carry only hashes, languages, document guid and (V2) notes.
  `mq:originalhash` is the natural cache key for an LLM pass. Generator id
  10–99 must be assigned by memoQ. Request version V4 exists but is undocumented.

**Preview SDK**

- Several tools connect at once; `PreviewPartIdRegex` routes content and
  triggers `AutoStartupCommand`. Parts are segment parts, paragraphs only when
  there are no structural tags. Ids come from the source file (XML filter
  settings, SRT filter, or an mqxliff round trip writing `mq:previewidbylabel`);
  `mQ-default` is undocumented. Id refresh happens only on request; our poll is
  what makes it periodic. The pipe name carries the terminal-server session id.
  A highlight request with only `PreviewPartId` cannot be rejected as stale.

**Distribution (MT, TB, TM, QA alike)**

Unsigned plugins prompt at every start unless
`C:\ProgramData\MemoQ\ClientDevConfig.xml` sets `LoadUnsignedPlugins`. Public
distribution is either memoQ compiling and signing the source into their
installer, or the signed-private-plugin route: `MemoQ.AddinSigner.exe -g`,
send memoQ the public key, they compile it into a public build, then `-s` per
release with the `.kgsign` beside the DLL. The Preview tool has no such gate.

There is also a **Preview SDK**, distributed separately rather than as an assembly
in the install directory — and it is more interesting than the others.

Confirmed in the UI at **Options > External preview tools**:

- a checkbox, **"Allow external preview tools to connect to memoQ"** (on by default);
- a list of installed external preview tools;
- **Advanced options** exposing the connection endpoints:
  - REST API base: `http://localhost:8088/MQPreviewService`
  - REST API full: `http://localhost:8088/MQPreviewService/1`
  - Named pipe base: `MQ_PREVIEW_PIPE`
  - Named pipe full: `MQ_PREVIEW_PIPE_1`

So a running memoQ exposes a **local REST API and a named pipe** that an external
process may connect to, and memoQ pushes it live document-preview events. This is
the only known route by which something outside memoQ can learn where the
translator is. It is what makes a position-aware companion app plausible at all —
worth pursuing before assuming the companion has to be a detached side window.

Not yet verified: whether those events carry segment identity, and what the payload
looks like. Ask memoQ for the Preview SDK package.

## Preview SDK — the contract, recovered 2026-09-02

memoQ's separately distributed **memoQ PDF Preview** tool ships
`MemoQ.PreviewInterfaces.dll` (53 KB), which IS the Preview SDK contract.
Installed at `C:\Program Files\memoQ\memoQ PDF Preview\`; downloaded from
https://docs.memoq.com/current/en/memoQ-PDF-preview-tool/memoq-pdf-preview-tool.html
(a public download — the assembly is not under NDA, though redistribution
terms are still unstated). Reflected in full;
the shape is:

**Transport.** Two protocols, same messages: a named pipe (`MQ_PREVIEW_PIPE`)
or REST (`http://localhost:8088/MQPreviewService`, with the tool hosting a
callback controller via `System.Web.Http.SelfHost`). memoQ's side is
configured in `C:\ProgramData\MemoQ\{Rest,NamedPipe}ProtocolWrapperSettings.xml`.
`PreviewServiceProxy(IPreviewToolCallback, baseAddress, protocol)` wraps it.

**Registration.** `Register(RegistrationRequest)`: a tool GUID, name,
description, an `AutoStartupCommand` (memoQ launches the tool itself —
the PDF tool has "Auto-start with memoQ"), a `PreviewPartIdRegex`, a
`ContentComplexityLevel` (`Minimal` | `PlainWithInterpretedFormatting`), and
`RequiredProperties` from {WebPreviewBaseUrl, Wpm, Cps, LineLengthLimit,
WordCount, CharCount}. Then `Connect(guid)`. memoQ shows registered tools
under Options > External preview tools and asks the user once
("Preview tool connection request", with "Can change focus").

**What memoQ pushes** (`IPreviewToolCallback`):
- `HandleContentUpdateRequest(PreviewPart[])` — each part: `PreviewPartId`,
  `SourceDocument {DocumentGuid, DocumentName, ImportPath}`, source/target
  language codes, and **`SourceContent` AND `TargetContent`** as text. Fires on
  every edit: one real log shows ~4,900 of these over a few months.
- `HandleChangeHighlightRequest(ActivePreviewParts[] with source/target
  FocusedRange {StartIndex, Length})` — **where the cursor is**, on every
  move (~4,500 in the same log).
- `HandlePreviewPartIdUpdateRequest`, `HandleDisconnect`.

**What the tool may send:** `RequestContentUpdate(previewPartIds,
targetLangCodes)` — pull any parts, and `RequestHighlightChange(previewPartId,
langs, sourceContent, targetContent, focused ranges)` — which the PDF tool
uses to make a click in the PDF select the matching memoQ segment ("Select
only one segment in memoQ then click the Align mode button…"). That is, in
all likelihood, **`go_to_segment`**.

**Why this matters.** Every ✗ in the MCP tool table exists because the MT/TB
SDKs never show a plugin the target text, the active row, or the document
name. The Preview SDK shows all three, live. A Supervertaler preview tool
registration — in the plugin process or the editor exe — would give the
bridge `get_active_segment`, target text for QA (`check_numbers`,
`find_inconsistencies`…), real document names without the disk hack, and
probably cursor navigation. `stage_translations` + Pre-translate stays the
only write channel; the Preview SDK has no "set target text" call.

**Measured with the spike (`src/Supervertaler.MemoQ.Preview`), 2026-09-02:**
- Accepting the "Preview tool connection request" dialog in memoQ *is* the
  connection: `Register` returns accepted and a subsequent `Connect` throws
  `PreviewToolAlreadyConnectedException`. `Connect` is for a tool that is
  already registered and starts later (the auto-start path).
- Part ids look like `mQ-default-<view-guid>-<n>`. The view guid is constant
  for a document but is NOT the document guid (that arrives separately in
  `SourceDocument.DocumentGuid`, alongside `DocumentName` and `ImportPath`).
  `<n>` is a stable per-row integer whose order did not obviously match the
  grid's row numbers on first sight — treat it as an opaque key and sort
  numerically only as a guess until the full id list has been compared.
- A highlight change delivers the active part in full: source AND target
  content, language codes, `WordCount`/`CharCount`, and the focused ranges
  (0..length of each side when a whole row is selected).
- A content update fires for exactly the part that changed, after an edit or
  confirm, with the new target text.
- `PlainWithInterpretedFormatting` renders inline formatting as `<b>…</b>`;
  tags come through as HTML-ish markup, not memoQ tag objects.
- The tool's own process, not the plugin, must host this: memoQ launches it
  from `AutoStartupCommand` and shows it under Options > External preview
  tools with "Auto-start with memoQ".

**Resolved 2026-09-19 without waiting for an answer: we ship none of it.**
`MemoQ.PreviewInterfaces.dll` ships with memoQ's preview tools rather than with
memoQ, and its redistribution terms are still unanswered - so the PDF Preview
tool is now a **prerequisite** and `PreviewSdk.cs` loads the assembly, and the
four libraries that come with it, out of wherever that tool installed
(`C:\Program Files\memoQ\memoQ PDF Preview\`, found by search across both
Program Files roots). Every reference in the preview csproj is `Private=false`:
compiled against, never copied. The build output is our own exe and its config,
nothing else. This is the same arrangement the add-in lives under for memoQ's
own assemblies, it puts the download on memoQ's website where a memoQ component
belongs, and it needs nothing from memoQ at all.

Two consequences worth knowing. The resolver has to be installed before any SDK
type is mentioned, so `Main` does that and calls a `NoInlining` `Run` - the
runtime resolves the types a method names when it compiles that method, not when
the line is reached. And `build.sh` explicitly deletes the five DLLs an older
deploy left in the data folder, because a copy beside the exe is found first and
would hide a broken resolver.

Still worth asking memoQ for redistribution, since it spares the customer an
install they may have no other use for - but it is now an improvement, not a
dependency. See `D:\SynologyDrive\Skills\memoQ call brief 2026-09-19.md`.
**Status 2026-09-17:** Ádám Gaugecz forwarded the question to Gábor Nagy and is
arranging a call.

**Privacy note:** the PDF tool's `%APPDATA%\MemoQ.PDFPreview\logs.txt`
names every document it ever saw. Never paste from it.

## What memoQ hands us (and Trados does not)

`TranslationBundle` carries context the Trados plugin has to assemble itself:

- `PlainTextContext` — `List<PlainTextContextItem>` (`Kind`, `Text1`, `Text2`, `NumericValue`)
- `SegmentContext` — `List<SegmentContextItem>` (`Kind`, `SourceSegment`, `TargetSegment`, `NumericValue`)

`ContextKinds` values: `Terminology`, `ForbiddenTerm`, `MetaInfo`, `TextFlowContext`,
`TranslationPair`.

**Which list a given kind lands in is not documented.** `PromptBuilder` therefore
looks for every kind in *both* lists, and `SupervertalerRichSession.LogContextShape`
logs what actually arrived on the first bundle of each batch. Read the log before
assuming.

**`IRichSession2` is unreachable for a third-party MT plugin — design around it.**
Measured 2026-08-30: memoQ calls `CreateLookupSession` for everything, Pre-translate
included (it uses `ISession`'s array overload). `CreateRichLookupSession` has never
been called once. A term marked forbidden in the project term base came straight
back in the output, because the plugin was never told it existed.

This is not a mistake on our side. Reflecting the two shipped comparators settles it:

| Plugin | Session interfaces |
|---|---|
| `MemoQ.ModernMT.dll` (bundled, signed) | `ISessionWithMetadata`, `ISession`, `ISessionForStoringTranslations` |
| `MemoQ.IntentoMT.dll` (bundled, signed) | `ISession`, `ISessionForStoringTranslations` |
| `LaraPlugin.dll` (current ModernMT/Lara, signed) | `ISessionWithMetadata`, `ISession`, `ISessionForStoringTranslations` |

**None of them implements `IRichSession`.** The most context-hungry adaptive MT
engines on the market do not use it, which means `TranslationBundle` — and with it
`ContextKinds.Terminology` and `ForbiddenTerm` — is effectively AGT-only.

**Do not claim `Capabilities.AGT` to try to unlock it.** Tested and rejected:
returning true from `HasCapability("AGT")` removed Supervertaler from the
*Pre-translation* dropdown in *Edit machine translation settings > Settings* — it
read "No plugins selected" and the engine could not be chosen at all.

### What to use instead

The three interfaces the shipped plugins use, all of which we now implement:

- **`ISession`** — the actual translate path, single and array overloads.
- **`ISessionWithMetadata`** — same, plus `MTRequestMetadata`: `ProjectGuid`,
  `DocumentID`, `Client`, `Domain`, `Subject`, and per-segment `SegmentID` /
  `SegmentIndex` / `SegmentStatus`. The only channel by which an MT plugin learns
  where it is. `Client` / `Domain` / `Subject` go into the prompt; `DocumentID`
  keys `DocumentMemory`.
- **`ISessionForStoringTranslations`** — every segment the translator confirms, as
  they confirm it. Requires `StoringTranslationSupported => true` on the director,
  and is what puts an engine in the *Self-learning MT* dropdown.

`Core/DocumentMemory.cs` joins them: confirmed pairs are recorded per document and
the most lexically similar ones are fed back into later prompts. It is the
substitute for the neighbouring-segment context we cannot have — and arguably
better, since every example is human-approved rather than merely adjacent.

Terminology proper has no route through the MT SDK, and **memoQ confirmed it on
2026-09-17** (Ádám Gaugecz, in reply to the question below): today it "can only
be queried through the Resources API" - which is the memoQ *server* REST API, not
something a desktop plugin has - and memoQ is "about to start developing a new
integration endpoint for MT that will also provide terminology and all the TM
hits - probably by Q1 2027 it will be public." So: the TB-plugin route TermLens
already uses is the right one and stays; when that endpoint ships, it becomes an
additional source of the same terms, not a replacement for the termbase system.


## The document in every request (added 2026-10-23)

Trados's Batch Translate has always sent the document; memoQ now does too. The
design and its costs are in `docs/design/whole-document-context.md`.

- `Core/DocumentContext.cs` builds the block (pure functions);
  `EngineContext.DocumentContextBlock` decides whether to send it and keeps it
  between rebuilds. It goes in the **system** half, after the memory bank and
  before `OutputContract`, under core's `# DOCUMENT CONTENT` heading and wording
  (copied, since core does not expose it on its own).
- **Source:** the live link's paragraphs when it has the document (all of it,
  from the first request), else `CaptureStore`'s rows. Only for a document memoQ
  has named: the `nodoc_` bucket can mix documents.
- **Byte stability is the whole design.** The block is rebuilt only when the
  text crosses a doubling (`DocumentContext.Step`, measured as the bank measures
  it so the two move together). Captured rows are cut at the doubling point
  (`CapturedPrefix`) rather than "whatever has arrived", so memoQ's two engines
  per pair build the same bytes at any moment. The price: without the live link
  the block holds 50-100% of what was captured.
- Limits: 100,000 characters (~25,000 tokens), or 800,000 with the
  `documentcontext.whole` key ("Send long documents whole"). Past them, the
  first 80% and last 20%, counted as the lines are written, numbers included.
- **Never for `LlmProviders.TakesEndpoint` providers** (Ollama, including its
  cloud models, and OpenAI-compatible): CPU re-read time and small windows.
- Governed by `usedocumentcontext` ("Send the document, confirmed segments and
  project metadata"). The long-document box is greyed out when that is off or
  the provider is local.
- `PromptBuilder.Build` and `BuildForBatch` gained a last parameter,
  `documentContext`. Eight harnesses call them by reflection with every
  argument spelled out; a new parameter means adding one to each.
- `tools/document-context-test.ps1` simulates runs (captured and live, two
  engines) and checks the system prompt is identical between doublings. It
  passes the settings in rather than writing `shared.txt`, so it is safe while
  memoQ is open. The harnesses it touched now find the DLL relative to their own
  folder, so they test a worktree's build rather than the main checkout's.
- **Each request is its own document (fixed 2026-10-27).** memoQ runs a
  Pre-translate of several documents as parallel sessions through ONE engine, so
  an engine-wide "current document" is whichever session spoke last; until
  2026-10-27 every batch was prompted and captured as that document.
  `SupervertalerSession` now opens `EngineContext.ForRequest(metadata)` around
  each call: an AsyncLocal scope, so `CurrentDocument`, `MemoryKey` and
  `LastMetadata` answer the request's own document on every thread the call
  continues on (Task.Run, awaits). Outside a request - the store session, which
  memoQ calls with no document - they answer the engine-wide one as before. The
  document block, the bank block and the article choice are cached per document
  (`PerDocument`, at most 8), or two documents in flight rebuild them at every
  switch, and for a large bank that is a model call. `tools/multi-document-test.ps1`.

## Reading memoQ's own data off disk

Surveyed 2026-08-31, because AutoPrompt needs project context the MT SDK does not
give us. Findings, from most to least usable:

**Resource registries — usable.** `C:\ProgramData\MemoQ\Termbases.xml` and
`TranslationMemories.xml` are plain XML, one entry per resource, carrying `<Name>`,
`<Directory>`, `<ClientID>`, `<DefaultDomain>`, `<DefaultSubject>`. A project's
`project.mprx` (also plain XML, under `Documents\My memoQ Projects\<name>\`) lists
the `<TBGuid>` of every attached term base plus `<SourceLangCode>`, `<Subject>`,
`<Domain>`. So *which* resources are attached, and what they are called, is
readable. Note the registry may point outside `ProgramData` — entries here are
symlinks to `D:\Google Drive\Software\memoQ\`, and stale `<Directory>` values
survive in the file, so resolve and existence-check rather than trusting the path.

**Translation memories — effectively closed.** A TM folder is a pile of `.sst`
files: RocksDB/LevelDB SSTables. Reading one means a native RocksDB binding *and*
memoQ's undocumented key schema, re-verified every release. Not worth it — see
below for what to use instead.

**Documents — recoverable but fragile.** The per-document store at
`Documents/<docGuid>/ver1/majorVersionStore.dat` (backslashes on disk) is an
undocumented length-prefixed binary format, but the
segment text sits in it in the clear, keyed `trans-units / trans-unit#N`. Verified
against the example patent: all 21 source segments extracted. Usable as a fallback,
never as the primary route — the format has no compatibility promise.

**The conclusion that matters:** do not build on any of this if the SDK already
carries it. `MTRequestMetadata` gives Client/Domain/Subject; `DocumentMemory` gives
real confirmed translation pairs for the document in hand; the glossary gives terms;
and every source segment passes through `TranslateMany` anyway. Disk reading is for
the one thing none of those provide — *which* term bases and TMs the project has
attached, by name.

## Tech stack

- **C# / .NET Framework 4.8, x64, WinForms** — must match memoQ.exe exactly; the
  add-in loads into its AppDomain.
- memoQ 12 is `12.5.20` here, built against as the newest memoQ found.
  `MemoQ.MTInterfaces` is assembly version `3.0.0.0`, and `MemoQ.TBInterfaces` /
  `MemoQ.TMInterfaces` are `2.0.0.0`.
- **memoQ 11** (11.6.10) ships older interfaces: MTInterfaces 1.4.7, TBInterfaces 1.2,
  Addins.Common 1.5.3. None is strong-named, so the version gap does not stop loading;
  a MISSING MEMBER does. The one that bit was `ContextKinds.ForbiddenTerm`, which is new
  in 12. It made every request throw MissingFieldException in 11, and it is now looked
  up by name (PromptBuilder.ForbiddenTermKind). **Anything new from memoQ's interfaces
  must be treated the same way.** Check with
  `tools/smoketest.ps1 -MemoQPath 'C:\Program Files\memoQ\memoQ-11'`, then use it live.
  memoQ 11 also lacks Microsoft.Data.Sqlite (see "Dependencies").
- Build: `bash build.sh` (build → smoke test → deploy).
- No NuGet packages, deliberately — see "Dependencies" below.

## Where settings live (moved out of memoQ, 2026-09-02)

memoQ persists an MT plugin's settings inside an **MT settings resource**, and
the only way to that dialog is Project home, Settings, MT settings, right-click
the provider, Edit, find Supervertaler, Options. The user works with a single
resource and wanted the settings reachable without opening memoQ at all, so
they now live in two files the plugin and the prompt editor both read:

- `C:\Users\<you>\AppData\Local\Supervertaler.memoQ\shared.txt` — one
  `key=value` per line: glossary, bridgemode, provider, model, endpoint,
  parallel, batchsize, useterminology, usedocumentcontext, promptpath.
- `...\instructions.txt` — the inline instructions, in their own file because
  they are the one setting that spans lines.

Three rules hold this together:

1. **`SharedSettings` knows nothing about the settings model.** The prompt
   editor compiles the very same source file (a `<Compile Include>` link in its
   csproj, alongside `LlmProviders.cs`), so it must not reference memoQ SDK
   types. It reports errors through an `ErrorSink` the plugin points at its log
   and the editor leaves silent.
2. **`EngineContext.General` is the single overlay point.** It returns the
   stored resource values with anything the shared file carries laid over the
   top, resolved on every access so a change in the editor lands on the next
   segment. All eight consumers read settings through it and none of them know
   two stores exist.
3. **Every accessor has an `...Or(fallback)` form**, answering with the
   resource value until the file has ever carried that key. That is the whole
   migration: nothing is copied on upgrade and no flag records whether a move
   happened.

`EngineContext`'s constructor calls `SharedSettings.SeedIfUnset(...)`, filling
gaps from the resource memoQ just handed us, so the editor shows what is
actually in force rather than its own defaults.

### API keys

Resolved in `Core/ApiKeys.cs`, in order: an explicit `apikey` in the shared
file, then the key Supervertaler for Trados keeps for that provider, then the
copy of memoQ's own key seeded into `apikey.memoq`. Trados stores its keys in
plain JSON at `D:\Supervertaler	rados\settings\settings.json` under
`aiSettings.apiKeys` (`claude`, `openai`, `gemini`), so a translator running
both products rotates a key once. Clear text on disk is a deliberate choice and
matches what Trados has always done.

Two things bit while writing that reader. The file carries a **UTF-8 byte order
mark**, which the JSON reader rejects as an unexpected character. And
`DataContractJsonSerializer` walks members in contract order and returned
**every key empty** against a file that plainly had them; it is the wrong tool
for a document another product owns. `JsonReaderWriterFactory` into an
`XDocument` is order-independent and indifferent to the fifty other settings.

### The harness trap this creates

**Always run a harness through `tools/run-harness.ps1`.** A harness builds an
engine from a bare defaults object, and two things follow from that:

- Seeding writes those defaults into `shared.txt`, and because seeding only
  fills gaps, memoQ then finds the keys present and never seeds the real ones.
  One unguarded run silently blanks the user's selected prompt.
- Key resolution finds the user's real key, so a test written around "no key
  configured" instead makes a **billable call**. This happened: a run reached
  AutoPrompt and drafted a prompt against the user's Anthropic account.

Both are off when `SUPERVERTALER_HARNESS` is set, which the wrapper and
`build.sh` (whose smoke test also builds an engine) both do. The wrapper still
snapshots and restores both files as well. Check `shared.txt` after any run that
skipped it.

## Local models (Ollama, OpenAI-compatible), added 2026-10-12

Two providers beside Anthropic, OpenAI and Google: `Ollama` and
`OpenAI-compatible` (core's `ollama` and `custom_openai`). Core already spoke to
both. memoQ never mapped to them, so the old "Endpoint (optional)" box was
**ignored from 2026-08-30**, when the add-in switched to core's client: core reads
`baseUrl` only for those two providers. The box is now greyed out for the cloud
providers.

- **`LlmProviders.CreateClient` is the only way a memoQ provider becomes a core
  client.** It refuses an unknown provider, where the old mapper fell back to
  Claude. It also refuses an OpenAI-compatible provider with no address, which
  core would send to api.openai.com. Both refusals exist for confidentiality: a
  translator who picked a local model picked it so the document stays in.
- **Every model call inside memoQ goes through `LocalServer.AskAsync`.** For the
  two local providers it shows the waiting notice (below) and does three things:
  - queues requests in the plugin, sized by Parallel requests and read on every
    call, so the time limit starts when a request is sent;
  - keeps a time limit a `TimeoutException`, not a cancellation, which would
    otherwise send every row of a batch back for the full limit again. Core
    throws one itself since c2eb1b2; memoQ rewords it, because core's message
    offers "a longer timeout in the AI settings", which memoQ does not have;
  - says "Is it running?" when nothing is listening.
- **Ollama silently truncates a long prompt.** Measured 2026-10-12, Ollama
  0.35.1, no GPU: the default context is 4,096 tokens (Ollama picks it from
  VRAM). A 25,000-token prompt was cut to its first 5 and last ~2,046 tokens,
  with HTTP 200, `done_reason` "stop" and a fluent translation. The only trace
  was a WARN in Ollama's own log. `prompt_eval_count` reports the truncated
  length, and still does when the prompt is served from Ollama's cache. So
  `EnsureWholePromptRead` refuses any reply where the server read less than half
  the estimated prompt, and `ContextTooSmallException` makes a batch skip the
  row-by-row retry.
- **Core sends `num_ctx`, `keep_alive` and `think` (core 28c6c74 and c2eb1b2,
  taken in on 2026-10-17).** Proposed from here on 10-12, written by the Trados
  session.
  - `num_ctx` is 2 × the chars/4 estimate + num_predict, rounded up to 8k, 16k,
    32k, 64k or 128k. Per endpoint + model it never drops below the largest size
    that has worked in this process, since a new size reloads the model.
  - It **overrides Ollama's own Context length setting**. So for Ollama a short
    read now means the model's own window (or the 128k ceiling), and
    `TooSmallMessage` names the model, never that setting. LM Studio and other
    OpenAI-compatible servers still get "raise the context length".
  - Core also refuses a short read itself, inside the call, as a
    `PromptTooLargeException`. `AskQueuedAsync` catches it and rethrows it as a
    `ContextTooSmallException` in memoQ's words, so a batch is still not retried
    row by row.
  - `think: false`: Gemma 4 and Qwen 3.x think by default and nothing reads it.
    One paragraph on gemma4:26b-a4b took 213 s with it, 8.4 s without.
- **Speed on a CPU:** TranslateGemma 4B took 622 s to read 25,000 tokens the
  first time and 6 s on every repeat. Hence the 30-minute `LocalTimeoutMinutes`,
  which since c2eb1b2 core applies to OpenAI-compatible servers too (they had
  the 2-minute cloud limit).
- **Keys.** Ollama is sent none. OpenAI-compatible reads only the shared file's
  `custom_openai` slot, never the provider-less leftovers (`apikey`,
  `apikey.memoq`): those hold a cloud key, and a typed address may belong to
  anyone. Migration skips both local providers.
- **Test connection tests what is in the dialog.** It used to build an
  `EngineContext`, which lays `shared.txt` over the values it is given, so it
  tested the saved provider instead.
- `tools/local-models-test.ps1` covers all of the above. Its last section runs
  against a real Ollama when one is listening (`SV_OLLAMA_MODEL`, default
  `translategemma:4b`; set it to a missing name to skip, which you should
  whenever Michael is using Ollama). LM Studio has not been tested; nothing here
  has it.

### First real use in memoQ (2026-10-13)

Michael's PC: fast, 96 GB of RAM, no graphics card. Settings: qwen2.5:7b, a
32k context, the default prompt plus a memory bank.
- **Timing.** The first segment took **13 min 22 s**: 13,903 prompt tokens read
  at 17 tokens a second, from Ollama's log. Later segments reused the cache: 12
  to 54 s, mostly spent writing at about 1.2 tokens a second.
- **memoQ asks again.** memoQ requested the same segment again after a few
  minutes; the queue kept the two in order.
- **The 7B model answered in English** on some segments, because the language pair
  was 13,000 tokens back. So `PromptBuilder` now repeats it
  (`LanguageReminder`) right before "Source segment:". The batch path cuts at
  that label and keeps the line.
- **It ended one reply with an empty `[[TC:]]`.** `BatchTranslator.WithoutEmptyComment`
  removes an empty marker, using core's `ReplyCheck.WithoutComment`, and keeps
  one with text.
- **A connection that broke off mid-request** (Ollama restarting to update
  itself) surfaced as "An error occurred while sending the request". It now gets
  its own message in `LocalServer`.

**The waiting notice** (`LocalProgress`). memoQ shows only a spinner, so the
translator assumed it had hung.
- A non-activating window in memoQ's corner, after 8 s, shown only while memoQ
  is in front, closing when the last local request is answered.
- **For Ollama on this computer it reads `%LocalAppData%\Ollama\server.log`.**
  The lines are llama.cpp's, `task N | new prompt ... task.n_tokens = T`, then
  `prompt processing, n_tokens = D, progress = P, t = S s / R tokens per
  second` every 1,024 tokens, then `prompt eval time`. It shows the share
  read and the time left. A format it does not recognise means elapsed time
  only.
- One notice for any number of requests. Each notice has its own token, so a
  notice that is closing never clears the flag of a newer one.
- **Topmost has to be in its CreateParams (`WS_EX_TOPMOST`).** WinForms applies
  `Form.TopMost` on activation, and a window with `ShowWithoutActivation` is
  never activated. So the first build's notice came up as an ordinary window,
  and the first click into memoQ covered it: Windows reported it visible, and
  nobody could see it. A check in `local-models-test.ps1` reads the real window
  style. `Toast.cs` (the Alt+Up notice) has the same latent fault; it is on
  screen for only 1.6 s.
- **Cached tokens count as read.** The `cached n_tokens = N` line raises the
  share read. In the last 1,024 tokens the notice says the translation is
  written next, because Ollama logs nothing while it writes.

**Keeping the model loaded did not work.** Ollama unloads a model 5 minutes
after the last request, and the next segment then re-reads everything.
- An empty `/api/generate` or `/api/chat` carrying `keep_alive` returns
  `done_reason: "load"` but does NOT renew a model that is already loaded:
  `/api/ps` showed the same `expires_at` after both.
- The `keep_alive` must travel with core's own request. **It does since core
  c2eb1b2: `"4h"` on every Ollama request.** It is not -1, because Trados
  Studio's normal close runs none of the plugin's shutdown code.
- A request's `keep_alive` beats the `OLLAMA_KEEP_ALIVE` variable: measured
  2026-10-17, with the variable at -1 the model loaded with a 4-hour expiry. So
  the editor's "Keep the model loaded while Ollama runs" box (0.1.15, which set
  that variable) did nothing for Supervertaler any more, and was removed the
  same day. The variable is left as the translator set it; it is Ollama's, and
  other programs may rely on it.
- Ollama does honour `keep_alive: 0` for a loaded model: an empty
  `/api/generate` returned `done_reason: "unload"` (Trados session, 0.40.5).
  `local-models-test` uses that to unload its model afterwards.

**Ollama's cloud.** A model named `*-cloud` or `*:cloud` runs on ollama.com.
- `/api/tags` lists it with `remote_host: https://ollama.com` and
  `remote_model`, at 306 bytes.
- `/api/show` refuses it outright when Cloud is off in Ollama's settings ("ollama
  cloud is disabled").
- Allowed but announced: a red line in both dialogs and a description in the
  list (both from the name), and "Ollama cloud" as the hit's label. The label
  comes from `LocalServer.ProviderLabelAsync`, which asks `/api/tags` and so
  catches a renamed cloud model too.

**The queue** (`LocalQueue`, used by `LocalServer.AskAsync`), built from the
plugin log on 2026-10-13. memoQ asks for the segment the translator lands on,
then **fetches the following rows ahead by itself** (three rows exactly 10.2 s
apart while the translator sat still, and the next row the moment an answer
arrived), and asks again for one it is still waiting on. A first version served
the newest request first, believing memoQ did not fetch ahead; it served
memoQ's look-ahead rows before the segment the translator was waiting on.
- Interactive requests go before Pre-translate batches, and within each the
  first asked goes first. That is the translator's order, and document order.
- A request for a segment already waiting or running is joined: a repeat ask
  moves a waiting one to the very front (`_front` counts down below every
  arrival stamp), and either way it is sent once. **A segment is the same
  segment even when its prompt changed** - a newly confirmed row becoming one
  of its examples got two segments translated twice. So `Turn.Segment`
  (document key + tagged source) is the identity, and for a local provider it
  is also the `TranslationCache` key: a segment answered once is served from
  the cache even after its examples change.
- A segment confirmed while it waited is skipped (`OvertakenException`). This
  works only when Supervertaler is memoQ's self-learning MT and so receives
  confirmations (`DocumentMemory.TargetFor`).
- One lock covers the waiting list, the running count and the flights. A place
  is handed over by completing the waiter's task, and every granted place is
  returned in a `finally`. `local-models-test` checks the order, the join, the
  skip and cancellation, and that the queue is empty afterwards.
- Anything awaited before a request has its place breaks the order: a request
  memoQ made later can enter the line first. So the model-window lookup below
  happens after `EnterAsync`, like the overtaken check.

**A model's own window.** Ollama loads a model with the smaller of its own
context length and the size asked for: the Context length setting until
2026-10-17, core's `num_ctx` since (qwen2.5:7b 32,768 and aya-expanse:8b 8,192
under one setting of 32,768). It cuts a prompt only when
it exceeds the whole window, and then keeps about half (`llama_server.go`,
read 2026-10-13: limit `numCtx - (numCtx - numKeep)/2`). `LocalServer` asks
`/api/show` for the model's `<arch>.context_length` on every request (about
0.1 s) and refuses before sending when core's estimate exceeds 1.5 times it;
nearer the line `EnsureWholePromptRead` judges by the server's count, and its
message says "no setting raises it" instead of "raise the context length" when
the model is the limit. With the shared memory bank Michael's prompt was
16,446 tokens; without it, 927.

**Stop** (`LocalServer.Stop`, the notice's link). Found 2026-10-13 with
gemma4:26b-a4b: a Pre-translate batch ran 13 minutes, memoQ's Cancel waits for the
request under way, `ollama stop` only unloads after it, and killing Ollama's
worker made `BatchTranslator` retry the rows one by one, so Ollama reloaded the
model. Only quitting Ollama ended it. Stop now: refuses everything waiting
(`LocalQueue.RefuseAll`), cancels what is under way (every local request is sent
with a token linked to a `CancellationTokenSource` that Stop cancels, so the
connection closes and Ollama stops), and refuses new requests for 15 s, so memoQ's
lined-up batches and the per-row fallback end at once. `StoppedException` is never
retried, by `BatchTranslator` or as a timeout. Requests therefore take
`Func<CancellationToken, Task<string>>`, not a closure over the caller's token.
Untested live so far: whether Ollama really stops generating when the connection
closes (expected, and what the log will show).

**The notice names the segment** (`Turn.Label`, `LocalProgress.Working`) with
its own clock, and says "translation ready ... click another segment and then
back" when an interactive answer arrives more than 3 minutes after memoQ asked:
memoQ stops waiting for a slow lookup and never shows a late answer, which then
sits in the cache.

**Parallel requests** is two values now: `parallel` for the cloud providers and
`parallel.local` (default 1) for Ollama and OpenAI-compatible. The dialogs show
whichever applies, and `EngineContext.General` picks it by provider.

## Consistent repetitions in Pre-translate (2026-10-23)

A Pre-translate gives every repetition of a source the translation its group got
first. Core's `RepetitionKey` and `RepetitionRun` (core 51097e2, shared with Trados);
the design is `docs/design/consistent-repetitions.md` in the Trados repo, section 4.
Nothing sent to the model changes. `tools/repetitions-test.ps1` checks the requests
are byte-identical with the setting on and off, against a fake model.

- **One place:** `SupervertalerSession.TranslateMany`, after the batch AND after
  the per-row fallback, calls `Repetitions.Align`, which calls `RepetitionRun.Settle`
  per row: the first translation a group gets in the run is its translation, and a
  later row that was worded differently, or failed, gets that one instead.
- **A run** (`PreTranslateRuns`) is continuous Pre-translate activity per language
  pair (two engines per pair would split it): it ends 60 s after its last call
  leaves, when a timer logs its summary and drops it. Each call holds a lease,
  released in a `using`, failure paths included.
- **Grid lookups and bridge mode stay out.** The origin is now read whenever the
  setting is on, not only in bridge mode (`OriginIfNeeded`). Unknown counts as
  Pre-translate.
- **memoQ numbers a segment's tags by place, closings included.** The XML id is the
  index in `ITags`, which is in position order: a pair is
  `<inline_tag id="0">B</inline_tag>`, a single tag `<inline_tag id="2"/>`, a tag
  whose partner is in another segment a bare `<inline_tag id="1">` or
  `</inline_tag>`. So two segments with the same key have the same ids, and a group
  translation is given to a repetition with `FromTaggedText(text, itsOwnSource)`.
- **But a translation re-serialised is numbered afresh.** A reply that moves a tag
  forward comes back from `ToTaggedText` with different ids from its source.
  `TagBridge.ToTaggedTextIn` reads it in the source's numbers instead, finding each
  tag by REFERENCE: `FromTaggedText` builds the translation from the source's own
  `InlineTag` objects, and `InlineTag.Equals` cannot tell two bold pairs apart.
- The key takes a tag's kind from its `Name`, never its attributes: the model never
  sees them, and each row gets its own tags back.
- Not possible here: a first occurrence memoQ fills from its own TM is never sent,
  and existing targets are never visible, so there are no conflicts to list.

## Gotchas that have already bitten

**memoQ will not load an assembly without `[assembly: Module(...)]`.** This is the
single most important fact about the plugin model, and it is invisible:
`ModuleManager.loadAssemblyModules` calls `tryGetModuleAttribute(assembly)` FIRST
and returns immediately when it is absent. No types are examined, no signature is
checked, and nothing is reported — no error dialog, no "unsigned plugin" warning,
no entry in MT settings, nothing in memoQ's own log. An assembly that implements
every interface perfectly is simply invisible. See `AssemblyModules.cs`.

The corollary: **do not hand-roll discovery checks.** The first version of
`tools/smoketest.ps1` verified "a type implements IPluginDirector2 and IModule",
passed, and the plugin was still invisible. The smoke test now calls memoQ's own
`tryGetModuleAttribute` / `IsMTAddin` / `IsAddinSigned` through reflection, which
is the only check worth trusting.

**`TranslationResult.Confidence` / `.ConfidenceProviderName` are AIQE fields, not
a match rate.** AIQE is memoQ's AI Quality Estimation feature (its own tab in the
MT settings dialog, with COMET and other providers behind an API key). Setting
those two makes memoQ render `AIQE: <name>   Score: (n%)` against every segment and
treats the plugin as a quality-estimation provider. Setting them to a constant —
which the first build did, at 0.75 — presents a fabricated number as a per-segment
quality judgement. Leave both unset unless Supervertaler genuinely scores its own
output. `Info` is the free-text field for "where did this come from", and it shows
under the hit in Translation results.

**`Supervertaler.MemoQ` shadows memoQ's own `MemoQ` root namespace.** Inside our
code, `MemoQ.MTInterfaces.MTException` resolves against `Supervertaler.MemoQ` and
fails to compile. Always `using MemoQ.MTInterfaces;` and reference types unqualified
— never inline-qualify with a leading `MemoQ.`.

**`PluginSettingsObject<TG,TS>.GeneralSettings` / `.SecureSettings` are readonly
fields**, not properties. They can only be set through the
`(TGeneralSettings, TSecureSettings)` constructor. Use
`SupervertalerSettings.Create(...)`, never an object initialiser.

**Git Bash mangles MSBuild switches.** Use `-p:` not `/p:` (a leading slash becomes
a Windows path, so the property arrives as a second project argument), and set
`MSYS2_ARG_CONV_EXCL="-p:"` — which then means `$PROJECT` must be passed through
`cygpath -w` itself.

**memoQ fails silently.** If the plugin type cannot be discovered, constructed or
initialised, the engine just does not appear in the MT list. Nothing is logged and
no error is shown. `tools/smoketest.ps1` exists to tell that apart from "I picked
the wrong menu" — it loads the built DLL exactly as memoQ's scanner does and drives
it through construction, `Initialize`, `CreateEngine` and both session factories.

## Dependencies: ship nothing

Add-ins are probed out of memoQ's own install directory
(`memoQ.exe.config`: `privatePath="DocConverters;Addins;CefSharp;x64"`), so anything
we drop into `Addins` competes with memoQ's own copy of the same library.

memoQ already ships `System.Data.SQLite.dll` + `SQLite.Interop.dll` — the exact DLL
recorded in the Trados plugin's `CLAUDE.md` as the cause of
`EntryPointNotFoundException` there. We would now be loading *into that process*.

So: every memoQ reference is `Private=false`, and the slice has zero NuGet packages.
JSON parsing uses memoQ's own `MemoQ.Addins.Common.Utils.JSON`. The termbases use
`Microsoft.Data.Sqlite`, borrowed from memoQ 12's own folder like everything else.

**The one exception: SQLite for memoQ 11 (v0.1.3).** memoQ 11 ships System.Data.SQLite
but not Microsoft.Data.Sqlite. So the installer adds, only to a memoQ whose folder
lacks `Microsoft.Data.Sqlite.dll`:
- Microsoft.Data.Sqlite 9.0.3 and SQLitePCLRaw core, batteries_v2 and
  provider.dynamic_cdecl 2.1.10, all in `Addins`;
- the native `e_sqlite3.dll` in **`Addins\runtimes\win-x64\native`**.

These are memoQ 12's own versions: the NuGet builds are byte-identical, fetched by
`tools/sqlite-redist/fetch.csproj` and pinned by SHA-256 in `build-installer.sh`.
Two things were learned the hard way:
- **Never put a native DLL loose in `Addins`.** memoQ's ModuleManager calls
  `Assembly.LoadFrom` on every `.dll` there at start-up, and a native one fails with
  BadImageFormatException. SQLitePCLRaw finds it under `runtimes\win-<arch>\native`
  beside itself, which the scan does not enter.
- **No resolver code is needed.** memoQ 11's probing covers `Addins`, and its config
  already redirects System.Memory and friends to versions that satisfy these libraries.

memoQ 12 is never given a second copy.

## Distribution

memoQ has no App Store. Three tiers, per memoQ support:

1. **Unsigned private** — build and distribute it yourself; users drop the DLL into
   the `Addins` folder and dismiss a one-time "unsigned plugin" warning. No review.
   **This is the starting point.**
2. **Signed private** — send memoQ the compiled DLL plus `PublicKey.xml` and a
   `.KGSIGN` file; the public key goes into the next maintenance release. Removes
   the warning and earns a listing on memoQ's website linking out to our download.
3. **Public** — full code review, QA and bundling into memoQ. Reserved for proven
   demand.

The `.kgsign` files next to each shipped add-in are base64 RSA signatures (1024-bit)
verified against a key baked into memoQ. Unsigned genuinely works: memoQ's own
`MemoQ.MSWordGC.dll` ships without a `.kgsign`, and our unsigned build loaded with
**no warning shown at all**. A `MemoQ.Common.Framework.Modules.IUnsignedPluginsApprove`
interface exists, so an approval prompt does happen in some configurations — it
simply did not fire here. Do not treat the absence of a warning as a sign that
something is wrong.

### Releasing

`python tools/release.py` checks, builds the installer and writes the notes, and
publishes nothing. `python tools/release.py --publish` does the same and then
publishes on GitHub, which Michael chose as the host on 2026-09-28. **Publishing
needs his explicit go-ahead in chat, every time.**

- **Stamp the changelog first.** `--publish` refuses unless the heading is
  `## [<version>] – <date>`, committed and pushed. New work then goes under a
  fresh `## [Unreleased]`.
- **Draft first, public last.** The release is created as a draft, the files are
  uploaded and their sizes read back, and only then is it made public. A failed
  upload leaves an invisible draft, never a public release with a broken installer.
- **The installer is also uploaded under a fixed name,**
  `Supervertaler-for-memoQ-Setup.exe`, because supervertaler.com/download/memoq
  points at `releases/latest/download/<that name>`. Renaming it breaks every
  download link.
- The version lives in all four csproj files and must agree. `release.py`
  refuses when it does not.

**Installation needs administrator rights** — the `Addins` folder is under Program
Files and there is no per-user equivalent. The path is version-stamped
(`memoQ-12`, `memoQ-13`, …), so a memoQ upgrade means a re-deploy. The installer
therefore installs into EVERY `memoQ-NN` folder from 11 up (six slots, newest first,
built with an ISPP `#for` over `[Files]`), and the Start Menu shortcut points to the
newest. The uninstaller removes exactly what each slot placed. Tested 2026-09-29 with
memoQ 11 and 12 side by side.

`build.sh`'s own dev deploy still targets the newest memoQ only. To deploy into
another version, stage the files and run `tools/deploy.ps1 -MemoQPath <folder>`
elevated.

## Roadmap

1. ~~MT plugin vertical slice~~ — done; loads in memoQ 12.4, appears in MT settings,
   options dialog opens, error paths report correctly.
2. ~~Get memoQ to call `CreateRichLookupSession`~~ — established that it never
   will; designed around it via `ISessionWithMetadata` + `ISessionForStoringTranslations`
   + `DocumentMemory`. **Verified working end to end 2026-08-30**: confirming a
   segment with a chosen term causes later segments to adopt it. memoQ's answer
   arrived 2026-09-17: not reachable by an MT plugin today; a new MT integration
   endpoint carrying terminology and TM hits is planned, public around Q1 2027.
   See "What to use instead" above.

   **`StoringTranslationSupported => true` only makes the engine _eligible_.** memoQ
   does not call `CreateStoreTranslationSession` until the plugin is selected under
   *Edit machine translation settings > Settings > Self-learning MT*, and the engine
   is rebuilt (restart memoQ after changing it). Until then every request logs
   `held=0` and nothing is captured — with no indication why.
3. ~~Batch several segments per LLM call~~ — shipped. `Core/BatchTranslator.cs`,
   using Core's `TranslationPrompt` batch format so library prompts written for
   numbered batches work here. memoQ hands the array overload about 10 segments
   at a time, so `BatchSize` above 10 has no effect.
4. ~~Extract `Supervertaler.Core` from the Trados plugin~~ — in progress as the
   `core/` submodule (Supervertaler-Plugin-Core): LlmClient, prompt library,
   TranslationPrompt, PromptGenerator, DocumentAnalyzer and friends. Both plugins
   compile the same sources in.
5. ~~TB plugin for TermLens~~ — shipped as `Supervertaler.MemoQ.Terms.dll`.
   Span arithmetic: map the LAST character's position and add one; mapping the
   exclusive end and adding one put spans one past the segment, which memoQ's
   tracked-changes converter turns into an ArgumentOutOfRangeException dialog.
6. Companion app for everything memoQ will not host. First piece shipped:
   `src/Supervertaler.PromptEditor`, a standalone WinForms exe launched from the
   options dialog's **Edit…** button beside the prompt picker. It deploys into
   `Addins` next to the DLLs — not because memoQ loads it (it never does) but
   because that is where the dialog looks for it.

   Written in C# against Core's `PromptLibrary` rather than in the companion's
   own language, deliberately. The format has 17 frontmatter keys in live use,
   ordered, with legacy aliases; a second implementation of it is exactly how
   nine of those keys came to be silently deleted on save. One parser, one
   writer, three consumers.

   It knows one thing the plugins do not: **which placeholders each host fills.**
   `ApplyVariables` substitutes an empty string for anything the caller had no
   value for, so `{{SOURCE_SEGMENT}}` in a memoQ prompt does not survive as
   visible text — it silently becomes nothing. The editor colours unknown
   placeholders red and warns when a prompt targeting memoQ uses one memoQ will
   not fill.
7. ~~Bridge + MCP server~~ — shipped 2026-09-01. `Core/MemoQBridge.cs` is an
   `HttpListener` inside the plugin speaking the same protocol as the Trados
   bridge; the unmodified `SupervertalerMcpServer.exe` drives it when pinned via
   `SUPERVERTALER_BRIDGE_FILE` to `<root>/memoq/runtime/bridge.json` (backslashes on disk). Verified
   end to end: initialize, tools/list (12 memoQ tools), get_project,
   stage_translations, all through the real exe.

   The tool set is the honest subset — no `go_to_segment`, no `update_segments`:
   memoQ gives a plugin no UI access. Instead the write channel is
   `stage_translations` + `Core/StagedTranslations.cs`: Claude stages pairs
   keyed on source text, and they reach the grid when the user runs
   Pre-translate or lands on the segment (checked before cache and LLM in
   SessionRunner and BatchTranslator, so a fully staged document costs zero
   LLM calls and needs no API key). `Core/CaptureStore.cs` records every
   source segment the plugin sees, which after one Pre-translate pass is the
   whole document — that is what get_project/get_segments serve. The bridge
   also exposes the glossary (lookup/add) and the shared prompt library
   (list/get/save), so Claude can draft a project prompt and the user selects
   it in the options dialog.

   **Two keys per staged pair (2026-10-01).** memoQ asks in its segment XML
   (tags as elements, `&amp;`, `<spec_char val=".."/>`); the live link's text has
   none of that. Staging only by exact text missed every tagged row, 31 of 501 on
   one job, and they silently went to the model. So each entry also has a LOOSE
   key (tags stripped, spec_char values restored, escapes undone); lookups try
   exact, then loose. Staging by partId uses memoQ's captured tagged form when
   memoQ has asked about the row, and `get_segments` shows it as `taggedSource`.
   A loose hit whose target lacks the source's tags is still delivered, marked
   "inline tags not placed". A tag is `</?` plus a letter, never a bare `<`:
   the live link's "a < b" is text.

   **Bridge mode** (`BridgeMode` setting, user-facing label "Pre-translate only
   captures and delivers staged translations", since relabelled "Pre-translate
   via Claude Desktop (MCP)") is scoped to Pre-translate. Pre-translate then costs
   nothing — capture on the first pass, delivery of staged translations on the
   second — while grid lookups keep calling the model, so a chat-driven job still
   gets live suggestions for rows Claude has not staged. It never needs toggling
   mid-job.

   **Scoping it by overload was wrong.** memoQ 12.5 asks for the row the
   translator lands on through the ARRAY overload, one row at a time, exactly as
   Pre-translate does, so until 2026-10-22 bridge mode captured those too and the
   translator got "No staged translation" instead of a suggestion. Nothing in the
   public SDK separates them (MTInterfaces 3.0 read in full, the SDK manual, the
   sample; same engine, same metadata; a one-row Pre-translate is one row). A probe
   build showed the caller does: `ClientMTManager.SyncLookupSingle` for a click,
   `PreTranslateAndStatisticsJob.preTranslateBatchMT` for every Pre-translate.
   `Core/LookupOrigin.cs` reads the stack at session entry (before `Task.Run`).
   These are memoQ internals, so it fails safe: only a positively recognised grid
   lookup goes to the model; anything else is captured as before, and the capture
   log line says "caller not recognised" when memoQ has renamed them - check that
   after every memoQ upgrade. Test: `tools/lookup-origin-test.ps1` (puts memoQ's
   real names on a real stack). A failed batch in bridge mode is no longer
   retried row by row with the model either.

   **Second capture channel:** the TB plugin's `Lookup` records every visited row
   into `CaptureStore` under a `visited_<pair>` bucket, regardless of MT provider.
   Its own key prefix, not the MT path's `nodoc_`: sharing a bucket made the
   origin reported over the bridge depend on which channel created it first.

   **Handshake ownership:** the bridge writes `bridge.json` only when the file is
   missing, ours, or owned by a dead PID. A test harness that loaded the DLL once
   overwrote memoQ's live handshake and exited, leaving memoQ listening on a port
   nothing could find. The harnesses now refuse to run while memoQ is open.

   **Language pair for staging** comes from the most recently active capture
   bucket, not the latest engine: memoQ builds one engine per target language in
   an order of its own, and the "latest" was German on a Dutch job.

8. ~~AutoPrompt~~ — shipped 2026-09-02. Button in the prompt editor; the work
   happens in the plugin over the bridge (`POST /v1/autoprompt`, not an MCP
   tool), because the captured document, confirmed pairs, glossary and API key
   are all inside memoQ's process. Same pipeline as Trados — keyword analysis,
   classification call, `PromptGenerator.BuildMetaPrompt` — plus a
   `HostConstraints` block (Core) describing how memoQ consumes a prompt:
   single unnumbered segments as well as batches, tags reproduced exactly,
   request-time confirmed pairs outrank the prompt's glossary, 1500-3000 words
   because the prompt is re-sent every ~10 segments. Inline translator
   comments are kept as in Trados — they land in the target cell and the
   translator processes them during review; the first draft of this block
   forbade them, and the user wants them. **Delimiter differs:** memoQ prompts
   use `[[TC: ...]]`, not `⟦TC: ...⟧` — U+27E6/U+27E7 are missing from Tahoma,
   Verdana and Calibri, the fonts memoQ's grid uses, and render as boxes.

   Document labels: memoQ gives the plugin only a document GUID, so
   `Core/DocumentNames.cs` resolves it to the project folder name and the
   file name from `Documents\<guid>er1\majorVersionStore.info` (first
   printable string). Labels only, never keys.

9. ~~Live document link (Preview SDK)~~ — shipped 2026-09-02, the same day the
   SDK assembly was found inside memoQ's PDF preview tool.
   `src/Supervertaler.MemoQ.Preview` registers as a preview tool, forwards every
   content update and highlight change to the bridge (`Core/PreviewStore.cs`),
   and long-polls the bridge for `goto` commands, executed through
   `RequestHighlightChange`. **Verified live:** memoQ moved the cursor. Two
   facts that shaped it: memoQ does not echo a selection it was asked to make,
   so the tool reports the new active row itself after an accepted goto; and
   **A preview part is a PARAGRAPH, not a segment.** Measured: 11 parts for a
   21-row document; part 5 is 602 characters / three sentences = grid rows
   5-7. The "11 of 21" was never about loading. Consequences: `get_segments`
   in live mode returns paragraphs (documented as such in the tool
   description); the focused range in a highlight change identifies the
   sentence — the grid row — within the paragraph, and `get_active_segment`
   cuts it out as `activeSource`/`activeTarget`; `go_to_segment` accepts
   `sourceStart`/`sourceLength` to aim at a sentence. memoQ's id list also
   arrives in STRING order (1, 10, 11, 2, ...), so rows are ordered by the
   numeric tail of the id, never by the list. **Verified live 2026-09-02:** a jump
   with a range aimed at the third sentence of paragraph 5 put memoQ's cursor
   on grid row 7. Sentence-precise, not paragraph-precise. Bridge tools added: `get_active_segment`, `go_to_segment`;
   `get_segments` serves the live view (order, targets, isActive, real name)
   when the tool is connected. The exe deploys to `<Supervertaler data folder>\memoq\preview\`
   (`D:\Supervertaler\memoq\preview\` here) — never `Addins`, because it
   carries its own Newtonsoft.Json and memoQ probes Addins for its own copy;
   and never under `%LocalAppData%`, because of the next section.

10. ~~QA over the live document~~ — shipped 2026-09-02. `Core/QaChecks.cs`
    runs the Trados plugin's checks (numbers, tags, nbsp, terminology,
    inconsistencies) over PreviewStore rows: same semantics, paragraph units,
    tag markers compared by name as a multiset since memoQ delivers text
    markers rather than tag ids. `run_verification` stays impossible — memoQ's
    own QA is not callable by a plugin. Bridge: GET /v1/qa-check?type=… and
    GET /v1/inconsistencies; five MCP tools.

11. ~~memoQ `.mcpb`~~ — shipped 2026-09-02. `tools/build_mcpb.py` packs the
    Trados repo's `Supervertaler.McpServer` exe with a manifest whose only
    difference is `env: SUPERVERTALER_HOST=memoq`. The server (Trados repo)
    understands that variable: handshake at `<root>/memoq/runtime/bridge.json`,
    a separate tool cache, memoQ wording in the not-found message, no
    `list/select_trados_instance` tools, and no Trados fallback registry.
    Verified over stdio: 19 memoQ tools, no instance tools, get_project
    answered. One server, two thin bundles. `dist/` is gitignored (29 MB).

    **ChatGPT desktop, 2026-09-21.** Same server again, registered a different
    way: ChatGPT has no equivalent of Claude Desktop's one-click bundle, so the
    editor writes a block into `~/.codex/config.toml`, the file ChatGPT desktop
    shares with Codex CLI and the Codex IDE extension. The work is
    `core/src/ChatGptMcpSetup.cs` - ported from the Trados plugin with core's
    owner's agreement, parameterised by a small options object - and the memoQ
    side is `ChatGptSetupDialog`, on Settings > Connect AI assistant.

    Three things about it worth not rediscovering. The block name carries the
    product (`mcp_servers.supervertaler_memoq`), so both products register side
    by side rather than overwriting each other. The environment goes in as an
    INLINE table, never a `[<block>.env]` section: a sub-table is a table
    header, and the remover ends our block at the next one, so an env section
    would survive a rewrite and reattach itself to whatever came after. And the
    server executable is published only with the **Trados** releases, resolved
    by asset name against `releases/latest` rather than a pinned tag - a
    dependency memoQ cannot enforce, and the reason the server eventually wants
    its own repository. `tools/codex-config-test.ps1` pins all three.

12. ~~Export glossary from a prompt~~ — shipped 2026-09-02. Core's
    `PromptGlossaryExtractor` reads every source/target table in a prompt
    (AutoPrompt's locked-terms table, or any laid out the same way), turns
    `never "X"` notes into forbidden rows, and writes the TB plugin's
    tab-separated format. Editor button **Export glossary…** writes to
    `<data folder>/memoq/glossaries/<prompt>.txt` and activates it over the
    bridge (`POST /v1/glossary/activate`, which sets `SharedSettings.GlossaryPath`).
    Tested on the real draft: 70 entries, `application → applicatie`, one
    forbidden (`apparaat`). Motivation: `check_terminology` against the general
    patent glossary flagged 9 of 11 paragraphs, every one a false positive.

## This shell cannot write to AppData (MSIX virtualisation)

Claude Code here runs inside the packaged Claude desktop app
(`Claude_pzs8sxrjxfjjc`). Windows virtualises the file system for packaged
apps: every write from this shell to `C:\Users\<user>\AppData\Local\...` or
`...\Roaming\...` — bash, PowerShell, python, child processes, even a
UAC-elevated child — lands in
`C:\Users\<user>\AppData\Local\Packages\Claude_pzs8sxrjxfjjc\LocalCache\...`.
Reads see a merged view, so memoQ's `plugin.log` reads fine and my own writes
look like they landed. Nothing outside the package sees them.

Found 2026-09-02 after an hour: seven files in every listing this shell could
produce, an empty folder in Explorer, Run and cmd. Everything (the search
tool) showed the real location.

Rules: deploy runtime files to the Supervertaler data folder (`D:`) or, via
the elevated `deploy.ps1`, to Program Files — both real. Never start the
preview tool from this shell: it inherits the sandbox, its log goes to the
package cache, and memoQ's auto-started copy is the one that matters. If a
listing here disagrees with what the user sees, the user is right.

**Orphaned preview tool:** when memoQ is killed rather than closed, the
preview tool it started lives on, and it will connect to ANY bridge whose
handshake appears — including a harness's — and consume its `goto` commands.
Two harness checks failed that way on 2026-09-02. The harnesses now refuse to
run while `Supervertaler.MemoQ.Preview.exe` is running; memoQ restarts the
tool itself, so killing an orphan costs nothing.

**The reverse trap:** once a harness run here has written
`%LocalAppData%\Supervertaler.memoQ\plugin.log` (or `preview-tool.log`), the
package copy SHADOWS memoQ's real one in this shell's merged view — reading
"the log" after that shows the harness's log, not memoQ's. Seen 2026-09-02
while looking into a memoQ hang: the tail was my own harness. Until the
plugin logs to the data folder instead, ask the user to copy the real file,
or read it through a path this shell does not virtualise.

## core is a submodule, so a freeze belongs on the pointer, not on core

`core/` is a git submodule pinned by commit - memoQ pins one, Trados pins its
own. **A commit on core's main branch does not reach either product's build
until that product bumps its pointer.**

This was missed for a fortnight, at real cost. The rule agreed with the Trados
session before their App Store submission was "no behaviour-changing commits to
core", which stalled every piece of shared work behind their release date: the
notes column for `PromptGlossaryExtractor.Entry`, the shared licence reader, the
core port of the termbase writer. The rule that was actually needed was "Trados
does not bump its pointer", which protects the release just as completely and
blocks nothing.

So: **a release freeze is per-product and applies to bumping the pointer.**
memoQ can take a core change the day it lands while Trados waits weeks. The one
discipline it needs is not pulling inside a checked-out `core/` during your own
freeze, since the build uses the checked-out state rather than the pinned
commit.

**The Trados session owns core.** Michael decided this on 2026-09-19, after both
sessions declined to settle it between themselves. The reasoning: core was
extracted from the Trados plugin and most of it is still that code, that session
has the deepest context on it, and an App Store release is slow to correct where
a memoQ add-in is a file copy.

Four rules go with it:

1. Either session may propose a core change. The owner decides.
2. **The non-owner may write a core change with the owner's prior agreement.**
   Normal practice, not an exception - an owner in a release freeze is
   unavailable to decide at exactly the moment the other side is waiting.
3. A behaviour change landing in core gets a message to the other session when
   it lands, so nobody bumps a pointer into a surprise.
4. Each product bumps its own pointer when it suits, and never inside its own
   release window.

**Byte-order marks in core: match the file you are in, and do not tidy.** Core's
files are inconsistent about the BOM - `GlossaryRepair.cs` carries one,
`LanguageCodes.cs` and `PromptTemplate.cs` do not - and the owner's ruling on
2026-09-19 is to leave it that way. Normalising them is a whole-file diff on
several files, buys nothing functional, and collides with in-flight work from
both products. Watch for a tool adding one: writing a file as `utf-8-sig` put a
BOM on a file that had none, and it took a reviewer to notice.

## Security defects are never written up in public

Every Supervertaler repository is public, deliberately: the products read
confidential client documents and send them to a model, and being able to say
"read the code and see what leaves your machine" is worth more to translators
under NDA than any obscurity would be. That is a settled decision, not an
oversight, and it is not to be re-litigated.

What follows from it is a rule about *writing*, not about code:

- **A defect in the licensing or trial system, or anything else where the
  write-up is a working recipe, does not go anywhere public.** Not an issue, and
  not a source comment, a commit message, a changelog bullet or a documentation
  page either - every one of those is in a public repository. Use a GitHub
  security advisory, which stays private until published, or a private note.
  Link to it publicly by all means; a stub can say what is being hardened
  without saying what the old behaviour permitted.
- The issue tracker is only the obvious one. The Trados side drafted a code
  comment explaining its licence fix that spelled out the trigger, the effect
  and the delivery routes - the same recipe, in source, in the same public
  repository, an hour after the issue came down - and caught it before
  committing. **State the invariant, never the method:** "only a reply that says
  active renews the window" says everything a maintainer needs and nothing an
  attacker can use.
- The distinction is between source and recipe. Publishing the code is
  transparency, and anyone reading it has to do the work. Publishing the trigger,
  the effect and the repeat interval removes that work for someone who would
  never have found it.
- This happened on 2026-09-19: a licence bypass was filed in full on the public
  Trados tracker and was readable for about an hour before being deleted. The
  private write-up is at `D:\SynologyDrive\Skills\Supervertaler licence hole
  (PRIVATE) 2026-09-19.md`.

The licensing design that follows from the same decision: the client is not a
trust boundary and must not be treated as one. Deadlines rather than
permissions, detection rather than prevention, and never a hard lockout on an
absence of information - a false lockout on a Sunday costs a customer, while a
freeloader costs revenue that was never coming.

## Licensing (wired 2026-09-23)

One Supervertaler licence covers both products. The licence itself lives in core
(`core/src/SupervertalerLicence.cs`), written and owned by the Trados session and
reviewed from here; memoQ only applies a policy on top of it, in
`Core/Licence.cs`, which the editor also compiles.

**The policy is Trados's, deliberately, so the two products never disagree about
the same licence.** Only a licence KNOWN to have lapsed (`Expired`) pauses anything,
and what it pauses is the AI: the MT engine (`SupervertalerSession`, which returns a
per-segment `MTException` so memoQ shows the reason under the grid), every bridge
route an assistant calls (read from `mcp-tools.json`, so a new tool is covered
automatically) and AutoPrompt. Reading which project is open stays open, because the
editor's own panel uses that route. Terminology, termbases, prompts and memory banks
are never gated. **`Unknown` is never a refusal** - it means the licence could not be
read, and a missing answer must never lock out a paying customer.

Three rules for anyone touching it:

- `Licence.Start` must run before anything touches `SupervertalerLicence.Instance`,
  because core's log hook has to be in place when it first loads. The director calls
  it first thing in `Initialize`; the editor calls it in `Main`.
- **A harness never reads or writes the real licence**, and never validates the real
  key online. Under `SUPERVERTALER_HARNESS` the gate is open and nothing is loaded.
  `tools/licence-gate-test.ps1` checks the licence file and the trial record are
  byte-identical afterwards, and pins the policy for every licence state - including a
  check that fails if core ever adds a state memoQ has not decided the meaning of.
- The licence window is built from a `LicenceView` snapshot, never from the live
  licence, so `tools/dialog-fit-test.ps1` measures it in all six states without
  touching anybody's licence.

Anything written about the licence in this public repository states the policy,
never how it resists tampering. See "Security defects are never written up in
public" above.

## Usage statistics and trial registration (0.1.1, 2026-09-29)

`Core/Stats.cs`, started once per memoQ session from the director's
`Initialize`, makes two background calls to Michael's stats Worker
(`supervertaler-stats` repo, the "Beijer Dashboard"). Both mirror Trados, so
one dashboard shows both products. Both are silent on failure and never run
under a harness.

- **The usage ping is genuinely opt-in.** The editor asks once, in a Yes/No
  box that can't be dismissed without an answer, and Settings has a checkbox.
  It sends only the fields the privacy policy lists: id, product `memoq`,
  plugin version, OS, memoQ version (in the `trados_version` field, which the
  dashboard labels by product) and locale. `tools/stats-test.ps1` fails if a
  field is added. **Change the privacy page first** if one ever is.
- **The editor is the only writer of the id** (`SharedSettings.SetUsageStats`).
  The plugin only reads, so two processes can never mint two ids for one install.
- **The trial registration is licensing, not statistics**, so it is not
  optional, exactly as in Trados. It runs only while there is no key, and sends
  core's `MachineId` fingerprint with product `memoq`. The Worker keeps one row
  per fingerprint, because the trial is one per computer across both plugins,
  plus a `products` list.

## MT marks: what memoQ keeps, and Remove MT marks (measured 2026-10-23)

A prospect asked how to stop memoQ showing "machine translation from MT /
Supervertaler" in the Review pane. Michael's position: a post-edited MT row is the
translator's own work, and the mark is theirs to remove (the Trados Batch
Anonymizer on the RWS AppStore does the same for SDLXLIFF).

- **The mark is memoQ's, not ours.** Every MT hit inserted into a row is stored as
  `<mq:insertedmatch matchtype="1" source="MT / <FriendlyName>">`; in memoQ 12 it
  nests the MT output itself. It survives editing and confirming, and retyping a
  row by hand does not clear it. A TM hit is `matchtype="0" source="<TM name> / "`
  plus `mq:percent` on the trans-unit. A typed row has no insertedmatch at all.
  Every engine is marked the same way (DeepL, Google, `MemoQAGT` without the
  prefix), and the SDLXLIFF converter maps the record to Trados origins.
- **Importing a cleaned file as an UPDATE does not work.** memoQ takes the statuses
  from the file but keeps the old insertedmatch, and adds a history version that
  holds it. **Removing the document and importing the cleaned file AS NEW** works,
  and keeps the document id and every segmentguid.
- **Writing an empty export's targets and importing it as an update** gives rows
  identical to typed ones, with no deletion needed. This is the basis for the
  editor translating a file itself (route B), which also works in server projects.
- **A rewritten .mqxlz needs fresh zip headers.** memoQ writes a Zip64 extra field
  holding each entry's sizes, and its reader (SharpZipLib) believes it, so an entry
  that keeps its old header is refused with "Size mismatch between central header
  and local header". `MtMarks` writes every entry anew with .NET's ZipArchive;
  `tools/mt-marks-test.ps1` reads the result with memoQ's own SharpZipLib.
- `src/Supervertaler.PromptEditor/MtMarks.cs` removes every matchtype-1 record,
  from rows and from their earlier versions, and turns `MachineTranslated` into
  `PartiallyEdited` where it removed one. It edits the file as text, never through
  an XML serializer, and writes the copy under the same name into a `Clean`
  folder beside the original, so that memoQ's Import dialog can take all of them
  with Ctrl+A. The report is a `ReportDialog`: its title-bar "?" (and F1) opens
  docs.supervertaler.com/memoq/remove-mt-marks/, as the Trados dialogs do, and
  its text scrolls rather than growing past the screen.
- The Python test kit (`tools/mt-mark-test/`) and its results stayed out of git.
  `tools/fixtures/memoq-export-with-mt.mqxlz` is a real memoQ 12 export, made of
  test sentences.

## Confidentiality

Same rule as the Trados repo: **never use real client names.** `Acme` for a client,
`PROJ-001` for a case reference. This work is patent and legal translation under
confidentiality. With a project open, real names reach `plugin.log` — substitute
before pasting output into docs, changelogs, issues or commits.
