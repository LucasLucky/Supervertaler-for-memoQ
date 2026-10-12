# Ollama and OpenAI-compatible servers: the ways a local model goes wrong.
#
# None of them is the happy path, which is one HTTP call:
#
#   - a provider the plugin does not know, or a local server with no address,
#     must be refused. Core's fallbacks are Anthropic and api.openai.com, and
#     the translator who chose a local model chose it so the document would
#     not go there;
#   - Ollama's context window is 4,096 tokens unless told otherwise, and a
#     longer prompt is cut in the middle and answered as if nothing happened
#     (measured 2026-10-12). The plugin must refuse that answer;
#   - requests to the translator's own server queue in the plugin, so a failed
#     one must still free its place, and a time limit must not turn into a
#     cancellation that sends every row of a batch back to wait again.
#
# The last section talks to a real Ollama when one is listening, and is
# skipped otherwise. Run through run-harness.ps1: fetching a model list writes
# the cache that wrapper restores.
$ErrorActionPreference = 'Stop'
$MemoQPath = 'C:\Program Files\memoQ\memoQ-12'
$PluginDll = 'D:\SynologyDrive\Dev\Sv\Supervertaler-for-memoQ\src\Supervertaler.MemoQ\bin\Release\Supervertaler.MemoQ.dll'

# Compiled, not a scriptblock: the plugin's tasks finish on pool threads, and a
# scriptblock cannot run there. C# 5 - what Windows PowerShell compiles.
Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;

public static class LocalHarness
{
    static string[] probe;
    [ThreadStatic] static Dictionary<string, bool> inFlight;
    static MethodInfo askAsync, createClient, ensureRead;
    static Type generalType, usageType;
    const BindingFlags Any = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static;

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

    public static void Init(Assembly plugin)
    {
        Type local = plugin.GetType("Supervertaler.MemoQ.Core.LocalServer", true);
        askAsync = local.GetMethod("AskAsync", Any);
        ensureRead = local.GetMethod("EnsureWholePromptRead", Any);
        createClient = plugin.GetType("Supervertaler.MemoQ.Settings.LlmProviders", true).GetMethod("CreateClient", Any);
        generalType = plugin.GetType("Supervertaler.MemoQ.Settings.SupervertalerGeneralSettings", true);
        usageType = plugin.GetType("Supervertaler.Core.ApiUsage", true);
    }

    static object General(string provider, string model, int parallel, string endpoint)
    {
        object g = Activator.CreateInstance(generalType);
        generalType.GetProperty("Provider").SetValue(g, provider);
        generalType.GetProperty("Model").SetValue(g, model);
        generalType.GetProperty("Endpoint").SetValue(g, endpoint);
        generalType.GetProperty("MaxParallelRequests").SetValue(g, parallel);
        return g;
    }

    static object Client(string provider, string model, string endpoint)
    {
        try { return createClient.Invoke(null, new object[] { provider, model, "", endpoint }); }
        catch (TargetInvocationException ex) { throw ex.InnerException; }
    }

    static Task<string> Ask(object general, object client, Func<Task<string>> request,
                            string user, string system, CancellationToken ct)
    {
        return (Task<string>)askAsync.Invoke(null, new object[] { general, client, request, user, system, ct });
    }

    static string Describe(Exception e)
    {
        while ((e is AggregateException || e is TargetInvocationException) && e.InnerException != null)
            e = e.InnerException;
        return e.GetType().Name + ": " + e.Message;
    }

    /// The type and message CreateClient throws for these settings, or "ok".
    public static string CreateClientOutcome(string provider, string endpoint)
    {
        try { Client(provider, "m", endpoint); return "ok"; }
        catch (Exception e) { return Describe(e); }
    }

    /// The most requests that were inside the server at once.
    public static int MaxConcurrent(string provider, int parallel, int requests)
    {
        object g = General(provider, "m", parallel, "http://localhost:1");
        object client = Client(provider, "m", "http://localhost:1");
        int now = 0, max = 0;
        object gate = new object();
        Task<string>[] tasks = new Task<string>[requests];
        for (int i = 0; i < requests; i++)
        {
            tasks[i] = Ask(g, client, async () =>
            {
                lock (gate) { now++; if (now > max) max = now; }
                await Task.Delay(150);
                lock (gate) { now--; }
                return "ok";
            }, "u", "s", CancellationToken.None);
        }
        Task.WaitAll(tasks);
        return max;
    }

    /// Whether a request after a failed one still gets through, with room for one only.
    public static bool FailureFreesTheQueue(bool failSynchronously)
    {
        object g = General("Ollama", "m", 1, "");
        object client = Client("Ollama", "m", "");
        Func<Task<string>> fail;
        if (failSynchronously) fail = () => { throw new InvalidOperationException("boom"); };
        else fail = async () => { await Task.Yield(); throw new InvalidOperationException("boom"); };

        try { Ask(g, client, fail, "u", "s", CancellationToken.None).Wait(); } catch { }

        Task<string> next = Ask(g, client, () => Task.FromResult("ok"), "u", "s", CancellationToken.None);
        return next.Wait(3000) && next.Result == "ok";
    }

    /// What reaches the caller when the request fails in a given way.
    public static string Outcome(string provider, string failure)
    {
        object g = General(provider, "m", 1, "http://localhost:1");
        object client = Client(provider, "m", "http://localhost:1");
        CancellationTokenSource cts = new CancellationTokenSource();
        Func<Task<string>> request;
        if (failure == "timeout")
            request = () => { throw new TaskCanceledException(); };
        else if (failure == "caller-cancelled")
            request = () => { cts.Cancel(); throw new OperationCanceledException(cts.Token); };
        else if (failure == "refused")
            request = () => { throw new HttpRequestException("An error occurred while sending the request.",
                new WebException("Unable to connect to the remote server", WebExceptionStatus.ConnectFailure)); };
        else
            request = () => { throw new HttpRequestException("Ollama API error 500: boom"); };

        try { Ask(g, client, request, "u", "s", cts.Token).Wait(); return "none"; }
        catch (Exception e) { return Describe(e); }
    }

    /// What the truncation check says about a reply that read this many tokens.
    public static string Judge(int regular, int cacheRead, int sentChars)
    {
        object usage = null;
        if (regular >= 0)
        {
            usage = Activator.CreateInstance(usageType);
            usageType.GetField("RegularInputTokens").SetValue(usage, regular);
            usageType.GetField("CacheReadTokens").SetValue(usage, cacheRead);
        }
        try { ensureRead.Invoke(null, new object[] { usage, new string('x', sentChars), null }); return "accepted"; }
        catch (Exception e) { return Describe(e); }
    }

    /// Whether a call returns within the time given. A hang is the failure being
    /// looked for, so the call runs on the pool and is waited for with a limit.
    public static bool ReturnsWithin(object target, MethodInfo method, object[] args, int milliseconds)
    {
        return Task.Run(() => method.Invoke(target, args)).Wait(milliseconds);
    }

    /// One real request to Ollama through everything the plugin puts around it.
    public static string Live(string endpoint, string model, string system, string user)
    {
        object g = General("Ollama", model, 1, endpoint);
        object client = Client("Ollama", model, endpoint);
        MethodInfo send = client.GetType().GetMethod("SendPromptAsync");
        Func<Task<string>> request = () => (Task<string>)send.Invoke(client, new object[]
        {
            user, system, (int?)60, CancellationToken.None, null, null, false, false
        });
        // On the pool, as memoQ calls it. Core's Ollama call awaits without
        // ConfigureAwait(false), so blocking on it from a thread that has a
        // WinForms context - which building the dialogs above installs - waits
        // for a continuation queued behind the wait itself, for ever.
        try { return "reply: " + Task.Run(() => Ask(g, client, request, user, system, CancellationToken.None)).Result.Trim(); }
        catch (Exception e) { return Describe(e); }
    }
}
'@

[LocalHarness]::Attach([string[]]@($MemoQPath, "$MemoQPath\Addins"))
$plugin = [Reflection.Assembly]::LoadFrom($PluginDll)
[LocalHarness]::Init($plugin)

$Static = [Reflection.BindingFlags]'Public,NonPublic,Static'
$providers = $plugin.GetType('Supervertaler.MemoQ.Settings.LlmProviders')
$catalog = $plugin.GetType('Supervertaler.MemoQ.Core.ModelCatalog')
function P($name, [object[]]$a) { $providers.GetMethod($name, $Static).Invoke($null, $a) }

$fails = 0
function Check($ok, $label) {
    if (-not $ok) { $script:fails++ }
    Write-Host "$(if ($ok) {'PASS'} else {'FAIL'}) $label"
}

# ---- 1. which provider is which ------------------------------------------
Write-Host "-- providers"
Check ((P 'CoreKey' @('Ollama')) -eq 'ollama') "Ollama maps to core's ollama"
Check ((P 'CoreKey' @('OpenAI-compatible')) -eq 'custom_openai') "OpenAI-compatible maps to core's custom_openai"
Check ($null -eq (P 'CoreKey' @('LM Studio'))) "an unknown provider maps to nothing"
foreach ($p in 'Anthropic', 'OpenAI', 'Google') {
    Check (-not (P 'TakesEndpoint' @($p)) -and (P 'NeedsKey' @($p))) "$p ignores the endpoint and needs a key"
}
foreach ($p in 'Ollama', 'OpenAI-compatible') {
    Check ((P 'TakesEndpoint' @($p)) -and -not (P 'NeedsKey' @($p))) "$p takes the endpoint and needs no key"
}
Check (-not (P 'NeedsKey' @('LM Studio'))) "an unknown provider is not said to need a key either"

# ---- 2. refusing to guess where the document goes -------------------------
Write-Host "-- refusing to guess"
$o = [LocalHarness]::CreateClientOutcome('LM Studio', 'http://localhost:1234/v1')
Check ($o -like 'InvalidOperationException:*does not know the provider*') "an unknown provider is refused, not sent to Anthropic ($o)"
$o = [LocalHarness]::CreateClientOutcome('OpenAI-compatible', '  ')
Check ($o -like 'InvalidOperationException:*No endpoint*') "an OpenAI-compatible server with no address is refused, not sent to api.openai.com"
Check ([LocalHarness]::CreateClientOutcome('OpenAI-compatible', 'http://localhost:1234/v1') -eq 'ok') "an OpenAI-compatible server with an address gets a client"
Check ([LocalHarness]::CreateClientOutcome('Ollama', '') -eq 'ok') "Ollama with no address gets a client (this computer)"
Check ([LocalHarness]::CreateClientOutcome('Anthropic', 'http://ignored') -eq 'ok') "a cloud provider with a stray endpoint still gets a client"

# ---- 3. Ollama's address ---------------------------------------------------
Write-Host "-- Ollama's address"
$cases = [ordered]@{
    ''                              = 'http://localhost:11434'
    'http://localhost:11434'        = 'http://localhost:11434'
    'http://localhost:11434/'       = 'http://localhost:11434'
    'http://localhost:11434/v1'     = 'http://localhost:11434'
    'http://localhost:11434/v1/'    = 'http://localhost:11434'
    'http://localhost:11434/api'    = 'http://localhost:11434'
    'http://gpu-box:11434'          = 'http://gpu-box:11434'
    'http://api:11434'              = 'http://api:11434'
    'https://ollama.example/proxy'  = 'https://ollama.example/proxy'
}
foreach ($k in $cases.Keys) {
    $got = P 'OllamaAddress' @($k)
    Check ($got -eq $cases[$k]) "'$k' -> '$got'"
}

# ---- 4. the queue ------------------------------------------------------------
Write-Host "-- the queue"
$m = [LocalHarness]::MaxConcurrent('Ollama', 1, 4)
Check ($m -eq 1) "Ollama with Parallel requests 1: one at a time (saw $m)"
$m = [LocalHarness]::MaxConcurrent('OpenAI-compatible', 3, 6)
Check ($m -eq 3) "OpenAI-compatible with Parallel requests 3: three at a time (saw $m)"
$m = [LocalHarness]::MaxConcurrent('Anthropic', 1, 4)
Check ($m -eq 4) "a cloud provider is not queued here (saw $m)"
Check ([LocalHarness]::FailureFreesTheQueue($true)) "a request that throws at once frees its place"
Check ([LocalHarness]::FailureFreesTheQueue($false)) "a request that fails later frees its place"

# ---- 5. how a failure reaches memoQ -----------------------------------------
Write-Host "-- failures"
$o = [LocalHarness]::Outcome('Ollama', 'timeout')
Check ($o -like 'TimeoutException:*did not answer in time*') "core's time limit is a failure, not a cancellation ($o)"
$o = [LocalHarness]::Outcome('Ollama', 'caller-cancelled')
Check ($o -like '*CanceledException*') "a caller giving up is still a cancellation ($o)"
$o = [LocalHarness]::Outcome('Ollama', 'refused')
Check ($o -like 'InvalidOperationException:*Could not reach Ollama at http://localhost:1*Is it running*') "nothing listening says so ($o)"
$o = [LocalHarness]::Outcome('Ollama', 'error')
Check ($o -like 'HttpRequestException:*500*') "a server that answers badly keeps its own message"
$o = [LocalHarness]::Outcome('Anthropic', 'timeout')
Check ($o -like 'TaskCanceledException*') "a cloud provider's failures pass through untouched"

# ---- 6. a prompt the server cut ----------------------------------------------
Write-Host "-- truncation"
# 100,000 characters is about 25,000 tokens at core's four to a token.
$o = [LocalHarness]::Judge(2051, 0, 100000)
Check ($o -like 'ContextTooSmallException:*2,051 of about 25,000*') "2,051 of 25,000 tokens read is refused ($o)"
Check ($o -like '*at least 32,768 tokens*') "and names a context length that would fit"
Check ([LocalHarness]::Judge(20000, 0, 100000) -eq 'accepted') "20,000 of 25,000 is accepted (tokenisers differ)"
Check ([LocalHarness]::Judge(3000, 10000, 100000) -eq 'accepted') "cached tokens count as read"
Check ([LocalHarness]::Judge(-1, 0, 100000) -eq 'accepted') "no count from the server is no judgement"
Check ([LocalHarness]::Judge(0, 0, 100000) -eq 'accepted') "a count of zero is no count"
Check ([LocalHarness]::Judge(100, 0, 4000) -eq 'accepted') "a prompt below 1,500 tokens is not judged"

# ---- 7. a refused batch does not hold the queue ------------------------------
# The first batch of a run takes a gate so it can warm the prompt cache alone,
# and opens it in a finally. CreateClient refuses by throwing; when it ran inside
# the gate and outside that finally, the first batch failed with the gate shut
# and the second waited for ever. Two Pre-translate calls on one engine, set to
# an OpenAI-compatible server with no address: both must come back, with the
# refusal on every row.
#
# Through memoQ's own session interface, which starts the plugin's bridge, so
# not while memoQ is open: the two must not compete for the handshake.
Write-Host "-- a refused batch"
if (Get-Process memoQ -ErrorAction SilentlyContinue) {
    Write-Host "SKIP memoQ is running; this section starts the plugin's own bridge"
}
else {
    $common = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.Addins.Common.dll")
    $builder = $common.GetType('MemoQ.Addins.Common.DataStructures.SegmentBuilder')
    function Seg($t) { $builder.GetMethod('CreateFromString').Invoke($null, @($t)) }

    # The shared file decides over memoQ's stored values; run-harness.ps1 puts it back.
    $shared = $plugin.GetType('Supervertaler.MemoQ.Core.SharedSettings')
    $shared.GetProperty('Provider', $Static).SetValue($null, 'OpenAI-compatible')
    $shared.GetProperty('Model', $Static).SetValue($null, 'local-model')
    $shared.GetProperty('Endpoint', $Static).SetValue($null, '')
    $shared.GetProperty('BridgeMode', $Static).SetValue($null, $false)

    $g = [Activator]::CreateInstance($plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerGeneralSettings'))
    $s = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSettings').GetMethod('Create').Invoke($null,
        @($g, [Activator]::CreateInstance($plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSecureSettings'))))
    $engineT = $plugin.GetType('Supervertaler.MemoQ.SupervertalerMTEngine')
    $engine = [Activator]::CreateInstance($engineT, [Reflection.BindingFlags]'Instance,Public,NonPublic', $null, @($s, 'eng', 'nld'), $null)
    $session = $engineT.GetMethod('CreateLookupSession').Invoke($engine, @())

    $segT = (Seg 'x').GetType()
    $many = $session.GetType().GetMethod('TranslateCorrectSegment',
        [Type[]]@($segT.MakeArrayType(), $segT.MakeArrayType(), $segT.MakeArrayType()))

    $allBack = $true
    foreach ($round in 1, 2) {
        $batch = [Array]::CreateInstance($segT, 3)
        for ($i = 0; $i -lt 3; $i++) { $batch[$i] = Seg "Round $round, sentence $i is fastened." }
        $argv = [object[]]@($batch, $null, $null)
        $back = [LocalHarness]::ReturnsWithin($session, $many, $argv, 30000)
        if (-not $back) { $allBack = $false }
        Check $back "Pre-translate batch $round comes back"
    }

    # The results of one more, for what the rows say. Only when the queue is
    # known to be free: asked directly, a third batch behind a shut gate would
    # hang this harness instead of failing it.
    if ($allBack) {
        $batch = [Array]::CreateInstance($segT, 2)
        $batch[0] = Seg 'The ring is fastened.'; $batch[1] = Seg 'The groove is deep.'
        $results = $many.Invoke($session, @($batch, $null, $null))
        $refused = @($results | Where-Object { $_.Exception -and $_.Exception.Message -like '*No endpoint is set*' })
        Check ($refused.Count -eq 2) "every row says why: '$($results[0].Exception.Message)'"
    }
}

# ---- 8. both settings dialogs ------------------------------------------------
# The endpoint box used to be open for every provider, with a hint promising a
# local model, and core ignored it for all three it was offered with. Now it is
# open only where it is read, the key box is shut where no key is sent, and a
# switch to a local server starts it at one request at a time.
#
# Before the live section, which fetches Ollama's list and so changes what the
# model note says.
Write-Host "-- dialogs"
Add-Type -AssemblyName System.Windows.Forms
$Instance = [Reflection.BindingFlags]'NonPublic,Instance'
$Ctor = [Reflection.BindingFlags]'Instance,Public,NonPublic'
function Field($form, $name) { $form.GetType().GetField($name, $Instance).GetValue($form) }

$generalT = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerGeneralSettings')
$secureT = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSecureSettings')
$settingsT = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSettings')
$settings = $settingsT.GetMethod('Create').Invoke($null,
    @([Activator]::CreateInstance($generalT), [Activator]::CreateInstance($secureT)))

$editorExe = 'D:\SynologyDrive\Dev\Sv\Supervertaler-for-memoQ\src\Supervertaler.PromptEditor\bin\Release\Supervertaler.PromptEditor.exe'
$editor = [Reflection.Assembly]::LoadFrom($editorExe)

$dialogs = @(
    @{ Name = "memoQ's dialog"; Make = { [Activator]::CreateInstance($plugin.GetType('Supervertaler.MemoQ.Settings.OptionsForm'), $Ctor, $null, @($settings), $null) }; Parallel = '_maxParallel'; Hint = '_endpointHint' }
    @{ Name = "the editor's dialog"; Make = { [Activator]::CreateInstance($editor.GetType('Supervertaler.PromptEditor.SettingsForm'), $Ctor, $null, @(), $null) }; Parallel = '_parallel'; Hint = '_endpointHint' }
)

foreach ($d in $dialogs) {
    $form = & $d.Make
    try {
        $provider = Field $form '_provider'
        $endpoint = Field $form '_endpoint'
        $key = Field $form '_apiKey'
        $parallel = Field $form $d.Parallel
        $hint = Field $form $d.Hint
        $model = Field $form '_model'

        Check (@($provider.Items) -contains 'Ollama' -and @($provider.Items) -contains 'OpenAI-compatible') "$($d.Name) offers Ollama and OpenAI-compatible"

        $provider.SelectedItem = 'Anthropic'
        $parallel.Value = 5
        Check (-not $endpoint.Enabled) "$($d.Name): Anthropic greys out the endpoint"
        Check ($key.Enabled) "$($d.Name): Anthropic keeps the key box"

        $provider.SelectedItem = 'Ollama'
        Check ($endpoint.Enabled) "$($d.Name): Ollama opens the endpoint"
        Check (-not $key.Enabled -and $key.Text -eq '') "$($d.Name): Ollama shuts the key box"
        Check ($parallel.Value -eq 1) "$($d.Name): Ollama starts at one request at a time"
        Check ($hint.Text -like '*localhost:11434*') "$($d.Name): the hint says where Ollama is looked for"
        Check (@($model.Items | ForEach-Object { $_.Id }) -contains 'translategemma:12b') "$($d.Name): Ollama suggests models to download"

        $parallel.Value = 3
        $provider.SelectedItem = 'OpenAI-compatible'
        Check ($endpoint.Enabled -and $key.Enabled) "$($d.Name): OpenAI-compatible opens the endpoint and the key box"
        Check ($model.Items.Count -eq 0) "$($d.Name): OpenAI-compatible offers no other provider's models ($($model.Items.Count) listed)"
        Check ($model.Text -eq '') "$($d.Name): and keeps none in the box"

        $provider.SelectedItem = 'Google'
        Check ($parallel.Value -eq 1) "$($d.Name): leaving a local server does not change Parallel requests"

        # Rewritten after the layout is fixed, so each must fit on its row.
        foreach ($p in 'Anthropic', 'Ollama', 'OpenAI-compatible') {
            $provider.SelectedItem = $p
            $w = [Windows.Forms.TextRenderer]::MeasureText($hint.Text, $hint.Font).Width
            Check ($w -le $hint.Width) "$($d.Name): the $p hint fits ($w of $($hint.Width) px)"
        }
    }
    finally { $form.Dispose() }
}

# ---- 9. a real Ollama, when there is one -------------------------------------
Write-Host "-- live Ollama"
# The dialogs left a WinForms context on this thread; see Live() for why that hangs.
[Threading.SynchronizationContext]::SetSynchronizationContext($null)
$tags = $null
try { $tags = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 3 } catch { }
$model = if ($env:SV_OLLAMA_MODEL) { $env:SV_OLLAMA_MODEL } else { 'translategemma:4b' }

if ($null -eq $tags) {
    Write-Host "SKIP no Ollama at http://localhost:11434"
}
elseif (-not ($tags.models | Where-Object { $_.name -eq $model })) {
    Write-Host "SKIP $model is not installed (set SV_OLLAMA_MODEL to another)"
}
else {
    $fetch = $catalog.GetMethod('FetchAsync', $Static)
    $listed = $fetch.Invoke($null, @('Ollama', '', 'http://localhost:11434/v1', [Threading.CancellationToken]::None)).Result
    Check (@($listed | Where-Object { $_.Id -eq $model }).Count -eq 1) "Fetch list, keyless and through a /v1 address, finds $model ($(@($listed).Count) installed)"

    $o = [LocalHarness]::Live('', $model, 'Translate from English into Dutch. Reply with the translation only.', 'The ring is fastened.')
    Check ($o -like 'reply: *') "a short prompt is translated ($o)"

    $o = [LocalHarness]::Live('http://localhost:11999', $model, 'x', 'y')
    Check ($o -like '*Could not reach Ollama at http://localhost:11999*') "a wrong port says nothing is listening ($o)"

    # The measured case: an instruction at the top of a long prompt. Either the
    # server reads all of it, or the plugin refuses the answer - never a reply
    # made without the instruction.
    $claim = 'Claim {0}: the fastening element according to claim {1}, wherein the retaining ring engages the groove at a depth of {0}.{1} millimetres. '
    $filler = -join (1..700 | ForEach-Object { $claim -f $_, ($_ % 7 + 1) })
    $system = "Translate from English into Dutch. Reply with the translation only.`n`n$filler"
    $started = Get-Date
    $o = [LocalHarness]::Live('', $model, $system, 'The ring is fastened.')
    $secs = [int]((Get-Date) - $started).TotalSeconds
    if ($o -like 'ContextTooSmallException:*') {
        Check $true "a 25,000-token prompt cut by the server is refused (${secs}s): $o"
    }
    else {
        Write-Host "INFO the server read the whole long prompt (${secs}s); its context window is large enough here"
        Check ($o -like 'reply: *') "and the reply came back ($o)"
    }
}

Write-Host
if ($fails -gt 0) { Write-Host "$fails check(s) FAILED"; exit 1 }
Write-Host "All checks passed."
