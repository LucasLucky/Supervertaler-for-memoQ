# A Pre-translate of several documents (found live 2026-10-27).
#
# memoQ sends a Pre-translate of several documents as parallel sessions through
# one engine. The engine used to keep one "current document", set by whichever
# session spoke last, so every batch was prompted and filed as that document:
# document B's rows went out with document A's text, A's confirmed examples and
# A's capture bucket. Each request now carries its own document
# (EngineContext.ForRequest). This checks, without memoQ:
#
#   1. a request's document follows the call into Task.Run, across awaits and on
#      the thread pool, and a thread started during the call falls back to the
#      engine's document once the call is over;
#   2. many calls for two documents at once never see each other's document;
#   3. the document block is each request's own, and two documents in flight do
#      not rebuild it at every switch; the per-document caches stay bounded;
#   4. end to end through memoQ's session interface, against a fake
#      OpenAI-compatible server: two documents pre-translated in parallel, round
#      after round, and every row is captured under its own document.
#
#   powershell -NoProfile -File tools\run-harness.ps1 -Harness tools\multi-document-test.ps1
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [string]$MemoQPath = 'C:\Program Files\memoQ\memoQ-12',
    # Another build to test, such as the one before a fix. run-harness.ps1 passes
    # no arguments on, so it can also come from SV_TEST_PLUGIN_DLL.
    [string]$PluginDll = $env:SV_TEST_PLUGIN_DLL
)
$ErrorActionPreference = 'Stop'
if (-not $env:SUPERVERTALER_HARNESS) { throw 'Run this through tools\run-harness.ps1: it builds an engine, which would otherwise seed the real shared settings.' }
if (Get-Process memoQ -ErrorAction SilentlyContinue) { throw 'memoQ is running: this harness starts its own bridge and must not compete with the live one. Close memoQ first.' }
if (Get-Process Supervertaler.MemoQ.Preview -ErrorAction SilentlyContinue) { throw 'The Supervertaler preview tool is running (an orphan if memoQ is closed): it would connect to this harness bridge and eat its commands. Stop it from the tray, or: taskkill /IM Supervertaler.MemoQ.Preview.exe /F' }
$Bin = "$Root\src\Supervertaler.MemoQ\bin\Release"
if (-not $PluginDll) { $PluginDll = "$Bin\Supervertaler.MemoQ.dll" }
Write-Host "plugin: $PluginDll"
Write-Host "memoQ:  $MemoQPath"

# Compiled, not scriptblocks: the work runs on thread-pool threads, where a
# scriptblock has no runspace.
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;

public static class MultiDocResolver
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
[MultiDocResolver]::Attach([string[]]@($MemoQPath, "$MemoQPath\Addins", (Split-Path $PluginDll -Parent), $Bin))

# A fake OpenAI-compatible server answering every numbered segment with
# "NL <source>". Only the session's requests need an answer here.
Add-Type -ReferencedAssemblies System.Web.Extensions -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

public class MultiDocFakeModel
{
    HttpListener listener;
    public int Port;
    public int Requests;

    public void Start()
    {
        for (int port = 19050; port < 19150; port++)
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

    void Handle(HttpListenerContext ctx)
    {
        try
        {
            string body;
            using (var reader = new StreamReader(ctx.Request.InputStream, Encoding.UTF8)) body = reader.ReadToEnd();
            Interlocked.Increment(ref Requests);
            var json = (Dictionary<string, object>)new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.DeserializeObject(body);
            string user = "";
            foreach (Dictionary<string, object> m in (object[])json["messages"])
                if ((string)m["role"] == "user") user = m["content"] as string ?? "";

            string reply;
            var at = user.IndexOf("ONLY the numbered translations.", StringComparison.Ordinal);
            if (at >= 0)
            {
                var part = user.Substring(at);
                var end = part.IndexOf("**YOUR TRANSLATIONS", StringComparison.Ordinal);
                if (end >= 0) part = part.Substring(0, end);
                var lines = new List<string>();
                foreach (Match seg in Regex.Matches(part, @"^(\d+)\. (.*?)\r?$", RegexOptions.Multiline))
                    lines.Add(seg.Groups[1].Value + ". NL " + seg.Groups[2].Value);
                reply = string.Join("\n", lines);
            }
            else
            {
                var label = user.LastIndexOf("Source segment:", StringComparison.Ordinal);
                reply = "NL " + (label >= 0 ? user.Substring(label + "Source segment:".Length).Trim() : user.Trim());
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

# The calls themselves, made the way memoQ makes them: on the thread pool, many at once.
Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;

public static class MultiDocCalls
{
    static Guid Doc(object ctx, PropertyInfo current) { return (Guid)current.GetValue(ctx); }

    // Inside a request: directly, from Task.Run, after an await. Then after it.
    public static Guid[] SeenInFlow(object ctx, MethodInfo forRequest, PropertyInfo current, object metadata)
    {
        var seen = new Guid[4];
        using ((IDisposable)forRequest.Invoke(ctx, new[] { metadata }))
        {
            seen[0] = Doc(ctx, current);
            seen[1] = Task.Run(() => Doc(ctx, current)).GetAwaiter().GetResult();
            seen[2] = Task.Run(async () => { await Task.Delay(20).ConfigureAwait(false); return Doc(ctx, current); }).GetAwaiter().GetResult();
        }
        seen[3] = Doc(ctx, current);
        return seen;
    }

    // A thread started during the request, asking once the request is over.
    public static Guid FromThreadAfterScope(object ctx, MethodInfo forRequest, PropertyInfo current, object metadata)
    {
        var seen = Guid.Empty;
        var go = new ManualResetEventSlim();
        Thread thread;
        using ((IDisposable)forRequest.Invoke(ctx, new[] { metadata }))
        {
            thread = new Thread(() => { go.Wait(); seen = Doc(ctx, current); });
            thread.Start();
        }
        go.Set();
        thread.Join();
        return seen;
    }

    // Two documents at once, round after round, each call noting its metadata as
    // the session does: how often a call saw the other document.
    public static int Crossed(object ctx, MethodInfo forRequest, MethodInfo note, PropertyInfo current,
                              object metaA, object metaB, Guid a, Guid b, int rounds)
    {
        int crossed = 0;
        Parallel.For(0, rounds * 2, new ParallelOptions { MaxDegreeOfParallelism = 8 }, i =>
        {
            var meta = i % 2 == 0 ? metaA : metaB;
            var want = i % 2 == 0 ? a : b;
            note.Invoke(ctx, new[] { meta });
            using ((IDisposable)forRequest.Invoke(ctx, new[] { meta }))
            {
                for (int k = 0; k < 10; k++)
                {
                    var got = Task.Run(async () => { await Task.Yield(); return Doc(ctx, current); }).GetAwaiter().GetResult();
                    if (got != want) Interlocked.Increment(ref crossed);
                }
            }
        });
        return crossed;
    }

    // Pre-translate calls for several documents, made at once.
    public static int PreTranslateAll(MethodInfo translate, object session, object[] segmentArrays, object[] metadata)
    {
        int failed = 0;
        Parallel.For(0, segmentArrays.Length, new ParallelOptions { MaxDegreeOfParallelism = 8 }, i =>
        {
            try { translate.Invoke(session, new[] { segmentArrays[i], null, null, metadata[i] }); }
            catch { Interlocked.Increment(ref failed); }
        });
        return failed;
    }
}
'@

$mt     = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.MTInterfaces.dll")
$common = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.Addins.Common.dll")
$plugin = [Reflection.Assembly]::LoadFrom($PluginDll)

$fails = 0; $total = 0
function Check($ok, $label) {
    $script:total++
    if (-not $ok) { $script:fails++ }
    Write-Host "$(if ($ok) {'PASS'} else {'FAIL'}) $label"
}
$Static   = [Reflection.BindingFlags]'NonPublic,Public,Static'
$Instance = [Reflection.BindingFlags]'NonPublic,Public,Instance'
function U($obj) { if ($null -eq $obj) { return $null }; return , $obj.PSObject.BaseObject }

$engineT   = $plugin.GetType('Supervertaler.MemoQ.Core.EngineContext')
$generalT  = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerGeneralSettings')
$secureT   = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSecureSettings')
$settingsT = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSettings')
$store     = $plugin.GetType('Supervertaler.MemoQ.Core.CaptureStore')
$preview   = $plugin.GetType('Supervertaler.MemoQ.Core.PreviewStore')
$partT     = $plugin.GetType('Supervertaler.MemoQ.Core.PreviewStore+Part')
$metaT     = $mt.GetType('MemoQ.MTInterfaces.MTRequestMetadata')
$settings  = $settingsT.GetMethod('Create').Invoke($null, @([Activator]::CreateInstance($generalT), [Activator]::CreateInstance($secureT)))

$forRequest = $engineT.GetMethod('ForRequest')
$note       = $engineT.GetMethod('NoteMetadata')
$current    = $engineT.GetProperty('CurrentDocument')
$memoryKey  = $engineT.GetProperty('MemoryKey')
$docBlock   = $engineT.GetMethod('DocumentContextBlock', $Instance, $null, [Type[]]@([bool], [string], [bool]), $null)
if ($null -eq $forRequest) {
    # The build before the fix: only the end-to-end check applies to it.
    Write-Host 'This build has no EngineContext.ForRequest: running the end-to-end check only.'
}

function Meta([Guid]$document) {
    $m = [Activator]::CreateInstance($metaT)
    $metaT.GetProperty('DocumentID').SetValue($m, $document)
    return $m
}
function NewEngine { return [Activator]::CreateInstance($engineT, $Instance, $null, @($settings, 'eng', 'nld'), $null) }
function Note($ctx, $meta) { [void]$note.Invoke((U $ctx), @((U $meta))) }
function Scoped($ctx, $meta, [scriptblock]$body) {
    $scope = $forRequest.Invoke((U $ctx), @((U $meta)))
    try { return & $body } finally { $scope.Dispose() }
}

$a = [Guid]::NewGuid(); $b = [Guid]::NewGuid()
$metaA = Meta $a; $metaB = Meta $b

if ($null -ne $forRequest) {
    # ---- 1. a request's document follows the call -------------------------------
    Write-Host '-- a request carries its own document'
    $ctx = NewEngine
    Note $ctx $metaA; Note $ctx $metaB          # B spoke last, as on 27 Oct
    $seen = [MultiDocCalls]::SeenInFlow((U $ctx), $forRequest, $current, (U $metaA))
    Check ($seen[0] -eq $a) 'inside a request for A, the engine reports A although B spoke last'
    Check ($seen[1] -eq $a -and $seen[2] -eq $a) '  from Task.Run, and after an await on another thread'
    Check ($seen[3] -eq $b) '  and once the request is over, the engine''s own document again (B)'
    $late = [MultiDocCalls]::FromThreadAfterScope((U $ctx), $forRequest, $current, (U $metaA))
    Check ($late -eq $b) 'a thread started during the request, asking after it ended, falls back to the engine''s document'
    $keyA = Scoped $ctx $metaA { [string]$memoryKey.GetValue((U $ctx)) }
    Check ($keyA -eq ($a.ToString('N') + '_eng-nld')) "the request's memory key is A's ($keyA)"
    $nested = Scoped $ctx $metaA { Scoped $ctx $metaB { } ; [Guid]$current.GetValue((U $ctx)) }
    Check ($nested -eq $a) 'a request inside a request restores the outer one when it ends'
    Check ($null -eq $forRequest.Invoke((U $ctx), @($null))) 'no metadata, no scope: the metadata-free overload keeps the engine''s document'

    # ---- 2. two documents at once ---------------------------------------------------
    Write-Host '-- two documents at once'
    $crossed = [MultiDocCalls]::Crossed((U $ctx), $forRequest, $note, $current, (U $metaA), (U $metaB), $a, $b, 200)
    Check ($crossed -eq 0) "400 calls for two documents at once, 4,000 reads on the thread pool: $crossed saw the other document"

    # ---- 3. the document block --------------------------------------------------------
    Write-Host '-- the document block'
    function PartList { return , [Activator]::CreateInstance([Collections.Generic.List`1].MakeGenericType(@($partT))) }
    function Live([Guid]$document, [string]$word, [int]$count) {
        $parts = PartList
        $view = [Guid]::NewGuid().ToString()
        for ($n = 1; $n -le $count; $n++) {
            $p = [Activator]::CreateInstance($partT)
            $partT.GetField('PartId').SetValue($p, "mQ-default-$view-$n")
            $partT.GetField('DocumentGuid').SetValue($p, $document)
            $partT.GetField('Source').SetValue($p, "$word paragraph $n of its own document.")
            $parts.Add($p)
        }
        [void]$preview.GetMethod('Upsert', $Static).Invoke($null, @(, (U $parts)))
    }
    Live $a 'Alpha' 30
    Live $b 'Bravo' 30
    function Block($meta) { Scoped $ctx $meta { $docBlock.Invoke((U $ctx), @($true, 'Anthropic', $false)) } }
    $blockA = Block $metaA
    $blockB = Block $metaB
    Check ($blockA.Contains('Alpha paragraph 30') -and -not $blockA.Contains('Bravo')) 'a request for A gets A''s text, although B spoke last'
    Check ($blockB.Contains('Bravo paragraph 30') -and -not $blockB.Contains('Alpha')) 'a request for B gets B''s'
    $againA = Block $metaA; $againB = Block $metaB
    Check ([object]::ReferenceEquals($againA, $blockA) -and [object]::ReferenceEquals($againB, $blockB)) 'switching between them serves each its built block, not a rebuild'
    Note $ctx $metaB    # section 2 left either document last
    $outside = $docBlock.Invoke((U $ctx), @($true, 'Anthropic', $false))
    Check ($outside.Contains('Bravo') -and -not $outside.Contains('Alpha')) 'outside a request: the engine''s document, as before'

    $perDocT = $engineT.GetNestedType('PerDocument`1', [Reflection.BindingFlags]'NonPublic,Public').MakeGenericType(@([string]))
    $keep = [int]$perDocT.GetField('Keep', $Static).GetValue($null)
    $cache = [Activator]::CreateInstance($perDocT, $true)
    $set = $perDocT.GetMethod('Set'); $tryGet = $perDocT.GetMethod('TryGet')
    function Hit($document, $key) { $args3 = [object[]]@($document, $key, $null); $ok = $tryGet.Invoke($cache, $args3); return @($ok, $args3[2]) }
    [void]$set.Invoke($cache, @('first', 'k1', 'one'))
    for ($n = 0; $n -lt 100; $n++) {
        [void]$set.Invoke($cache, @("doc$n", 'k', "v$n"))
        if ($n % 2 -eq 0) { [void](Hit 'first' 'k1') }       # kept in use
    }
    Check ([int]$perDocT.GetProperty('Count').GetValue($cache) -le $keep) "100 documents: the cache holds at most $keep"
    $h = Hit 'first' 'k1'
    Check ($h[0] -and $h[1] -eq 'one') '  and the one in use is still there'
    Check (-not (Hit 'doc0' 'k')[0]) '  the least recently used went'
    Check (-not (Hit 'doc99' 'other key')[0]) '  a changed key is a miss'
    [void]$set.Invoke($cache, @('nothing', 'k', $null))
    $none = Hit 'nothing' 'k'
    Check ($none[0] -and $null -eq $none[1]) '  and "built, and there was nothing" is remembered as such'
}

# ---- 4. end to end, through memoQ's session interface ----------------------------
Write-Host '-- end to end (fake model)'
$fake = New-Object MultiDocFakeModel
$fake.Start()
try {
    $sharedT = $plugin.GetType('Supervertaler.MemoQ.Core.SharedSettings')
    function Shared($name, $value) { $sharedT.GetProperty($name, $Static).SetValue($null, $value) }
    Shared 'Provider' 'OpenAI-compatible'
    Shared 'Model' 'fake-model'
    Shared 'Endpoint' "http://127.0.0.1:$($fake.Port)/v1"
    Shared 'BridgeMode' $false
    Shared 'BatchSize' 2
    Shared 'LocalParallel' 4
    Shared 'SendMemoryBank' $false
    Shared 'UseTerminologyContext' $false
    Shared 'UseDocumentContext' $false
    Shared 'PromptPath' ''

    $sbT = $common.GetType('MemoQ.Addins.Common.DataStructures.SegmentBuilder')
    $segT = $common.GetType('MemoQ.Addins.Common.DataStructures.Segment')
    function Seg([string]$text) { return $sbT.GetMethod('CreateFromString').Invoke($null, @($text)) }
    function SegArray([string[]]$texts) { $arr = [Array]::CreateInstance($segT, $texts.Count); for ($i = 0; $i -lt $texts.Count; $i++) { $arr[$i] = Seg $texts[$i] }; return , $arr }

    $mtEngineT = $plugin.GetType('Supervertaler.MemoQ.SupervertalerMTEngine')
    $engine = [Activator]::CreateInstance($mtEngineT, $Instance, $null, @($settings, 'eng', 'nld'), $null)
    $session = $mtEngineT.GetMethod('CreateLookupSession').Invoke($engine, @())
    $segArrT = $segT.MakeArrayType()
    $translate = $session.GetType().GetMethod('TranslateCorrectSegment', [Type[]]@($segArrT, $segArrT, $segArrT, $metaT))

    # memoQ's three sessions of 27 Oct, round after round: B's slice, and two of A's.
    $c = [Guid]::NewGuid(); $d = [Guid]::NewGuid()
    $mc = Meta $c; $md = Meta $d
    $rounds = 30
    $calls = New-Object System.Collections.Generic.List[object]
    $metas = New-Object System.Collections.Generic.List[object]
    for ($r = 0; $r -lt $rounds; $r++) {
        $calls.Add((SegArray @("Charlie $r one.", "Charlie $r two.", "Charlie $r three.", "Charlie $r four."))); $metas.Add((U $mc))
        $calls.Add((SegArray @("Delta $r one.", "Delta $r two."))); $metas.Add((U $md))
        $calls.Add((SegArray @("Delta $r three.", "Delta $r four.", "Delta $r five."))); $metas.Add((U $md))
    }
    $failed = [MultiDocCalls]::PreTranslateAll($translate, (U $session), $calls.ToArray(), $metas.ToArray())
    Check ($failed -eq 0 -and $fake.Requests -gt 0) "$($calls.Count) Pre-translate calls for two documents at once reached the fake model ($($fake.Requests) requests)"

    $get = $store.GetMethod('Get', $Static)
    function Sources([Guid]$document) {
        $capture = $get.Invoke($null, @($document.ToString('N') + '_eng-nld'))
        if ($null -eq $capture) { return @() }
        $member = $capture.GetType().GetProperty('Sources')
        $list = if ($member) { $member.GetValue($capture) } else { $capture.GetType().GetField('Sources').GetValue($capture) }
        return @($list | ForEach-Object { [string]$_ })
    }
    $inC = Sources $c; $inD = Sources $d
    $strayC = @($inC | Where-Object { $_ -like 'Delta*' }).Count
    $strayD = @($inD | Where-Object { $_ -like 'Charlie*' }).Count
    Check ($strayC -eq 0 -and $strayD -eq 0) "every row captured under its own document: $strayC of D's rows under C, $strayD of C's under D"
    Check (@($inC | Where-Object { $_ -like 'Charlie*' }).Count -eq 4 * $rounds -and @($inD | Where-Object { $_ -like 'Delta*' }).Count -eq 5 * $rounds) `
        "  and all of them there ($(@($inC).Count) for C, $(@($inD).Count) for D)"
}
finally {
    $fake.Stop()
}

Write-Host ''
Write-Host "$($total - $fails) of $total passed"
if ($fails -gt 0) { Write-Host "$fails FAILED"; exit 1 } else { Write-Host 'All passed.' }
