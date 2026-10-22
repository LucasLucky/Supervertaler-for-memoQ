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
#     (measured 2026-10-12). Core now tells it (num_ctx) and refuses a short
#     read itself, but a model's own window can still be smaller than the
#     prompt. The plugin must refuse that answer, in its own words;
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
        queueType = plugin.GetType("Supervertaler.MemoQ.Core.LocalQueue", true);
        turnType = queueType.GetNestedType("Turn", BindingFlags.NonPublic | BindingFlags.Public);
        gateType = plugin.GetType("Supervertaler.MemoQ.Core.CloudGate", true);
    }

    static Type gateType;

    /// What the cloud gate holds now - for checking nothing is left behind.
    public static string GateState() { return (string)gateType.GetMethod("State", Any).Invoke(null, null); }

    /// Anthropic with room for one: holds the place with "A", lines up the
    /// script - "B:i" someone is looking at it, "X:b" a Pre-translate batch,
    /// "C:x" given up while it waits, "F:fail" a request that fails - then lets
    /// A finish. Returns the order the requests ran in, and what each caller got.
    public static string CloudOrder(string script)
    {
        object g = General("Anthropic", "m", 1, "");
        object client = Client("Anthropic", "m", "");
        var order = new List<string>();
        object gate = new object();
        var hold = new TaskCompletionSource<string>();

        Task<string> first = Ask(g, client, () => { lock (gate) order.Add("A"); return hold.Task; },
            "cloud A", "s", CancellationToken.None, Turn(true, false));

        var tasks = new List<Task<string>>();
        var cancels = new List<CancellationTokenSource>();
        foreach (string item in script.Split(','))
        {
            string[] parts = item.Split(':');
            string label = parts[0], kind = parts[1];
            var cancel = new CancellationTokenSource();
            if (kind == "x") cancels.Add(cancel);
            Func<Task<string>> request;
            if (kind == "fail") request = () => { lock (gate) order.Add(label); throw new InvalidOperationException("boom"); };
            else request = () => { lock (gate) order.Add(label); return Task.FromResult("reply " + label); };
            tasks.Add(Ask(g, client, request, "cloud " + label, "s", cancel.Token, Turn(kind != "b", false)));
        }

        foreach (var c in cancels) c.Cancel();
        hold.SetResult("reply A");
        first.Wait(5000);

        var got = new List<string>();
        foreach (var task in tasks)
        {
            try { task.Wait(5000); got.Add(task.Result); }
            catch (Exception e) { got.Add(Describe(e).Split(':')[0]); }
        }

        lock (gate) return string.Join(",", order) + " | " + string.Join(",", got);
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
                            string user, string system, CancellationToken ct, object turn = null)
    {
        return AskWith(general, client, _ => request(), user, system, ct, turn);
    }

    /// The request is given the token it is sent with, as core's call is.
    static Task<string> AskWith(object general, object client, Func<CancellationToken, Task<string>> request,
                                string user, string system, CancellationToken ct, object turn = null)
    {
        return (Task<string>)askAsync.Invoke(null, new object[] { general, client, request, user, system, ct, turn });
    }

    static string Outcome(Task<string> task, int milliseconds)
    {
        try { return task.Wait(milliseconds) ? task.Result : "still running"; }
        catch (Exception e) { return Describe(e).Split(':')[0]; }
    }

    /// Stop with one request under way and one waiting, then one more asked
    /// for straight after, then one more once the pause is over.
    public static string StopEverything()
    {
        object g = General("Ollama", "m", 1, "http://localhost:1");
        object client = Client("Ollama", "m", "http://localhost:1");
        Type local = askAsync.DeclaringType;
        var started = new TaskCompletionSource<bool>();
        var sent = new List<string>();
        object gate = new object();

        Task<string> a = AskWith(g, client, async ct =>
        {
            lock (gate) sent.Add("A");
            started.TrySetResult(true);
            await Task.Delay(60000, ct);
            return "reply A";
        }, "stop A", "s", CancellationToken.None, Turn(true, false));
        if (!started.Task.Wait(15000)) return "A never started";

        Task<string> b = Ask(g, client, () => { lock (gate) sent.Add("B"); return Task.FromResult("reply B"); },
            "stop B", "s", CancellationToken.None, Turn(true, false));

        var clock = System.Diagnostics.Stopwatch.StartNew();
        local.GetMethod("Stop", Any).Invoke(null, null);
        string aOut = Outcome(a, 5000), bOut = Outcome(b, 5000);
        long ms = clock.ElapsedMilliseconds;

        Task<string> c = Ask(g, client, () => { lock (gate) sent.Add("C"); return Task.FromResult("reply C"); },
            "stop C", "s", CancellationToken.None, Turn(true, false));
        string cOut = Outcome(c, 5000);
        string state = QueueState();

        // The pause over: a request goes as usual.
        local.GetField("_stoppedUntil", Any).SetValue(null, DateTime.MinValue);
        Task<string> d = Ask(g, client, () => { lock (gate) sent.Add("D"); return Task.FromResult("reply D"); },
            "stop D", "s", CancellationToken.None, Turn(true, false));
        string dOut = Outcome(d, 15000);

        lock (gate)
            return "A: " + aOut + ", B: " + bOut + ", C: " + cOut + ", D: " + dOut
                + " | sent " + string.Join(",", sent) + " | " + state + " | stopped in " + (ms < 3000 ? "under 3 s" : ms + " ms");
    }

    static Type turnType, queueType;

    static object Turn(bool interactive, bool overtaken)
    {
        object turn = Activator.CreateInstance(turnType);
        turnType.GetField("Interactive").SetValue(turn, interactive);
        if (overtaken) turnType.GetField("Overtaken").SetValue(turn, new Func<bool>(() => true));
        return turn;
    }

    /// What the queue holds now - for checking nothing is left behind.
    public static string QueueState() { return (string)queueType.GetMethod("State", Any).Invoke(null, null); }

    /// Holds the only place with "A", lines up the script - "B:i" someone is
    /// looking at it, "X:b" a Pre-translate batch, "S:skip" confirmed while it
    /// waits; a repeated label is the same prompt asked again - then lets A
    /// finish. Returns the order the requests ran in, and what each caller got.
    public static string QueueOrder(string script)
    {
        object g = General("Ollama", "m", 1, "");
        object client = Client("Ollama", "m", "");
        var order = new List<string>();
        object gate = new object();
        var hold = new TaskCompletionSource<string>();

        Task<string> first = Ask(g, client, () => { lock (gate) order.Add("A"); return hold.Task; },
            "prompt A", "s", CancellationToken.None, Turn(true, false));

        var tasks = new List<Task<string>>();
        int asked = 0;
        foreach (string item in script.Split(','))
        {
            string[] parts = item.Split(':');
            string label = parts[0], kind = parts[1];
            object turn = Turn(kind != "b", kind == "skip");

            // "C:s" is a segment whose prompt differs every time it is asked -
            // a newly confirmed row became one of its examples meanwhile.
            string user = "prompt " + label;
            if (kind == "s")
            {
                turnType.GetField("Segment").SetValue(turn, "segment " + label);
                user += " #" + (asked++);
            }

            tasks.Add(Ask(g, client, () => { lock (gate) order.Add(label); return Task.FromResult("reply " + label); },
                user, "s", CancellationToken.None, turn));
        }

        hold.SetResult("reply A");
        first.Wait(5000);

        var got = new List<string>();
        foreach (var task in tasks)
        {
            try { task.Wait(5000); got.Add(task.Result); }
            catch (Exception e) { got.Add(Describe(e).Split(':')[0]); }
        }

        lock (gate) return string.Join(",", order) + " | " + string.Join(",", got);
    }

    /// A request cancelled while it waits leaves the line and gives no place back.
    public static string QueueCancelled()
    {
        object g = General("Ollama", "m", 1, "");
        object client = Client("Ollama", "m", "");
        var order = new List<string>();
        object gate = new object();
        var hold = new TaskCompletionSource<string>();
        var cancel = new CancellationTokenSource();

        Task<string> first = Ask(g, client, () => { lock (gate) order.Add("A"); return hold.Task; },
            "prompt A2", "s", CancellationToken.None, Turn(true, false));
        Task<string> b = Ask(g, client, () => { lock (gate) order.Add("B"); return Task.FromResult("reply B"); },
            "prompt B2", "s", cancel.Token, Turn(true, false));
        cancel.Cancel();
        Task<string> c = Ask(g, client, () => { lock (gate) order.Add("C"); return Task.FromResult("reply C"); },
            "prompt C2", "s", CancellationToken.None, Turn(true, false));

        hold.SetResult("reply A");
        first.Wait(5000);
        string bOutcome;
        try { b.Wait(5000); bOutcome = b.Result; } catch (Exception e) { bOutcome = Describe(e).Split(':')[0]; }
        c.Wait(5000);
        lock (gate) return string.Join(",", order) + " | B: " + bOutcome;
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
            }, "u" + i, "s", CancellationToken.None);
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

        // Generous: each request first asks Ollama about the model, and with
        // no Ollama running a refused connection takes Windows a second or two.
        Task<string> next = Ask(g, client, () => Task.FromResult("ok"), "u", "s", CancellationToken.None);
        return next.Wait(15000) && next.Result == "ok";
    }

    /// What reaches the caller when the request fails in a given way.
    public static string Outcome(string provider, string failure)
    {
        object g = General(provider, "m", 1, "http://localhost:1");
        object client = Client(provider, "m", "http://localhost:1");
        CancellationTokenSource cts = new CancellationTokenSource();
        Func<Task<string>> request;
        if (failure == "timeout")
            request = () => { throw new TimeoutException("Ollama did not answer within 30 minutes, so the request was abandoned."
                + " A longer timeout in the AI settings, a smaller model or a shorter prompt helps."); };
        else if (failure == "other-limit")
            request = () => { throw new TaskCanceledException(); };
        else if (failure == "caller-cancelled")
            request = () => { cts.Cancel(); throw new OperationCanceledException(cts.Token); };
        else if (failure == "broke-off")
            request = () => { throw new HttpRequestException("An error occurred while sending the request.",
                new WebException("The underlying connection was closed: A connection that was expected to be kept alive was closed by the server.",
                    WebExceptionStatus.KeepAliveFailure)); };
        else if (failure == "refused")
            request = () => { throw new HttpRequestException("An error occurred while sending the request.",
                new WebException("Unable to connect to the remote server", WebExceptionStatus.ConnectFailure)); };
        else
            request = () => { throw new HttpRequestException("Ollama API error 500: boom"); };

        try { Ask(g, client, request, "u", "s", cts.Token).Wait(); return "none"; }
        catch (Exception e) { return Describe(e); }
    }

    static object Usage(int regular, int cacheRead)
    {
        if (regular < 0) return null;
        object usage = Activator.CreateInstance(usageType);
        usageType.GetField("RegularInputTokens").SetValue(usage, regular);
        usageType.GetField("CacheReadTokens").SetValue(usage, cacheRead);
        return usage;
    }

    /// What the truncation check says about a reply that read this many tokens.
    public static string Judge(int regular, int cacheRead, int sentChars)
    {
        object usage = Usage(regular, cacheRead);
        try { ensureRead.Invoke(null, new object[] { usage, new string('x', sentChars), null, provider, model, window }); return "accepted"; }
        catch (Exception e) { return Describe(e); }
    }

    static string provider = "OpenAI-compatible", model;
    static int? window;

    /// The same, for a given kind of server and a model whose own window is known (0: not known).
    public static string JudgeFor(string providerName, int regular, int sentChars, string modelName, int modelWindow)
    {
        provider = providerName; model = modelName; window = modelWindow > 0 ? (int?)modelWindow : null;
        try { return Judge(regular, 0, sentChars); }
        finally { provider = "OpenAI-compatible"; model = null; window = null; }
    }

    /// What reaches the caller when core refuses a short read itself
    /// (PromptTooLargeException, thrown before the request returns), with the
    /// server's count left in LastUsage as core leaves it - or none (-1).
    public static string CoreRefusal(int regular, int sentChars)
    {
        object g = General("Ollama", "qwen2.5:7b", 1, "http://localhost:1");
        object client = Client("Ollama", "qwen2.5:7b", "http://localhost:1");
        Type refusal = usageType.Assembly.GetType("Supervertaler.Core.PromptTooLargeException", true);
        PropertyInfo last = client.GetType().GetProperty("LastUsage");
        string user = new string('x', sentChars);
        Func<Task<string>> request = () =>
        {
            last.GetSetMethod(true).Invoke(client, new object[] { Usage(regular, 0) });
            throw (Exception)Activator.CreateInstance(refusal, "core's own words");
        };
        try { Ask(g, client, request, user, null, CancellationToken.None).Wait(); return "none"; }
        catch (Exception e) { return Describe(e); }
    }

    /// What the check before sending says about a prompt this long for a model this size.
    public static string BeforeSending(int sentChars, string modelName, int modelWindow)
    {
        MethodInfo refuse = askAsync.DeclaringType.GetMethod("RefuseIfTooLarge", Any);
        int? w = modelWindow > 0 ? (int?)modelWindow : null;
        try { refuse.Invoke(null, new object[] { modelName, w, new string('x', sentChars), null }); return "sent"; }
        catch (Exception e) { return Describe(e); }
    }

    /// Whether a call returns within the time given. A hang is the failure being
    /// looked for, so the call runs on the pool and is waited for with a limit.
    public static bool ReturnsWithin(object target, MethodInfo method, object[] args, int milliseconds)
    {
        return Task.Run(() => method.Invoke(target, args)).Wait(milliseconds);
    }

    [System.Runtime.InteropServices.DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int index);

    /// The extended window style Windows actually gave a window.
    public static int ExStyle(IntPtr h) { return GetWindowLong(h, -20); }

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
# A cloud provider waits only for a place. Until 0.1.20 it did not wait at all,
# and memoQ's own limit is fixed when the MT settings resource is created, so
# the cloud value of Parallel requests did nothing (found 2026-10-14).
$m = [LocalHarness]::MaxConcurrent('Anthropic', 1, 4)
Check ($m -eq 1) "Anthropic with Parallel requests 1: one at a time (saw $m)"
$m = [LocalHarness]::MaxConcurrent('Google', 3, 6)
Check ($m -eq 3) "Google with Parallel requests 3: three at a time (saw $m)"
$o = [LocalHarness]::CloudOrder('X:b,Y:i,Z:b')
Check ($o -eq 'A,Y,X,Z | reply X,reply Y,reply Z') "cloud: a segment being looked at goes before Pre-translate, which keeps its order ($o)"
$o = [LocalHarness]::CloudOrder('B:x,C:i')
Check ($o -eq 'A,C | TaskCanceledException,reply C') "cloud: a request given up while it waits is never sent ($o)"
$o = [LocalHarness]::CloudOrder('F:fail,G:i')
Check ($o -eq 'A,F,G | InvalidOperationException,reply G') "cloud: a request that fails gives its place back ($o)"
$s = [LocalHarness]::GateState()
Check ($s -eq 'waiting 0, running 0') "and nothing is left behind at the cloud gate ($s)"
Check ([LocalHarness]::FailureFreesTheQueue($true)) "a request that throws at once frees its place"
Check ([LocalHarness]::FailureFreesTheQueue($false)) "a request that fails later frees its place"

# ---- 4a. the order of the queue ------------------------------------------------
# memoQ asks for the segment the translator lands on and then fetches the rows
# after it by itself (plugin log, 2026-10-13), so the order it asks in is the
# translator's own. Newest-first, the first version, served memoQ's look-ahead
# rows before the segment the translator was waiting on.
$o = [LocalHarness]::QueueOrder('B:i,C:i,D:i')
Check ($o -like 'A,B,C,D |*') "segments go in the order memoQ asked for them ($o)"
$o = [LocalHarness]::QueueOrder('X:b,Y:i,Z:b')
Check ($o -like 'A,Y,X,Z |*') "a segment being looked at goes before Pre-translate, which keeps its order ($o)"
$o = [LocalHarness]::QueueOrder('B:i,C:i,C:i')
Check ($o -eq 'A,C,B | reply B,reply C,reply C') "a segment asked for again moves to the front, is sent once, and both askers get the answer ($o)"
$o = [LocalHarness]::QueueOrder('B:i,C:i,D:i,D:i,C:i')
Check ($o -like 'A,C,D,B |*') "the one asked for again most recently goes first of all ($o)"
$o = [LocalHarness]::QueueOrder('C:s,D:i,C:s')
Check ($o -eq 'A,C,D | reply C,reply D,reply C') "the same segment with a changed prompt is still one request ($o)"
$o = [LocalHarness]::QueueOrder('S:skip,C:i')
Check ($o -eq 'A,C | OvertakenException,reply C') "a segment confirmed while it waited is not sent, and says so ($o)"
$o = [LocalHarness]::QueueCancelled()
Check ($o -eq 'A,C | B: TaskCanceledException') "a request given up while it waits leaves the line ($o)"
$s = [LocalHarness]::QueueState()
Check ($s -eq 'waiting 0, running 0, flights 0') "and nothing is left behind in the queue ($s)"

# ---- 4b. Stop ----------------------------------------------------------------------
# The notice's way out. On 2026-10-13 a Pre-translate batch ran for thirteen
# minutes, memoQ's Cancel waited for it, and only quitting Ollama ended it.
Write-Host "-- Stop"
$o = [LocalHarness]::StopEverything()
Check ($o -like 'A: StoppedException, B: StoppedException, C: StoppedException, D: reply D |*') "Stop cancels the one under way, refuses the one waiting and the next one asked for, then lets the next go ($o)"
Check ($o -like '*| sent A,D |*') "the refused ones never reached the server"
Check ($o -like '*waiting 0, running 0, flights 0*') "and leaves nothing behind in the queue"
Check ($o -like '*stopped in under 3 s') "at once, not when the request would have ended"

# ---- 5. how a failure reaches memoQ -----------------------------------------
Write-Host "-- failures"
$o = [LocalHarness]::Outcome('Ollama', 'timeout')
Check ($o -like 'TimeoutException:*Ollama at http://localhost:1 did not answer within 30 minutes*memory bank*') "core's time limit is a failure, in memoQ's words ($o)"
Check ($o -notlike '*AI settings*') "and offers no timeout setting, which memoQ does not have"
$o = [LocalHarness]::Outcome('Ollama', 'other-limit')
Check ($o -like 'TimeoutException:*did not answer within*') "a cancellation nobody asked for is a time limit too, not a cancellation ($o)"
$o = [LocalHarness]::Outcome('Ollama', 'caller-cancelled')
Check ($o -like '*CanceledException*') "a caller giving up is still a cancellation ($o)"
$o = [LocalHarness]::Outcome('Ollama', 'refused')
Check ($o -like 'InvalidOperationException:*Could not reach Ollama at http://localhost:1*Is it running*') "nothing listening says so ($o)"
$o = [LocalHarness]::Outcome('Ollama', 'broke-off')
Check ($o -like 'InvalidOperationException:*broke off before it answered*kept alive*try the segment again*') "a connection that broke off says so, not 'an error occurred' ($o)"
$o = [LocalHarness]::Outcome('Ollama', 'error')
Check ($o -like 'HttpRequestException:*500*') "a server that answers badly keeps its own message"
$o = [LocalHarness]::Outcome('Anthropic', 'other-limit')
Check ($o -like 'TaskCanceledException*') "a cloud provider's failures pass through untouched ($o)"
$o = [LocalHarness]::Outcome('Anthropic', 'timeout')
Check ($o -like 'TimeoutException: Ollama did not answer within 30 minutes, so the request was abandoned.*') "core's time limit too, in core's words ($o)"

# ---- 6. a prompt the server cut ----------------------------------------------
Write-Host "-- truncation"
# 100,000 characters is about 25,000 tokens at core's four to a token.
$o = [LocalHarness]::Judge(2051, 0, 100000)
Check ($o -like 'ContextTooSmallException:*2,051 of about 25,000*') "2,051 of 25,000 tokens read is refused ($o)"
Check ($o -like '*at least 32,768 tokens*') "and names a context length that would fit"
Check ($o -notlike '*Ollama*') "an OpenAI-compatible server is not sent to Ollama's settings"
Check ([LocalHarness]::Judge(20000, 0, 100000) -eq 'accepted') "20,000 of 25,000 is accepted (tokenisers differ)"
Check ([LocalHarness]::Judge(3000, 10000, 100000) -eq 'accepted') "cached tokens count as read"
Check ([LocalHarness]::Judge(-1, 0, 100000) -eq 'accepted') "no count from the server is no judgement"
Check ([LocalHarness]::Judge(0, 0, 100000) -eq 'accepted') "a count of zero is no count"
Check ([LocalHarness]::Judge(100, 0, 4000) -eq 'accepted') "a prompt below 1,500 tokens is not judged"

# A model whose own window is smaller than the prompt: no setting helps, and
# the message used to send the translator to one (aya-expanse:8b, 2026-10-13).
$o = [LocalHarness]::JudgeFor('Ollama', 4099, 100000, 'aya-expanse:8b', 8192)
Check ($o -like '*aya-expanse:8b can hold at most 8,192 tokens*no setting raises it*memory bank*') "a cut by the model's own limit says so ($o)"
Check ($o -notlike '*Raise the server*') "and does not send the translator to a setting"
# Core sends Ollama a context size that holds the prompt, overriding Ollama's
# own Context length setting (2026-10-17): for Ollama a short read is always
# the model, and that setting no longer does anything.
foreach ($w in 32768, 0) {
    $o = [LocalHarness]::JudgeFor('Ollama', 2051, 100000, 'qwen2.5:7b', $w)
    Check ($o -like '*qwen2.5:7b holds fewer tokens than this prompt*no setting raises it*') "Ollama, window $(if ($w) {$w} else {'unknown'}): the model is named as the limit ($o)"
    Check ($o -notlike '*Raise the server*' -and $o -notlike '*Context length*') "and Ollama's Context length setting is not offered"
}
$o = [LocalHarness]::JudgeFor('OpenAI-compatible', 2051, 100000, 'qwen2.5:7b', 0)
Check ($o -like '*Raise the server*at least 32,768 tokens*LM Studio*') "an OpenAI-compatible server still gets its setting ($o)"
$o = [LocalHarness]::JudgeFor('OpenAI-compatible', 2051, 100000, 'm', 30000)
Check ($o -like '*at least 30,000 tokens*') "and never a size larger than the model holds ($o)"

# Core refuses a short read itself, before the request returns: memoQ's words,
# and the exception a batch does not retry row by row.
$o = [LocalHarness]::CoreRefusal(4099, 100000)
Check ($o -like 'ContextTooSmallException:*4,099 of about 25,000*qwen2.5:7b holds fewer tokens*') "core's refusal reaches memoQ in memoQ's words ($o)"
$o = [LocalHarness]::CoreRefusal(-1, 100000)
Check ($o -eq "ContextTooSmallException: core's own words") "with no count to word it by, core's message, still as the type a batch does not retry ($o)"
$s = [LocalHarness]::QueueState()
Check ($s -eq 'waiting 0, running 0, flights 0') "and the refusal leaves nothing behind in the queue ($s)"

# Before sending: a prompt that cannot fit is refused at once, not after the
# five minutes it took Ollama to read the part it kept.
$o = [LocalHarness]::BeforeSending(100000, 'aya-expanse:8b', 8192)
Check ($o -like 'ContextTooSmallException:*Not sent: aya-expanse:8b can hold at most 8,192 tokens*about 25,000*') "a 25,000-token prompt is not sent to an 8,192-token model ($o)"
Check ([LocalHarness]::BeforeSending(40000, 'm', 8192) -eq 'sent') "10,000 tokens to 8,192 goes: the estimate is too rough to refuse on"
Check ([LocalHarness]::BeforeSending(100000, 'm', 0) -eq 'sent') "no window known, no judgement"
Check ([LocalHarness]::BeforeSending(4000, 'm', 512) -eq 'sent') "a prompt below 1,500 tokens is not judged"

$windowIn = $plugin.GetType('Supervertaler.MemoQ.Core.LocalServer').GetMethod('WindowIn', $Static)
$show = '{"license":"x","parameters":"num_ctx 4096","details":{"family":"command-r"},"model_info":{"general.architecture":"command-r","command-r.context_length":8192,"command-r.embedding_length":4096},"capabilities":["completion"]}'
Check ($windowIn.Invoke($null, @($show)) -eq 8192) "the window is read from Ollama's description of the model"
Check ($null -eq $windowIn.Invoke($null, @('{"details":{}}'))) "and a description without it gives none"
Check ($null -eq $windowIn.Invoke($null, @('{"error":"model not found"}'))) "nor does an error"

# ---- 7. Ollama's cloud ---------------------------------------------------------
# Allowed, and said. The name is what a dialog has; a request asks Ollama's model
# list, which marks a cloud model with remote_host whatever it is called. The list
# below is Ollama 0.40.3's own answer for a cloud model pulled on 2026-10-13.
Write-Host "-- Ollama's cloud"
foreach ($c in @(
        @('Ollama', 'gpt-oss:20b-cloud', $true), @('Ollama', 'qwen3-coder:cloud', $true),
        @('Ollama', 'qwen2.5:7b', $false), @('Ollama', 'cloudy:7b', $false),
        @('Anthropic', 'gpt-oss:20b-cloud', $false), @('OpenAI-compatible', 'x-cloud', $false))) {
    $got = P 'IsOllamaCloudModel' @($c[0], $c[1])
    Check ($got -eq $c[2]) "$($c[0]) '$($c[1])' is $(if ($c[2]) {''} else {'not '})a cloud model"
}

# Which Parallel requests value and which notice a model gets (2026-10-22). Until
# then every Ollama model counted as local: a cloud model went one batch at a time
# under "the model reads the instructions once" (seen 2026-10-14, gemma4:31b-cloud).
foreach ($c in @(
        @('Ollama', 'qwen2.5:7b', $true), @('OpenAI-compatible', 'anything', $true),
        @('Ollama', 'gemma4:31b-cloud', $false), @('Ollama', 'qwen3-coder:cloud', $false),
        @('Anthropic', 'claude-opus-5-5', $false), @('Ollama', '', $true))) {
    $got = P 'RunsLocally' @($c[0], $c[1])
    Check ($got -eq $c[2]) "$($c[0]) '$($c[1])' $(if ($c[2]) {'runs locally'} else {'does not run locally'})"
}

# And the engine uses it: an Ollama cloud model gets the cloud's value. The shared
# file decides (run-harness.ps1 snapshots and restores it).
$sharedT = $plugin.GetType('Supervertaler.MemoQ.Core.SharedSettings')
$SharedProp = [Reflection.BindingFlags]'NonPublic,Public,Static'
function Shared($name, $value) { $sharedT.GetProperty($name, $SharedProp).SetValue($null, $value) }
$genT = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerGeneralSettings')
$secT = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSecureSettings')
$setT = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerSettings')
$ctxSettings = $setT.GetMethod('Create').Invoke($null, @([Activator]::CreateInstance($genT), [Activator]::CreateInstance($secT)))
$ctx = [Activator]::CreateInstance($plugin.GetType('Supervertaler.MemoQ.Core.EngineContext'),
    [Reflection.BindingFlags]'Instance,Public,NonPublic', $null, @($ctxSettings, 'eng', 'nld'), $null)
function ParallelFor($provider, $model) {
    Shared 'Provider' $provider; Shared 'Model' $model
    $ctx.GetType().GetProperty('General').GetValue($ctx).MaxParallelRequests
}
Shared 'Parallel' 3; Shared 'LocalParallel' 1
Check ((ParallelFor 'Ollama' 'gemma4:31b-cloud') -eq 3) "the engine gives an Ollama cloud model the cloud's Parallel requests (3)"
Check ((ParallelFor 'Ollama' 'qwen2.5:7b') -eq 1) "and a model on this computer the local value (1)"
Check ((ParallelFor 'Anthropic' 'claude-opus-5-5') -eq 3) "and a cloud provider the cloud's, as before (3)"

$localServer = $plugin.GetType('Supervertaler.MemoQ.Core.LocalServer')
$tags ='{"models":[{"name":"gpt-oss:20b-cloud","model":"gpt-oss:20b-cloud","remote_model":"gpt-oss:20b","remote_host":"https://ollama.com","size":306},' +
        '{"name":"my-renamed-model:latest","model":"my-renamed-model:latest","remote_host":"https://ollama.com"},' +
        '{"name":"qwen2.5:7b","model":"qwen2.5:7b","size":4683087332}]}'
function RemoteHost($model) {
    $argv = [object[]]@($tags, $model, $false)
    $h = $localServer.GetMethod('RemoteHostIn', $Static).Invoke($null, $argv)
    return @($h, $argv[2])
}
$r = RemoteHost 'gpt-oss:20b-cloud'
Check ($r[0] -eq 'https://ollama.com' -and $r[1]) "Ollama's list marks gpt-oss:20b-cloud as running on $($r[0])"
$r = RemoteHost 'my-renamed-model'
Check ($r[0] -eq 'https://ollama.com' -and $r[1]) "a cloud model under any name is caught by the list ('my-renamed-model' finds ':latest')"
$r = RemoteHost 'qwen2.5:7b'
Check ($null -eq $r[0] -and $r[1]) "a local model is listed with no remote host"
$r = RemoteHost 'not-installed:1b'
Check (-not $r[1]) "a model the list lacks is reported as not listed, so the name decides"

$generalT0 = $plugin.GetType('Supervertaler.MemoQ.Settings.SupervertalerGeneralSettings')
function Label($provider, $model, $endpoint) {
    $g = [Activator]::CreateInstance($generalT0)
    $generalT0.GetProperty('Provider').SetValue($g, $provider)
    $generalT0.GetProperty('Model').SetValue($g, $model)
    $generalT0.GetProperty('Endpoint').SetValue($g, $endpoint)
    return $localServer.GetMethod('ProviderLabelAsync', $Static).Invoke($null, @($g)).Result
}
Check ((Label 'Anthropic' 'claude-sonnet-5-5' '') -eq 'Anthropic') "a cloud provider is labelled with its name, no request made"
Check ((Label 'Ollama' 'gpt-oss:20b-cloud' 'http://localhost:1') -eq 'Ollama cloud') "with Ollama unreachable, a cloud name is still labelled 'Ollama cloud'"
Check ((Label 'Ollama' 'qwen2.5:7b' 'http://localhost:1') -eq 'Ollama') "and a local name 'Ollama'"

# ---- 8. the waiting notice -----------------------------------------------------
# What it reads out of Ollama's log, and what it says. The lines are Ollama
# 0.40.3's, from the first Ollama segment ever translated in memoQ (2026-10-13).
Write-Host "-- the waiting notice"
$progress = $plugin.GetType('Supervertaler.MemoQ.Core.LocalProgress')
$parse = $progress.GetMethod('Parse', $Static)
$describe = $progress.GetMethod('Describe', $Static)
$log = @(
    'slot   operator(): id  0 | task 0 | new prompt, n_ctx_slot = 32768, n_keep = 4, task.n_tokens = 44',
    'slot print_timing: id  0 | task 0 | prompt eval time =    1754.45 ms /    44 tokens (   39.87 ms per token,    25.08 tokens per second)',
    'slot   operator(): id  0 | task 9 | new prompt, n_ctx_slot = 32768, n_keep = 4, task.n_tokens = 13903',
    'slot   operator(): id  0 | task 9 | cached n_tokens = 3, memory_seq_rm [3, end)',
    'slot print_timing: id  0 | task 9 | prompt processing, n_tokens =   9216, progress = 0.66, t = 454.64 s / 20.27 tokens per second',
    'slot print_timing: id  0 | task 9 | prompt processing, n_tokens =  10240, progress = 0.74, t = 527.22 s / 19.42 tokens per second'
) -join "`n"
$reading = $parse.Invoke($null, @($log))
Check ($reading.Total -eq 13903 -and $reading.Done -eq 10240 -and [math]::Abs($reading.Rate - 19.42) -lt 0.01 -and -not $reading.Writing) `
    "the log reads as 10,240 of 13,903 tokens at 19.42 a second"
$text = $describe.Invoke($null, @('Ollama', 'qwen2.5:7b', [TimeSpan]::FromSeconds(527), 1, $reading, $null, $null))
Check ($text -like '*waiting for Ollama (qwen2.5:7b)*8:47*' -and $text -like '*Reading the instructions: 73% done (10,240 of 13,903 tokens)*about 4 minutes left*') "and the notice says so: $(($text -split "`n")[0..1] -join ' / ')"
Check ($text -like "*The first translation is the slow one*") "and why, in a translator's words"
Check ($text -notmatch '\brequest') "with no 'request' in it"
$cloudText = $describe.Invoke($null, @('Ollama', 'gemma4:31b-cloud', [TimeSpan]::FromSeconds(40), 1, $null, $null, $null))
Check ($cloudText -like '*waiting for Ollama (gemma4:31b-cloud)*' -and $cloudText -notlike '*The first translation is the slow one*') `
    "a model on Ollama's servers is not said to be reading the instructions on this computer"
$localText = $describe.Invoke($null, @('Ollama', 'qwen2.5:7b', [TimeSpan]::FromSeconds(40), 1, $null, $null, $null))
Check ($localText -like '*The first translation is the slow one*') "a local model with no log to go on still is"

$done = $parse.Invoke($null, @($log + "`nslot print_timing: id  0 | task 9 | prompt eval time =  799400.48 ms / 13900 tokens (   57.51 ms per token,    17.39 tokens per second)"))
Check ($done.Writing) "a finished prompt is read as writing the answer"
$writing = $describe.Invoke($null, @('Ollama', 'm', [TimeSpan]::FromSeconds(800), 3, $done, $null, $null))
Check ($writing -like '*Instructions read (13,903 tokens); now writing the translation.*2 more translations are waiting their turn.*') "which the notice says, with the queue behind it"
Check ($writing -notlike '*slow one*') "and no longer explains a slowness that is over"
Check ($describe.Invoke($null, @('Ollama', 'm', [TimeSpan]::FromSeconds(30), 2, $reading, $null, $null)) -like '*1 more translation is waiting its turn.*') "one waiting reads as one"

# The second request of a job: most of the prompt is in Ollama's cache already.
$warm = $parse.Invoke($null, @((@(
    'slot   operator(): id  0 | task 15 | new prompt, n_ctx_slot = 32768, n_keep = 4, task.n_tokens = 13933',
    'slot   operator(): id  0 | task 15 | cached n_tokens = 13312, memory_seq_rm [13312, end)'
) -join "`n")))
Check ($warm.Done -eq 13312 -and $warm.Total -eq 13933) "tokens Ollama had cached count as read (13,312 of 13,933)"
Check ($describe.Invoke($null, @('Ollama', 'm', [TimeSpan]::FromSeconds(9), 1, $warm, $null, $null)) -like '*Instructions read (13,933 tokens); now writing the translation.*') "so a warm request goes straight to writing, not 0%"

# The segment the model is on, with its own clock; and an answer that came
# after memoQ had probably stopped waiting for it.
$label = $progress.GetMethod('SegmentLabel', $Static).Invoke($null, @("[0002] Conventional bicycle lamps are  switched on and off by hand."))
Check ($label -like '?`[0002] Conventional bicycle lamps are??' -and $label.Length -le 44) "a segment is quoted by its first words, cut between words ($label)"
Check ($progress.GetMethod('SegmentLabel', $Static).Invoke($null, @('Claims')) -like '?Claims?') "a short one whole"
Check ($null -eq $progress.GetMethod('SegmentLabel', $Static).Invoke($null, @('  '))) "an empty one not at all"
Check ($progress.GetMethod('BatchLabel', $Static).Invoke($null, @(10)) -eq '10 segments for Pre-translate') "a batch by its size"

$on = $describe.Invoke($null, @('Ollama', 'm', [TimeSpan]::FromSeconds(84), 2, $reading, $label, $null))
$lines = $on -split "`r?`n"
Check ($lines[0] -eq 'Supervertaler is waiting for Ollama (m)') "the first line names the server, with no clock ($($lines[0]))"
Check ($lines[1] -like 'Translating ?`[0002] Conventional*? * 1:24') "the second names the segment, with its own clock ($($lines[1]))"
Check ($on -like '*1 more translation is waiting its turn.*') "and the queue behind it"

$ready = $describe.Invoke($null, @('Ollama', 'm', [TimeSpan]::Zero, 0, $null, $null, $label))
Check ($ready -like "Supervertaler: translation ready for ?``[0002] Conventional*?.*click another segment and then back.") "an answer memoQ stopped waiting for: ready, and how to see it ($ready)"
$both = $describe.Invoke($null, @('Ollama', 'm', [TimeSpan]::FromSeconds(5), 1, $null, '"next"', $label))
Check ($both -like '*Ready: ?`[0002]*click another segment and then back.*Translating "next"*') "said above the segment that is on now"
Check ($describe.Invoke($null, @('Ollama', 'm', [TimeSpan]::Zero, 0, $null, $null, $null)) -eq '') "nothing waiting and nothing ready says nothing"

# When "ready" is said: someone was looking, and memoQ asked long enough ago.
$readyField = $progress.GetField('_ready', [Reflection.BindingFlags]'NonPublic,Static')
$working = $progress.GetMethod('Working', $Static)
function ReadyAfter($minutes, $interactive) {
    $readyField.SetValue($null, $null)
    $w = $working.Invoke($null, @('"seg"'))
    [void]$w.GetType().GetMethod('Answered').Invoke($w, @($interactive, [DateTime]::UtcNow.AddMinutes(-$minutes)))
    ([IDisposable]$w).Dispose()
    $r = $readyField.GetValue($null)
    $readyField.SetValue($null, $null)
    return $r
}
Check ((ReadyAfter 4 $true) -eq '"seg"') "an answer four minutes after memoQ asked is announced"
Check ($null -eq (ReadyAfter 1 $true)) "one after a minute is not: memoQ shows it itself"
Check ($null -eq (ReadyAfter 10 $false)) "nor is a Pre-translate batch"

$quiet = $describe.Invoke($null, @('OpenAI-compatible', 'local-model', [TimeSpan]::FromSeconds(75), 1, $null, $null, $null))
Check ($quiet -like '*waiting for OpenAI-compatible (local-model)*1:15*' -and $quiet -notlike '*Reading the instructions*') "with no log to read, it says how long, and no more"
Check ($quiet -like '*the model reads the instructions once*') "and names no server it cannot see"
Check ($null -eq $parse.Invoke($null, @('[GIN] 2026/10/13 - 10:47:52 | 200 | 13m22s | POST "/api/chat"'))) "a log it cannot read gives no progress rather than a wrong one"

# Always on top, by its own window style. WinForms' TopMost is applied on
# activation and this window is never activated, so it came up as an ordinary
# window: the first click into memoQ's grid covered it, and in memoQ on
# 2026-10-13 it was visible to Windows and to nobody for ten minutes.
$noticeT = $progress.GetNestedType('NoticeForm', [Reflection.BindingFlags]'NonPublic')
$notice = [Activator]::CreateInstance($noticeT, [Reflection.BindingFlags]'Instance,Public,NonPublic', $null, @([object]::new()), $null)
try {
    $links = @($notice.Controls | Where-Object { $_ -is [Windows.Forms.LinkLabel] })
    $stopText = $progress.GetField('StopText', $Static).GetValue($null)
    Check ($links.Count -eq 1 -and $links[0].Text -eq $stopText) "the notice has a Stop link ('$stopText')"
    $ex = [LocalHarness]::ExStyle($notice.Handle)
    Check (($ex -band 0x8) -ne 0) "the notice window is always on top (style 0x$('{0:X}' -f $ex))"
    Check (($ex -band 0x08000000) -ne 0) "and never takes the keyboard from memoQ"
}
finally { $notice.Dispose() }

# ---- 9. the language beside the segment -----------------------------------------
# A 7B model given a 14,000-token prompt returned "Summary of the invention" in
# English (2026-10-13): the pair was stated once, 13,000 tokens back. It is now
# restated beside the segment, in the single request and the batch alike.
Write-Host "-- the language beside the segment"
$mtAsm = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.MTInterfaces.dll")
$commonAsm = [Reflection.Assembly]::LoadFrom("$MemoQPath\MemoQ.Addins.Common.dll")
$bundleT = $mtAsm.GetType('MemoQ.MTInterfaces.TranslationBundle')
$bundle = [Activator]::CreateInstance($bundleT)
$seg = $commonAsm.GetType('MemoQ.Addins.Common.DataStructures.SegmentBuilder').GetMethod('CreateFromString').Invoke($null, @('Summary of the invention'))
$bundleT.GetMember('Source')[0].SetValue($bundle, $seg)
$builder = $plugin.GetType('Supervertaler.MemoQ.Core.PromptBuilder')
$structureOff = [Enum]::ToObject($plugin.GetType('Supervertaler.Core.StructureContextMode'), 0)
$gs = [Activator]::CreateInstance($generalT0)
$single = $builder.GetMethod('Build').Invoke($null, @($bundle, $gs, 'eng', 'nld', $null, $null, $null, 'Translate well.', $null, $structureOff, $null))
Check ($single.User -match "Translate from English into Dutch\.\r?\n\r?\nSource segment:\r?\nSummary of the invention") "the single request restates the pair beside the segment"
$batch = $builder.GetMethod('BuildForBatch').Invoke($null, @($gs, 'eng', 'nld', $null, $null, $null, 'Translate well.', $null, $structureOff))
Check ($batch.User.TrimEnd().EndsWith('Translate from English into Dutch.')) "and a batch ends its context with it, just before its numbered segments"

# An empty translator comment is deleted; a real one stays in the target, where
# memoQ keeps them for review. Segment 10 of the first Ollama test ended in "[[TC:]]".
$noEmpty = $plugin.GetType('Supervertaler.MemoQ.Core.BatchTranslator').GetMethod('WithoutEmptyComment', $Static)
function Clean($s) { $noEmpty.Invoke($null, @($s)) }
Check ((Clean 'aan de sensor (4) en aan de lichtbron (3).[[TC:]]') -eq 'aan de sensor (4) en aan de lichtbron (3).') "an empty [[TC:]] at the end is removed"
Check ((Clean "aan de lichtbron (3). [[TC:  ]]") -eq 'aan de lichtbron (3).') "and one holding only spaces"
Check ((Clean 'De lamp (1). [[TC: "lamp" or "lampje"? Please check.]]') -eq 'De lamp (1). [[TC: "lamp" or "lampje"? Please check.]]') "a comment with text is kept"
Check ((Clean 'De lamp (1).') -eq 'De lamp (1).') "a reply without one is untouched"

# ---- 10. a refused batch does not hold the queue -----------------------------
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

# ---- 11. both settings dialogs -----------------------------------------------
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
    @{ Name = "memoQ's dialog"; Make = { [Activator]::CreateInstance($plugin.GetType('Supervertaler.MemoQ.Settings.OptionsForm'), $Ctor, $null, @($settings), $null) }; Parallel = '_maxParallel'; Hint = '_endpointHint'; Note = '_modelNote' }
    @{ Name = "the editor's dialog"; Make = { [Activator]::CreateInstance($editor.GetType('Supervertaler.PromptEditor.SettingsForm'), $Ctor, $null, @(), $null) }; Parallel = '_parallel'; Hint = '_endpointHint'; Note = '_modelStatus' }
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
        $note = Field $form $d.Note
        $startLocal = Field $form '_localParallel'

        Check (@($provider.Items) -contains 'Ollama' -and @($provider.Items) -contains 'OpenAI-compatible') "$($d.Name) offers Ollama and OpenAI-compatible"

        $provider.SelectedItem = 'Anthropic'
        $parallel.Value = 5
        Check (-not $endpoint.Enabled) "$($d.Name): Anthropic greys out the endpoint"
        Check ($key.Enabled) "$($d.Name): Anthropic keeps the key box"

        $provider.SelectedItem = 'Ollama'
        Check ($endpoint.Enabled) "$($d.Name): Ollama opens the endpoint"
        Check (-not $key.Enabled -and $key.Text -eq '') "$($d.Name): Ollama shuts the key box"
        Check ($parallel.Value -eq $startLocal) "$($d.Name): Ollama shows the local servers' own Parallel requests ($($parallel.Value)), not Anthropic's 5"
        $parallel.Value = 2
        Check ($hint.Text -like '*localhost:11434*') "$($d.Name): the hint says where Ollama is looked for"
        Check (@($model.Items | ForEach-Object { $_.Id }) -contains 'translategemma:12b') "$($d.Name): Ollama suggests models to download"

        # A model from Fetch list, which Ollama names by id only, chosen and
        # read back as the dialog would send it. 0.1.12 sent "(qwen2.5:7b)".
        $cachePath = $catalog.GetMethod('CacheFile', $Static).Invoke($null, @('Ollama'))
        [IO.File]::WriteAllLines($cachePath, @('qwen2.5:7b', 'mixtral:8x7b', 'gpt-oss:20b-cloud'), (New-Object Text.UTF8Encoding($false)))
        # Off, then on: a box that opened ticked - the user's saved choice - does
        # not reload the list when ticked again.
        (Field $form '_showAllModels').Checked = $false
        (Field $form '_showAllModels').Checked = $true
        $fetched = @($model.Items | Where-Object { $_.Id -eq 'qwen2.5:7b' })
        Check ($fetched.Count -eq 1 -and $fetched[0].ToString() -eq 'qwen2.5:7b') "$($d.Name): a fetched model is shown as its id ('$($fetched[0])')"
        $model.SelectedItem = $fetched[0]
        $chosen = $form.GetType().GetMethod('ChosenModelId', $Instance).Invoke($form, @())
        Check ($chosen -eq 'qwen2.5:7b') "$($d.Name): and choosing it sends '$chosen'"
        Check ($parallel.Value -eq 2) "$($d.Name): a model on this computer keeps the local Parallel requests ($($parallel.Value))"

        # Ollama's cloud: allowed, and said - in the list, and under the box.
        $cloudItem = @($model.Items | Where-Object { $_.Id -eq 'gpt-oss:20b-cloud' })
        Check ($cloudItem.Count -eq 1 -and $cloudItem[0].ToString() -like "*Ollama's servers*") "$($d.Name): a fetched cloud model says so in the list ('$($cloudItem[0])')"
        $model.SelectedItem = $cloudItem[0]
        Check ($note.Text -like "Cloud model:*" -and $note.ForeColor -eq [Drawing.Color]::Firebrick) "$($d.Name): choosing it puts the warning under the box"
        $chosen = $form.GetType().GetMethod('ChosenModelId', $Instance).Invoke($form, @())
        Check ($chosen -eq 'gpt-oss:20b-cloud') "$($d.Name): and it can still be chosen ('$chosen')"
        Check ($parallel.Value -eq 5) "$($d.Name): a cloud model shows the cloud's Parallel requests ($($parallel.Value)), not the local 2"
        $parallel.Value = 7
        $model.Text = 'qwen3-coder:cloud'
        Check ($note.Text -like "Cloud model:*") "$($d.Name): a typed ':cloud' model is warned about too"
        Check ($parallel.Value -eq 7) "$($d.Name): another cloud model keeps the value just set ($($parallel.Value))"
        $model.Text = 'qwen2.5:7b'
        Check ($note.Text -notlike "Cloud model:*") "$($d.Name): a local model takes the warning away ('$($note.Text)')"
        Check ($parallel.Value -eq 2 -and (Field $form '_cloudParallel') -eq 7) `
            "$($d.Name): back on a local model, the local value ($($parallel.Value)), with the cloud's 7 parked"
        $model.Text = 'gpt-oss:20b-cloud'
        Check ($parallel.Value -eq 7) "$($d.Name): and the cloud model brings the 7 back ($($parallel.Value))"
        $parallel.Value = 5
        $model.Text = 'qwen2.5:7b'
        $w = [Windows.Forms.TextRenderer]::MeasureText('Cloud model: your text goes to Ollama''s servers, not this computer.', $note.Font).Width
        Check ($w -le $note.Width) "$($d.Name): the warning fits ($w of $($note.Width) px)"
        (Field $form '_showAllModels').Checked = $false

        $provider.SelectedItem = 'OpenAI-compatible'
        Check ($endpoint.Enabled -and $key.Enabled) "$($d.Name): OpenAI-compatible opens the endpoint and the key box"
        Check ($model.Items.Count -eq 0) "$($d.Name): OpenAI-compatible offers no other provider's models ($($model.Items.Count) listed)"
        Check ($model.Text -eq '') "$($d.Name): and keeps none in the box"

        Check ($parallel.Value -eq 2) "$($d.Name): OpenAI-compatible shares the local servers' value"

        $provider.SelectedItem = 'Google'
        Check ($parallel.Value -eq 5) "$($d.Name): back on a cloud provider, the cloud value is back ($($parallel.Value))"
        $provider.SelectedItem = 'Ollama'
        Check ($parallel.Value -eq 2) "$($d.Name): and the local one is kept for the next switch"
        Check ((Field $form '_cloudParallel') -eq 5) "$($d.Name): with the cloud value parked meanwhile"

        # Rewritten after the layout is fixed, so each must fit on its row.
        foreach ($p in 'Anthropic', 'Ollama', 'OpenAI-compatible') {
            $provider.SelectedItem = $p
            $w = [Windows.Forms.TextRenderer]::MeasureText($hint.Text, $hint.Font).Width
            Check ($w -le $hint.Width) "$($d.Name): the $p hint fits ($w of $($hint.Width) px)"
        }
    }
    finally { $form.Dispose() }
}

# ---- 11a. memoQ's font ---------------------------------------------------------
# memoQ gives the plugin's dialog its own font from the start: Segoe UI 9.75,
# measured from a screenshot on 2026-10-14 in which "Segments per request" showed
# as "Segments per" - 137 px of text in a 130 px caption. WinForms reads
# Control.DefaultFont when a control is made, so it is set the same way here, and
# last, because it applies to every form made after it.
Write-Host "-- memoQ's font"
$defaultFont = [Windows.Forms.Control].GetField('defaultFont', $Static)
$fontBefore = $defaultFont.GetValue($null)
$defaultFont.SetValue($null, (New-Object Drawing.Font('Segoe UI', [single]9.75)))
try {
    $forms = @(
        @{ Name = "memoQ's dialog"; Form = [Activator]::CreateInstance($plugin.GetType('Supervertaler.MemoQ.Settings.OptionsForm'), $Ctor, $null, @($settings), $null) }
        @{ Name = "the editor's dialog"; Form = [Activator]::CreateInstance($editor.GetType('Supervertaler.PromptEditor.SettingsForm'), $Ctor, $null, @(), $null) }
    )
    foreach ($d in $forms) {
        $form = $d.Form
        try {
            $captions = @($form.Controls | Where-Object { $_ -is [Windows.Forms.Label] -and -not $_.AutoSize -and -not $_.AutoEllipsis -and $_.Left -lt 40 -and $_.Text })
            $cut = @($captions | Where-Object { $_.PreferredSize.Width -gt $_.Width } | ForEach-Object { "'$($_.Text)' needs $($_.PreferredSize.Width) of $($_.Width) px" })
            Check ($captions.Count -ge 6 -and $cut.Count -eq 0) "$($d.Name), in $($form.Font.Name) $($form.Font.SizeInPoints): all $($captions.Count) captions fit on one line$(if ($cut) { ' - ' + ($cut -join '; ') })"

            # The note beside Parallel requests: says what is kept apart and
            # what to choose, wraps, and is not covered by the row below.
            $note = @($form.Controls | Where-Object { $_ -is [Windows.Forms.Label] -and $_.Text -like 'Saved separately for cloud providers*' })
            Check ($note.Count -eq 1) "$($d.Name): the Parallel requests note says what is saved separately"
            if ($note.Count -eq 1) {
                $n = $note[0]
                $batch = Field $form '_batchSize'
                $need = $n.GetPreferredSize((New-Object Drawing.Size($n.Width, 0))).Height
                Check ($n.Text -like '*4 suits a cloud provider*' -and $n.Text -like '*1 suits a model on your own computer*') "$($d.Name): and what to choose"
                Check ($n.Height -ge $need -and $n.Right -le $form.ClientSize.Width) "$($d.Name): the note is shown whole ($($n.Width)x$($n.Height) px, $need needed)"
                Check ($n.Bottom -le $batch.Top) "$($d.Name): and the row below starts under it ($($n.Bottom) / $($batch.Top))"
            }
        }
        finally { $form.Dispose() }
    }
}
finally { $defaultFont.SetValue($null, $fontBefore) }

# ---- 12. a real Ollama, when there is one ------------------------------------
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
    # Core asks Ollama to keep a model loaded for four hours. Unloaded again at
    # the end - whatever happens - unless it was loaded before the run, when it
    # is someone's and stays.
    $loadedBefore = $false
    try { $loadedBefore = [bool]((Invoke-RestMethod -Uri 'http://localhost:11434/api/ps' -TimeoutSec 3).models | Where-Object { $_.name -eq $model }) } catch { $loadedBefore = $true }
    try {
        $fetch = $catalog.GetMethod('FetchAsync', $Static)
        $listed = $fetch.Invoke($null, @('Ollama', '', 'http://localhost:11434/v1', [Threading.CancellationToken]::None)).Result
        Check (@($listed | Where-Object { $_.Id -eq $model }).Count -eq 1) "Fetch list, keyless and through a /v1 address, finds $model ($(@($listed).Count) installed)"

        $o = [LocalHarness]::Live('', $model, 'Translate from English into Dutch. Reply with the translation only.', 'The ring is fastened.')
        Check ($o -like 'reply: *') "a short prompt is translated ($o)"

        $o = [LocalHarness]::Live('http://localhost:11999', $model, 'x', 'y')
        Check ($o -like '*Could not reach Ollama at http://localhost:11999*') "a wrong port says nothing is listening ($o)"

        # The measured case: an instruction at the top of a prompt longer than
        # Ollama's own default of 4,096 tokens, which used to cut it. Core sends
        # a context size that holds it (2026-10-17), so it is read whole and
        # answered. About 6,000 tokens: enough to be cut at 4,096, and a few
        # minutes' reading on a computer without a graphics card.
        $claim = 'Claim {0}: the fastening element according to claim {1}, wherein the retaining ring engages the groove at a depth of {0}.{1} millimetres. '
        $filler = -join (1..180 | ForEach-Object { $claim -f $_, ($_ % 7 + 1) })
        $system = "Translate from English into Dutch. Reply with the translation only.`n`n$filler"
        $started = Get-Date
        $o = [LocalHarness]::Live('', $model, $system, 'The ring is fastened.')
        $secs = [int]((Get-Date) - $started).TotalSeconds
        Check ($o -like 'reply: *') "a prompt longer than Ollama's default window is read whole and answered (${secs}s): $o"
    }
    finally {
        if (-not $loadedBefore) {
            try {
                Invoke-RestMethod -Uri 'http://localhost:11434/api/generate' -Method Post -TimeoutSec 30 -ContentType 'application/json' `
                    -Body (@{ model = $model; keep_alive = 0 } | ConvertTo-Json) | Out-Null
                Write-Host "INFO $model unloaded again"
            }
            catch { Write-Host "INFO $model could not be unloaded ($($_.Exception.Message)); Ollama frees it after four hours" }
        }
    }
}

# The model's own window, asked of Ollama itself. Refused before anything is
# sent, so no model is loaded and it takes no time.
if ($null -ne $tags -and ($tags.models | Where-Object { $_.name -eq 'aya-expanse:8b' })) {
    $claim = 'Claim {0}: the fastening element according to claim {1}, wherein the retaining ring engages the groove at a depth of {0}.{1} millimetres. '
    $filler = -join (1..700 | ForEach-Object { $claim -f $_, ($_ % 7 + 1) })
    $started = Get-Date
    $o = [LocalHarness]::Live('', 'aya-expanse:8b', "Translate from English into Dutch.`n`n$filler", 'The ring is fastened.')
    $secs = [math]::Round(((Get-Date) - $started).TotalSeconds, 1)
    Check ($o -like 'ContextTooSmallException:*Not sent: aya-expanse:8b can hold at most 8,192 tokens*') "aya-expanse:8b is asked its window and refuses a 25,000-token prompt (${secs}s): $o"
    Check ($secs -lt 5) "at once, not after reading it"
}
else {
    Write-Host "SKIP aya-expanse:8b is not installed; the model-window check runs against it"
}

Write-Host
if ($fails -gt 0) { Write-Host "$fails check(s) FAILED"; exit 1 }
Write-Host "All checks passed."
