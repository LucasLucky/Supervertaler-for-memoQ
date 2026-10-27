# Consistent repetitions in Pre-translate (2026-10-23).
#
# A Pre-translate gives every repetition of a source the translation its group
# got first (Core\Repetitions.cs, Core\PreTranslateRuns.cs; the design is
# docs/design/consistent-repetitions.md in the Trados repo, section 4). This
# checks, without memoQ:
#
#   1. the match key: exact text, tags by kind and place, never their numbers;
#   2. a translation read back in its source's tag numbers;
#   3. the alignment step, row by row, including the failure paths;
#   4. many calls aligning at once, as memoQ's parallel sessions do;
#   5. a run's lifetime: shared while calls overlap, ended a while after the last;
#   6. end to end through memoQ's session interface, against a fake
#      OpenAI-compatible server started here: the requests are identical with
#      the setting on and off, a grid lookup neither uses nor fills a run, and a
#      failed repeat is filled. No API key and no real model are involved.
#
#   powershell -NoProfile -File tools\run-harness.ps1 -Harness tools\repetitions-test.ps1
#
# What it cannot reach: memoQ itself - whether memoQ's real segments number their
# tags as SegmentBuilder's do, and what the grid shows. That is the live check.
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$MemoQPath = 'C:\Program Files\memoQ\memoQ-12'
)
$ErrorActionPreference = 'Stop'
if (-not $env:SUPERVERTALER_HARNESS) { throw 'Run this through tools\run-harness.ps1: it builds an engine, which would otherwise seed the real shared settings.' }
if (Get-Process memoQ -ErrorAction SilentlyContinue) { throw 'memoQ is running: this harness starts its own bridge and must not compete with the live one. Close memoQ first.' }
if (Get-Process Supervertaler.MemoQ.Preview -ErrorAction SilentlyContinue) { throw 'The Supervertaler preview tool is running (an orphan if memoQ is closed): it would connect to this harness bridge and eat its commands. Stop it from the tray, or: taskkill /IM Supervertaler.MemoQ.Preview.exe /F' }
$Bin = "$Root\src\Supervertaler.MemoQ\bin\Release"
Write-Host "plugin: $Bin"
Write-Host "memoQ:  $MemoQPath"

# Compiled, not a scriptblock: the session and the fake server work on
# thread-pool threads, where a scriptblock handler has no runspace (see
# bridgemode-test.ps1).
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

public static class RepetitionsHarnessResolver
{
    static string[] probe;
    [ThreadStatic] static Dictionary<string, bool> inFlight;

    public static void Attach(string[] dirs)
    {
        probe = dirs;
        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
    }

    static Assembly Resolve(object sender, ResolveEventArgs e)
    {
        string name = new AssemblyName(e.Name).Name;
        if (inFlight == null) inFlight = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        if (inFlight.ContainsKey(name)) return null;
        inFlight[name] = true;
        try
        {
            foreach (string dir in probe)
            {
                string candidate = Path.Combine(dir, name + ".dll");
                if (File.Exists(candidate)) return Assembly.LoadFrom(candidate);
            }
            return null;
        }
        catch { return null; }
        finally { inFlight.Remove(name); }
    }
}
'@
[RepetitionsHarnessResolver]::Attach([string[]]@($MemoQPath, "$MemoQPath\Addins", $Bin))

# memoQ's grid, by the name seen on the stack in memoQ 12.5 (lookup-origin-test.ps1).
Add-Type -TypeDefinition @'
using System.Reflection;
using System.Runtime.CompilerServices;

namespace MemoQ.TranslationEnvironment.MT.Managers.Local
{
    public static class ClientMTManager
    {
        [MethodImpl(MethodImplOptions.NoInlining)]
        public static object SyncLookupSingle(MethodInfo method, object session, object[] args)
        {
            return method.Invoke(session, args);
        }
    }
}
'@

# A fake OpenAI-compatible server. It records every request and answers each
# numbered segment with "NL <source>", or "R<n> <source>" when the source says
# VARY - n counting requests, so the same sentence in another request comes back
# worded differently, as a real model's does. While FailFlaky is set, any request
# carrying FLAKY gets HTTP 400 (core does not retry it).
Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

public class RepetitionsFakeModel
{
    HttpListener listener;
    int requests;
    public readonly List<string> Users = new List<string>();
    public readonly List<string> Systems = new List<string>();
    public volatile bool FailFlaky;
    public int Port;

    public void Start()
    {
        for (int port = 18950; port < 19050; port++)
        {
            var candidate = new HttpListener();
            candidate.Prefixes.Add("http://127.0.0.1:" + port + "/");
            try { candidate.Start(); }
            catch (HttpListenerException) { continue; }
            listener = candidate;
            Port = port;
            break;
        }
        if (listener == null) throw new InvalidOperationException("no free port for the fake model");

        var loop = new Thread(() =>
        {
            while (listener.IsListening)
            {
                HttpListenerContext ctx;
                try { ctx = listener.GetContext(); } catch { return; }
                ThreadPool.QueueUserWorkItem(_ => Handle(ctx));
            }
        });
        loop.IsBackground = true;
        loop.Start();
    }

    public void Stop() { try { listener.Stop(); } catch { } }

    public void Reset()
    {
        lock (Users) { Users.Clear(); Systems.Clear(); requests = 0; }
    }

    public string[] UserPrompts() { lock (Users) return Users.ToArray(); }
    public string[] SystemPrompts() { lock (Users) return Systems.ToArray(); }

    static string Translate(string source, int request)
    {
        return source.Contains("VARY") ? "R" + request + " " + source : "NL " + source;
    }

    void Handle(HttpListenerContext ctx)
    {
        try
        {
            string body;
            using (var reader = new StreamReader(ctx.Request.InputStream, Encoding.UTF8)) body = reader.ReadToEnd();
            var json = (Dictionary<string, object>)new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(body);
            string system = "", user = "";
            foreach (Dictionary<string, object> m in (object[])json["messages"])
            {
                var content = m["content"] as string ?? "";
                if ((string)m["role"] == "system") system = content; else if ((string)m["role"] == "user") user = content;
            }

            int request;
            lock (Users) { Users.Add(user); Systems.Add(system); request = ++requests; }

            if (FailFlaky && user.Contains("FLAKY"))
            {
                Send(ctx, 400, "{\"error\":{\"message\":\"fake refusal for FLAKY\",\"type\":\"invalid_request_error\"}}");
                return;
            }

            string reply;
            var at = user.IndexOf("ONLY the numbered translations.", StringComparison.Ordinal);
            if (at >= 0)
            {
                var part = user.Substring(at);
                var end = part.IndexOf("**YOUR TRANSLATIONS", StringComparison.Ordinal);
                if (end >= 0) part = part.Substring(0, end);
                var lines = new List<string>();
                foreach (Match seg in Regex.Matches(part, @"^(\d+)\. (.*?)\r?$", RegexOptions.Multiline))
                    lines.Add(seg.Groups[1].Value + ". " + Translate(seg.Groups[2].Value, request));
                reply = string.Join("\n", lines);
            }
            else
            {
                var label = user.LastIndexOf("Source segment:", StringComparison.Ordinal);
                var source = label >= 0 ? user.Substring(label + "Source segment:".Length).Trim() : user.Trim();
                reply = Translate(source, request);
            }

            var answer = new Dictionary<string, object>
            {
                { "choices", new object[] { new Dictionary<string, object> {
                    { "message", new Dictionary<string, object> { { "role", "assistant" }, { "content", reply } } },
                    { "finish_reason", "stop" } } } }
            };
            Send(ctx, 200, new JavaScriptSerializer().Serialize(answer));
        }
        catch (Exception ex)
        {
            try { Send(ctx, 500, "{\"error\":{\"message\":" + new JavaScriptSerializer().Serialize(ex.Message) + "}}"); } catch { }
        }
    }

    static void Send(HttpListenerContext ctx, int status, string json)
    {
        var bytes = Encoding.UTF8.GetBytes(json);
        ctx.Response.StatusCode = status;
        ctx.Response.ContentType = "application/json";
        ctx.Response.ContentLength64 = bytes.Length;
        ctx.Response.OutputStream.Write(bytes, 0, bytes.Length);
        ctx.Response.OutputStream.Close();
    }
}
'@

# Many calls aligning at once, the way memoQ's parallel sessions call in: each
# row aligned alone, on the thread pool, against one run.
Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Threading.Tasks;

public static class RepetitionsParallel
{
    public static string[] AlignAll(MethodInfo align, MethodInfo toTaggedIn, object run,
                                    object[] sources, object[] results, Type segmentType, Type resultType)
    {
        var delivered = new string[sources.Length];
        Parallel.For(0, sources.Length, new ParallelOptions { MaxDegreeOfParallelism = 16 }, i =>
        {
            var segs = Array.CreateInstance(segmentType, 1);
            segs.SetValue(sources[i], 0);
            var res = Array.CreateInstance(resultType, 1);
            res.SetValue(results[i], 0);
            var back = (Array)align.Invoke(null, new object[] { run, segs, res });
            var result = back.GetValue(0);
            var translation = resultType.GetField("Translation").GetValue(result);
            delivered[i] = (string)toTaggedIn.Invoke(null, new object[] { translation, sources[i] });
        });
        return delivered;
    }
}
'@

$mt     = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.MTInterfaces.dll")
$common = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.Addins.Common.dll")
$plugin = [Reflection.Assembly]::LoadFrom("$Bin\Supervertaler.MemoQ.dll")

$fails = 0; $total = 0
function Check($ok, $label) {
    $script:total++
    if (-not $ok) { $script:fails++ }
    Write-Host "$(if ($ok) {'PASS'} else {'FAIL'}) $label"
}
$Static = [Reflection.BindingFlags]'NonPublic,Public,Static'

# ---- memoQ segments, built as memoQ's own types --------------------------------
$ds       = 'MemoQ.Addins.Common.DataStructures'
$tagTypes = $common.GetType("$ds.InlineTagTypes")
$tagT     = $common.GetType("$ds.InlineTag")
$avpT     = $common.GetType("$ds.AttrValPair")
$sbT      = $common.GetType("$ds.SegmentBuilder")
$segT     = $common.GetType("$ds.Segment")
$resultT  = $mt.GetType('MemoQ.MTInterfaces.TranslationResult')
$avpCtor  = $avpT.GetConstructors() | Where-Object { $_.GetParameters().Count -ceq 3 } | Select-Object -First 1
$appendTag = $sbT.GetMethod('AppendInlineTag', [Type[]]@($tagT))
$appendStr = $sbT.GetMethod('AppendString', [Type[]]@([string]))
$toSegment = $sbT.GetMethod('ToSegment', [Type[]]@())

# A tag: kind Open, Close or Empty, a name, and an id attribute that differs
# between occurrences in real files and must not matter.
function Tag($kind, $name, $id = '1') {
    $attrs = [Array]::CreateInstance($avpT, 1)
    $attrs.SetValue($avpCtor.Invoke([object[]]@('id', [string]$id, $false)), 0)
    $a = New-Object object[] 3
    $a[0] = [Enum]::Parse($tagTypes, $kind); $a[1] = $name; $a[2] = $attrs
    return $tagT.GetConstructors()[0].Invoke($a)
}
# A segment from strings and tags, in order.
function Seg {
    $sb = [Activator]::CreateInstance($sbT)
    foreach ($part in $args) {
        if ($part -is [string]) { [void]$appendStr.Invoke($sb, @($part)) }
        else { [void]$appendTag.Invoke($sb, @($part)) }
    }
    return $toSegment.Invoke($sb, @())
}
function SegArray { $a = [Array]::CreateInstance($segT, $args.Count); for ($i = 0; $i -lt $args.Count; $i++) { $a[$i] = $args[$i] }; return ,$a }
function ResultArray { $a = [Array]::CreateInstance($resultT, $args.Count); for ($i = 0; $i -lt $args.Count; $i++) { $a[$i] = $args[$i] }; return ,$a }

$repT     = $plugin.GetType('Supervertaler.MemoQ.Core.Repetitions')
$bridgeT  = $plugin.GetType('Supervertaler.MemoQ.Core.TagBridge')
$runT     = $plugin.GetType('Supervertaler.Core.RepetitionRun')
$runsT    = $plugin.GetType('Supervertaler.MemoQ.Core.PreTranslateRuns')
$keyOf    = $repT.GetMethod('KeyOf', $Static)
$tokensOf = $repT.GetMethod('Tokens', $Static)
$align    = $repT.GetMethod('Align', $Static)
$toTagged = $bridgeT.GetMethod('ToTaggedText', $Static)
$toTaggedIn = $bridgeT.GetMethod('ToTaggedTextIn', $Static)
$fromTagged = $bridgeT.GetMethod('FromTaggedText', $Static)
$asMemoQError = $plugin.GetType('Supervertaler.MemoQ.Core.BatchTranslator').GetMethod('AsMemoQError', $Static)

function Key($seg) { $keyOf.Invoke($null, @($seg)) }
function Xml($seg) { [string]$toTagged.Invoke($null, @($seg)) }
function InSource($translation, $source) { $toTaggedIn.Invoke($null, @($translation, $source)) }
function FromText($text, $source) { $fromTagged.Invoke($null, @($text, $source)) }
function Ok($text, $source, $info = 'Model / m') {
    $r = [Activator]::CreateInstance($resultT)
    $r.Translation = FromText $text $source
    $r.Info = $info
    return $r
}
function Failed {
    $r = [Activator]::CreateInstance($resultT)
    $r.Exception = $asMemoQError.Invoke($null, @([InvalidOperationException]::new('fake failure')))
    return $r
}
function NewRun { [Activator]::CreateInstance($runT) }
function Align($run, $sources, $results) { , $align.Invoke($null, @($run, $sources, $results)) }
function Same($a, $b) { [object]::ReferenceEquals($a, $b) }
$NBSP = [string][char]0xA0
$Aligned = 'same translation as an earlier repetition in this run'

# ---- 1. the match key -----------------------------------------------------------
Write-Host '-- the match key'
Check ((Key (Seg 'The pump is primed.')) -ceq (Key (Seg 'The pump is primed.'))) 'the same sentence in two rows has one key'
Check ((Key (Seg 'The pump is primed.')) -cne (Key (Seg 'the pump is primed.'))) 'case counts'
Check ((Key (Seg 'A tolerance of 5 %.')) -cne (Key (Seg "A tolerance of 5$NBSP%."))) 'a non-breaking space is not a space'
Check ((Key (Seg "Step`t1")) -cne (Key (Seg 'Step 1'))) 'a tab is not a space'
Check ((Key (Seg ('Line one' + [char]0x2028 + 'two'))) -cne (Key (Seg 'Line one two'))) 'a line separator is not a space'
Check ((Key (Seg 'Done.')) -cne (Key (Seg 'Done. '))) 'a trailing space counts: exact text'
Check ((Key (Seg 'Press ' (Tag Open bold 1) 'Start' (Tag Close bold 1) ' now.')) -ceq `
       (Key (Seg 'Press ' (Tag Open bold 7) 'Start' (Tag Close bold 7) ' now.'))) 'the same tags with different ids share a key'
Check ((Key (Seg 'Press ' (Tag Open bold) 'Start' (Tag Close bold) ' now.')) -cne `
       (Key (Seg 'Press ' (Tag Open italic) 'Start' (Tag Close italic) ' now.'))) 'a bold pair is not an italic pair'
Check ((Key (Seg 'Press ' (Tag Open bold) 'Start' (Tag Close bold) ' now.')) -cne (Key (Seg 'Press Start now.'))) 'a tagged sentence is not its plain text'
Check ((Key (Seg 'Press ' (Tag Open bold) 'Start' (Tag Close bold) ' now.')) -cne (Key (Seg 'Press <b>Start</b> now.'))) 'tag markup typed as text is text, not a tag'
Check ((Key (Seg 'See ' (Tag Empty image) ' and ' (Tag Open bold) 'this' (Tag Close bold) '.')) -cne `
       (Key (Seg 'See ' (Tag Open bold) ' and ' (Tag Close bold) 'this' (Tag Empty image) '.'))) 'the same tags in another order are another key'
Check ((Key (Seg 'Lone ' (Tag Close bold) ' end.')) -cne (Key (Seg 'Lone ' (Tag Close italic) ' end.'))) 'a closing tag whose opening is elsewhere still has its kind'
Check ((Key (Seg 'Tom & Jerry')) -ceq (Key (Seg 'Tom & Jerry'))) 'a character memoQ writes as spec_char keys as itself'
Check ((Key (Seg 'Tom & Jerry')) -cne (Key (Seg 'Tom &amp; Jerry'))) '"&" is not the text "&amp;"'
Check ((Key (Seg '1,000.5')) -cne $null) 'a number-only row is grouped: its format changes by language'
Check ($null -ceq (Key (Seg ''))) 'an empty row has no key'
Check ($null -ceq (Key (Seg (Tag Empty image)))) 'a tag-only row has no key (copied from its source anyway)'
Check ($null -ceq (Key (Seg ' - ; '))) 'a punctuation-only row has no key'
Check ($null -ceq (Key $null)) 'no segment at all: no key, no exception'

$tokens = @($tokensOf.Invoke($null, @((Xml (Seg 'A ' (Tag Open bold) 'B' (Tag Close bold) ' C ' (Tag Empty image))),
                                      (Seg 'A ' (Tag Open bold) 'B' (Tag Close bold) ' C ' (Tag Empty image)).ITags)))
$shape = ($tokens | ForEach-Object { "$($_.Kind):$($_.Value)" }) -join '|'
Check ($shape -ceq 'Text:A |TagOpen:bold|Text:B|TagClose:bold|Text: C |TagStandalone:image') "the tokens follow the segment ($shape)"

# ---- 2. a translation in its source's tag numbers -------------------------------
Write-Host '-- tag numbers'
$src = Seg 'A ' (Tag Open bold) 'B' (Tag Close bold) ' C ' (Tag Empty image)
Check ((Xml $src) -ceq 'A <inline_tag id="0">B</inline_tag> C <inline_tag id="2"/>') "memoQ numbers tags by place, closings included ($(Xml $src))"
$reply = 'X <inline_tag id="2"/> Y <inline_tag id="0">Z</inline_tag> W'
$t = FromText $reply $src
Check ((Xml $t) -cne $reply) "re-serialised, a translation that moves a tag forward is numbered afresh ($(Xml $t))"
Check ((InSource $t $src) -ceq $reply) 'read in its source''s numbers, it is what the model wrote'
$two = Seg (Tag Open bold) 'one' (Tag Close bold) ' and ' (Tag Open bold) 'two' (Tag Close bold)
$swapped = '<inline_tag id="2">twee</inline_tag> en <inline_tag id="0">een</inline_tag>'
Check ((InSource (FromText $swapped $two) $two) -ceq $swapped) 'two identical bold pairs swapped are told apart (by reference, not Equals)'
$other = Seg 'A ' (Tag Open bold) 'B' (Tag Close bold) ' C ' (Tag Empty image)
Check ($null -ceq (InSource (FromText $reply $other) $src)) 'a translation built on another segment''s tags cannot be read in this one''s: null'
Check ((InSource (FromText 'Geen tags.' $src) $src) -ceq 'Geen tags.') 'a translation without tags is its text'

# ---- 3. aligning one call --------------------------------------------------------
Write-Host '-- aligning a call'
$run = NewRun
$s1 = Seg 'The pump is primed.'; $s2 = Seg 'The pump is primed.'; $s3 = Seg 'The valve closes.'
$r1 = Ok 'De pomp is gevuld.' $s1; $r2 = Ok 'De pomp wordt gevuld.' $s2; $r3 = Ok 'De klep sluit.' $s3
$out = Align $run (SegArray $s1 $s2 $s3) (ResultArray $r1 $r2 $r3)
Check ((Xml $out[1].Translation) -ceq 'De pomp is gevuld.') 'a repetition worded differently gets the first occurrence''s translation'
Check ($out[1].Info -like "Model / m*$Aligned") "  and says so after the model's label ($($out[1].Info))"
Check ($out[1].Info -match [char]0x2013) '  with an en dash'
Check ((Same $out[0] $r1) -and (Same $out[2] $r3)) 'the first occurrence and an unrelated row are left as they were'
Check ($runT.GetProperty('Aligned').GetValue($run) -ceq 1 -and $runT.GetProperty('Differed').GetValue($run) -ceq 1) 'the run counts one aligned, worded differently'

$run = NewRun
$a1 = Ok 'Gelijk.' (Seg 'Equal.'); $a2s = Seg 'Equal.'; $a2 = Ok 'Gelijk.' $a2s
$out = Align $run (SegArray (Seg 'Equal.') $a2s) (ResultArray $a1 $a2)
Check (Same $out[1] $a2) 'a repetition the model already worded the same way is not replaced'

$run = NewRun
$f1 = Seg 'It is fastened.'; $f2 = Seg 'It is fastened.'; $failed = Failed
$out = Align $run (SegArray $f1 $f2) (ResultArray (Ok 'Het is bevestigd.' $f1) $failed)
Check ($null -ceq $out[1].Exception -and (Xml $out[1].Translation) -ceq 'Het is bevestigd.') 'a failed repetition is filled from its group'
Check ($out[1].Info -ceq "Supervertaler $([char]0x2013) $Aligned") "  its Info names Supervertaler, there being no model label ($($out[1].Info))"
Check ($runT.GetProperty('Filled').GetValue($run) -ceq 1) '  the run counts it as in place of a failed translation'

$run = NewRun
$g1 = Seg 'The arm swings.'; $g2 = Seg 'The arm swings.'; $first = Failed; $later = Ok 'De arm zwaait.' $g2
$out = Align $run (SegArray $g1 $g2) (ResultArray $first $later)
Check ((Same $out[0] $first) -and $null -cne $out[0].Exception) 'a failed first occurrence with no group yet stays failed: nothing to give it'
Check (Same $out[1] $later) '  and the first success becomes the group''s translation'
$g3 = Seg 'The arm swings.'
$out = Align $run (SegArray $g3) (ResultArray (Failed))
Check ((Xml $out[0].Translation) -ceq 'De arm zwaait.') '  which a failure in a later call is filled from'

$run = NewRun
$p1 = Seg 'Press ' (Tag Open bold 1) 'Start' (Tag Close bold 1) ' now.'
$p2 = Seg 'Press ' (Tag Open bold 7) 'Start' (Tag Close bold 7) ' now.'
$pText = 'Druk nu op <inline_tag id="0">Start</inline_tag>.'
$out = Align $run (SegArray $p1 $p2) (ResultArray (Ok $pText $p1) (Failed))
Check ((InSource $out[1].Translation $p2) -ceq $pText) 'a tagged repetition gets the translation with its tags in the same places'
Check ((Same $out[1].Translation.ITags[0] $p2.ITags[0]) -and -not (Same $out[1].Translation.ITags[0] $p1.ITags[0])) '  and they are its own tags, not the first occurrence''s'

$run = NewRun
$m1 = Seg 'A ' (Tag Open bold 1) 'B' (Tag Close bold 1) ' C ' (Tag Empty image 1)
$m2 = Seg 'A ' (Tag Open bold 2) 'B' (Tag Close bold 2) ' C ' (Tag Empty image 2)
$out = Align $run (SegArray $m1 $m2) (ResultArray (Ok $reply $m1) (Ok 'X <inline_tag id="0">Z</inline_tag> Y <inline_tag id="2"/> W' $m2))
Check ((InSource $out[1].Translation $m2) -ceq $reply) 'a group translation that moved a tag forward moves it in the repetition too'
$image = @($out[1].Translation.ITags | Where-Object { "$($_.TagType)" -ceq 'Empty' })[0]
Check (Same $image $m2.ITags[2]) '  as the repetition''s own image tag'

$run = NewRun
$copyRow = Seg (Tag Empty image); $emptyRow = Seg ''; $dashRow = Seg ' - '
$rc = Ok '<inline_tag id="0"/>' $copyRow; $re = Ok '' $emptyRow; $rd = Ok ' - ' $dashRow
$out = Align $run (SegArray $copyRow $emptyRow $dashRow) (ResultArray $rc $re $rd)
Check ((Same $out[0] $rc) -and (Same $out[1] $re) -and (Same $out[2] $rd)) 'tag-only, empty and punctuation rows are left alone'
Check ($runT.GetProperty('Delivered').GetValue($run) -ceq 0) '  and never enter the run'

$run = NewRun
$u1 = Seg 'Press ' (Tag Open bold) 'Go' (Tag Close bold) '.'; $stranger = Seg 'Press ' (Tag Open bold) 'Go' (Tag Close bold) '.'
$untraced = Ok 'Druk op <inline_tag id="0">Go</inline_tag>.' $stranger
$out = Align $run (SegArray $u1) (ResultArray $untraced)
Check ((Same $out[0] $untraced) -and $runT.GetProperty('Delivered').GetValue($run) -ceq 0) 'a translation whose tag is not its source''s is left as it is, outside the run'
$u2 = Seg 'Press ' (Tag Open bold) 'Go' (Tag Close bold) '.'; $own2 = Ok 'Druk <inline_tag id="0">Go</inline_tag> in.' $u2
$out = Align $run (SegArray $u2) (ResultArray $own2)
Check (Same $out[0] $own2) '  and did not decide its group: the next occurrence keeps its own'

$out = Align $null (SegArray $s1) (ResultArray $r1)
Check (Same $out[0] $r1) 'no run: nothing changes'

# ---- 4. many calls at once -------------------------------------------------------
Write-Host '-- parallel calls'
$run = NewRun
$n = 400
$sources = New-Object object[] $n; $results = New-Object object[] $n
for ($i = 0; $i -lt $n; $i++) {
    $sources[$i] = Seg 'Fit ' (Tag Open bold "$i") 'the cover' (Tag Close bold "$i") '.'
    $results[$i] = Ok "Breng <inline_tag id=`"0`">de kap</inline_tag> aan ($i)." $sources[$i]
}
$delivered = [RepetitionsParallel]::AlignAll($align, $toTaggedIn, $run, $sources, $results, $segT, $resultT)
$distinct = @($delivered | Sort-Object -Unique)
Check ($distinct.Count -ceq 1) "$n rows aligned from 16 threads at once come out as one translation ($($distinct.Count) distinct: $($distinct[0]))"
Check ($runT.GetProperty('Delivered').GetValue($run) -ceq $n -and $runT.GetProperty('Aligned').GetValue($run) -ceq ($n - 1)) `
    "  the run delivered $n and aligned $($n - 1): exactly one first occurrence"

# ---- 5. a run's lifetime ---------------------------------------------------------
Write-Host '-- runs'
$idle = $runsT.GetProperty('IdleEnd', $Static)
$enter = $runsT.GetMethod('Enter', $Static)
$isOpen = $runsT.GetMethod('IsOpen', $Static)
function RunOpen($pair) { [bool]$isOpen.Invoke($null, @($pair)) }
$idle.SetValue($null, [TimeSpan]::FromMilliseconds(400))
try {
    $a = $enter.Invoke($null, @('t-nl')); $b = $enter.Invoke($null, @('t-nl')); $c = $enter.Invoke($null, @('t-de'))
    Check (Same $a.Repetitions $b.Repetitions) 'two calls running at once share a run'
    Check (-not (Same $a.Repetitions $c.Repetitions)) 'another language pair has a run of its own'
    $a.Dispose(); Start-Sleep -Milliseconds 800
    Check (RunOpen 't-nl') 'a run stays open while any call is running, however long'
    $b.Dispose()
    $d = $enter.Invoke($null, @('t-nl'))
    Check (Same $d.Repetitions $b.Repetitions) 'a call starting soon after the last one left joins the same run'
    $d.Dispose(); Start-Sleep -Milliseconds 1200
    Check (-not (RunOpen 't-nl')) 'once nothing has run for the idle time, the run is ended and dropped'
    $e = $enter.Invoke($null, @('t-nl'))
    Check (-not (Same $e.Repetitions $b.Repetitions)) 'the next call starts a new run'
    $e.Dispose(); $c.Dispose()

    $f = $enter.Invoke($null, @('t-fr')); $g = $enter.Invoke($null, @('t-fr'))
    $f.Dispose(); $f.Dispose(); Start-Sleep -Milliseconds 900
    Check (RunOpen 't-fr') 'leaving twice counts once: the other call keeps the run open'
    $g.Dispose(); Start-Sleep -Milliseconds 1200
    Check (-not (RunOpen 't-fr')) '  and it ends after that call leaves'

    $log = [string]$plugin.GetType('Supervertaler.MemoQ.Core.PluginLog').GetProperty('PrimaryPath', $Static).GetValue($null)
    $tail = if (Test-Path $log) { (Get-Content $log -Tail 200 -Encoding UTF8) -join "`n" } else { '' }
    Check ($tail -match 'repetitions: Pre-translate run ended \(t-nl\) - 0 segments') "a run's end is logged with its summary ($log)"
    Check ($tail -match 'repetitions: Pre-translate run started \(t-fr\)') '  and its start'
}
finally {
    $idle.SetValue($null, [TimeSpan]::FromSeconds(60))
}

# ---- 6. end to end, through memoQ's session interface ----------------------------
Write-Host '-- end to end (fake model)'
$fake = New-Object RepetitionsFakeModel
$fake.Start()
try {
    # The shared file decides; run-harness.ps1 puts it back.
    $sharedT = $plugin.GetType('Supervertaler.MemoQ.Core.SharedSettings')
    function Shared($name, $value) { $sharedT.GetProperty($name, $Static).SetValue($null, $value) }
    Shared 'Provider' 'OpenAI-compatible'
    Shared 'Model' 'fake-model'
    Shared 'Endpoint' "http://127.0.0.1:$($fake.Port)/v1"
    Shared 'BridgeMode' $false
    Shared 'BatchSize' 2
    Shared 'LocalParallel' 1
    Shared 'SendMemoryBank' $false
    Shared 'UseTerminologyContext' $false
    Shared 'UseDocumentContext' $false
    Shared 'PromptPath' ''

    $g = [Activator]::CreateInstance($plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerGeneralSettings'))
    $s = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSettings').GetMethod('Create').Invoke($null,
        @($g, [Activator]::CreateInstance($plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSecureSettings'))))
    $engineT = $plugin.GetType('Supervertaler.MemoQ.SupervertalerMTEngine')
    $engine = [Activator]::CreateInstance($engineT, [Reflection.BindingFlags]'Instance,Public,NonPublic', $null, @($s, 'eng', 'nld'), $null)
    $session = $engineT.GetMethod('CreateLookupSession').Invoke($engine, @())
    $segArrT = $segT.MakeArrayType()
    $many = $session.GetType().GetMethod('TranslateCorrectSegment', [Type[]]@($segArrT, $segArrT, $segArrT))
    $cache = $plugin.GetType('Supervertaler.MemoQ.Core.TranslationCache')
    function PreTranslate($segs) { , $many.Invoke($session, [object[]]@($segs, $null, $null)) }
    function GridLookup($segs) { , [MemoQ.TranslationEnvironment.MT.Managers.Local.ClientMTManager]::SyncLookupSingle($many, $session, [object[]]@($segs, $null, $null)) }

    # Five rows in three batches of up to two: the repeat of row 1 is in another
    # request, so the model words it differently; row 5 repeats row 3 with tags.
    function CallA {
        SegArray (Seg 'VARY The pump is primed.') (Seg 'Fixed line one.') `
                 (Seg 'Press ' (Tag Open bold 1) 'Start' (Tag Close bold 1) ' now VARY.') `
                 (Seg 'VARY The pump is primed.') (Seg 'Press ' (Tag Open bold 9) 'Start' (Tag Close bold 9) ' now VARY.')
    }

    Shared 'KeepRepetitionsConsistent' $false
    [void]$cache.GetMethod('Clear', $Static).Invoke($null, @())
    $fake.Reset()
    $offSegs = CallA
    $off = PreTranslate $offSegs
    $offUsers = $fake.UserPrompts(); $offSystems = $fake.SystemPrompts()
    Check ($offUsers.Count -ge 3) "setting off: the call went to the fake model ($($offUsers.Count) requests)"
    Check ((Xml $off[0].Translation) -cne (Xml $off[3].Translation)) "  and the model worded the repeat differently ($(Xml $off[0].Translation) / $(Xml $off[3].Translation))"

    Shared 'KeepRepetitionsConsistent' $true
    [void]$cache.GetMethod('Clear', $Static).Invoke($null, @())
    $fake.Reset()
    $onSegs = CallA
    $on = PreTranslate $onSegs
    $onUsers = $fake.UserPrompts(); $onSystems = $fake.SystemPrompts()
    Check (($onUsers.Count -ceq $offUsers.Count) -and (@(Compare-Object $onUsers $offUsers -SyncWindow 0).Count -ceq 0) `
           -and (@(Compare-Object $onSystems $offSystems -SyncWindow 0).Count -ceq 0)) `
        "setting on: the requests sent are identical, in the same order ($($onUsers.Count) requests)"
    Check ((Xml $on[3].Translation) -ceq (Xml $on[0].Translation)) "  and the repeat gets the first occurrence's translation ($(Xml $on[3].Translation))"
    Check ($on[3].Info -like "*$Aligned") "  marked in its Info ($($on[3].Info))"
    Check ((InSource $on[4].Translation $onSegs[4]) -ceq (InSource $on[2].Translation $onSegs[2])) "  the tagged repeat too ($(InSource $on[4].Translation $onSegs[4]))"
    Check (Same $on[4].Translation.ITags[0] $onSegs[4].ITags[0]) '  with its own tags'
    Check ((Xml $on[1].Translation) -ceq 'NL Fixed line one.') '  an unrelated row keeps the model''s translation'

    # A later call in the same run, whose requests all fail: a repeat is filled
    # from the run, a sentence the run has not seen stays failed.
    $bSegs = SegArray (Seg 'FLAKY The pump is primed.') (Seg 'FLAKY New sentence.')
    $seed = PreTranslate (SegArray (Seg 'FLAKY The pump is primed.') (Seg 'Another row.'))
    $fake.FailFlaky = $true
    $b = PreTranslate $bSegs
    $fake.FailFlaky = $false
    Check ($null -ceq $b[0].Exception -and (Xml $b[0].Translation) -ceq (Xml $seed[0].Translation) -and $b[0].Info -like "*$Aligned") `
        "a failed repeat in a later call is filled from the run ($(Xml $b[0].Translation); $($b[0].Info))"
    Check ($null -cne $b[1].Exception) '  a failed sentence the run has not seen stays failed, with its error'

    # A grid lookup neither uses nor fills the run.
    $grid = GridLookup (SegArray (Seg 'VARY The pump is primed.'))
    Check ((Xml $grid[0].Translation) -cne (Xml $on[0].Translation) -and $grid[0].Info -notlike "*$Aligned*") `
        "a grid lookup gets the model's own suggestion, not the run's ($(Xml $grid[0].Translation))"
    $gridOnly = GridLookup (SegArray (Seg 'VARY Only the grid saw this.'))
    # Two rows, so they go as a batch: a single row would be served from the
    # local server's per-segment cache, which the grid lookup has just filled.
    $first = PreTranslate (SegArray (Seg 'VARY Only the grid saw this.') (Seg 'Filler one.'))
    Check ((Xml $first[0].Translation) -cne (Xml $gridOnly[0].Translation)) "  and does not fill it: the next Pre-translate keeps its own ($(Xml $first[0].Translation))"
    $second = PreTranslate (SegArray (Seg 'VARY Only the grid saw this.') (Seg 'Filler two.'))
    Check ((Xml $second[0].Translation) -ceq (Xml $first[0].Translation) -and $second[0].Info -like "*$Aligned") '  which a later Pre-translate then aligns to'

    # Bridge mode keeps out of runs: its Pre-translate captures, and staged
    # translations are keyed by source.
    Shared 'BridgeMode' $true
    $bridged = PreTranslate (SegArray (Seg 'VARY The pump is primed.'))
    Check ($null -cne $bridged[0].Exception -and $bridged[0].Exception.Message -like '*No staged translation*') 'bridge mode: a Pre-translate row is captured, not filled from the run'
    Shared 'BridgeMode' $false

    # A call leaves its run even when everything in it failed: the run then
    # ends once the idle time has passed, rather than staying open for good.
    $idle.SetValue($null, [TimeSpan]::FromMilliseconds(300))
    $fake.FailFlaky = $true
    $broken = PreTranslate (SegArray (Seg 'FLAKY Nothing works.') (Seg 'FLAKY Still nothing.'))
    $fake.FailFlaky = $false
    Check ($null -cne $broken[0].Exception -and $null -cne $broken[1].Exception) 'a call whose every request fails comes back with its errors'
    Start-Sleep -Milliseconds 1200
    Check (-not (RunOpen 'eng-nld')) '  and has left its run, which has ended'
}
finally {
    $fake.Stop()
    $idle.SetValue($null, [TimeSpan]::FromSeconds(60))
}

Write-Host ''
Write-Host "$($total - $fails) of $total passed"
if ($fails -gt 0) { Write-Host "$fails FAILED"; exit 1 } else { Write-Host 'All passed.' }
