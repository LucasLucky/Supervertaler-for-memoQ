using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Runtime.Serialization;
using System.Runtime.Serialization.Json;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using Supervertaler.Core;
using Supervertaler.MemoQ.Settings;

namespace Supervertaler.MemoQ.Core
{
    /// <summary>
    /// What a model on the translator's own server needs that a cloud provider
    /// does not: requests queued here rather than at the server, and a check that
    /// the server read the whole prompt.
    ///
    /// <para>Applies to Ollama and OpenAI-compatible only; a cloud provider's
    /// request only waits for a place at <see cref="CloudGate"/>. Every call to a
    /// model made inside memoQ's process goes through <see cref="AskAsync"/>, so
    /// a provider added later cannot skip either half by accident.</para>
    /// </summary>
    internal static class LocalServer
    {
        /// <summary>
        /// Sends one request, waiting first for a free place - in the queue when
        /// the server is the translator's own - and refuses an answer made from
        /// part of the prompt.
        ///
        /// <para>The queue is here and not at the server because the timeout
        /// starts when the request is sent. memoQ calls the plugin from several
        /// threads at once and Ollama works on one request at a time unless told
        /// otherwise, so the fourth request of a Pre-translate used to spend three
        /// requests' worth of its own time limit waiting in Ollama's queue.</para>
        ///
        /// <para>How many go at once is the Parallel requests setting - the cloud
        /// value or the local one - read for every request, so a change in the
        /// settings applies to the next one. memoQ itself reads that setting only
        /// when the MT settings resource is created, which makes this the only
        /// place a change to it does anything for an existing resource.</para>
        /// </summary>
        /// <param name="client">The client <paramref name="request"/> uses; its usage is read afterwards.</param>
        /// <param name="request">
        /// The call itself, given the token to send it with: the caller's own,
        /// joined for a local server by the one <see cref="Stop"/> cancels.
        /// </param>
        /// <param name="user">The user prompt sent, for judging how much of it was read.</param>
        /// <param name="system">The system prompt sent, likewise.</param>
        /// <param name="turn">
        /// What the request is for, which decides its place in the queue (see
        /// <see cref="LocalQueue"/>). Null: someone is looking at the answer.
        /// </param>
        public static async Task<string> AskAsync(
            SupervertalerGeneralSettings general,
            LlmClient client,
            Func<CancellationToken, Task<string>> request,
            string user,
            string system,
            CancellationToken cancellationToken,
            LocalQueue.Turn turn = null)
        {
            if (!LlmProviders.TakesEndpoint(general.Provider))
                return await CloudGate.RunAsync(general.MaxParallelRequests, turn?.Interactive ?? true, request, cancellationToken)
                    .ConfigureAwait(false);

            // Just stopped: memoQ is still sending what it had lined up.
            RefuseIfStopped();

            // The same segment already waiting or under way: its answer, not a
            // second model call. memoQ asks again for a segment it is waiting on.
            var identity = LocalQueue.Identity(general, user, system, turn);
            var flight = LocalQueue.JoinOrOpen(identity, out var joined);
            if (flight == null) return await joined.ConfigureAwait(false);

            try
            {
                // From the moment it starts waiting, queue included: the
                // translator is waiting from then too. Disposed however the
                // request ends.
                string reply;
                var asked = DateTime.UtcNow;
                using (LocalProgress.Begin(general))
                {
                    reply = await AskQueuedAsync(general, client, request, user, system, cancellationToken, turn, flight, asked)
                        .ConfigureAwait(false);
                }

                flight.Answer.TrySetResult(reply);
                return reply;
            }
            catch (OperationCanceledException)
            {
                flight.Answer.TrySetCanceled();
                throw;
            }
            catch (Exception ex)
            {
                flight.Answer.TrySetException(ex);
                throw;
            }
            finally
            {
                LocalQueue.Close(identity, flight);
            }
        }

        private static async Task<string> AskQueuedAsync(
            SupervertalerGeneralSettings general,
            LlmClient client,
            Func<CancellationToken, Task<string>> request,
            string user,
            string system,
            CancellationToken cancellationToken,
            LocalQueue.Turn turn,
            LocalQueue.Flight flight,
            DateTime asked)
        {
            var parallel = general.MaxParallelRequests;
            await LocalQueue.EnterAsync(parallel, turn, flight, cancellationToken).ConfigureAwait(false);
            try
            {
                // Asked when the turn comes, not when the request was made: the
                // translator may have confirmed the segment while it waited.
                if (turn?.Overtaken != null && turn.Overtaken())
                {
                    PluginLog.Write("queue: a segment confirmed while it waited is not sent");
                    throw new LocalQueue.OvertakenException();
                }

                // Asked when the turn comes too, never before the request joins
                // the line: a lookup there would let a request memoQ made later
                // overtake one still waiting for its answer.
                var window = await ModelWindowAsync(general).ConfigureAwait(false);
                RefuseIfTooLarge(general.Model, window, user, system);

                // Taken last, as the request goes: Stop cancels what is under way
                // at that moment, and a request taking its place just after Stop
                // is refused here.
                var stop = StopToken();

                string reply;
                var work = LocalProgress.Working(turn?.Label);
                try
                {
                    using (var both = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, stop))
                        reply = await request(both.Token).ConfigureAwait(false);
                    EnsureWholePromptRead(client.LastUsage, user, system, general.Model, window);
                    work.Answered(turn?.Interactive ?? true, asked);
                }
                catch (OperationCanceledException) when (stop.IsCancellationRequested)
                {
                    // Checked before the time limit below: a stopped request is
                    // neither a timeout nor memoQ giving up, and either of those
                    // would send a batch back one row at a time.
                    throw new StoppedException();
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
                    // Core's own time limit, not a caller giving up. Left as a
                    // cancellation it is rethrown as one all the way out, and the
                    // session then retries every row of the batch alone, each
                    // with the full limit again. As a failure, a batch is retried
                    // row by row - smaller requests, which a slow server can
                    // finish - and each row that still fails says why.
                    throw new TimeoutException(general.Provider + " at " + Address(general)
                        + " did not answer in time. A smaller model, or fewer segments per request, "
                        + "makes each answer quicker.");
                }
                catch (HttpRequestException ex) when (Unreachable(ex))
                {
                    // .NET says only "An error occurred while sending the
                    // request", and the likeliest reason here is that the
                    // translator has not started the server.
                    throw new InvalidOperationException("Could not reach " + general.Provider + " at "
                        + Address(general) + ". Is it running?", ex);
                }
                catch (HttpRequestException ex) when (ex.InnerException != null)
                {
                    // Reached, then lost: the connection broke off before an
                    // answer. Core's own errors for a server that answered badly
                    // carry no inner exception and keep their message. Seen in
                    // memoQ on 2026-10-13 while Ollama restarted to update itself,
                    // as three rows saying only "An error occurred while sending
                    // the request".
                    throw new InvalidOperationException("The connection to " + general.Provider + " at "
                        + Address(general) + " broke off before it answered (" + Innermost(ex).Message
                        + "). If it was restarting - after an update, say - try the segment again.", ex);
                }
                finally
                {
                    work.Dispose();
                }

                return reply;
            }
            finally
            {
                // However the request ended - answered, refused, failed - its place
                // goes to whoever is next.
                LocalQueue.Leave(parallel);
            }
        }

        private static readonly HttpClient Http = new HttpClient { Timeout = TimeSpan.FromSeconds(5) };

        // -- Stop ----------------------------------------------------------------

        /// <summary>
        /// How long after Stop new requests are refused. memoQ goes on sending
        /// what it had lined up - the rest of a Pre-translate, each row of a
        /// batch, the rows it fetches ahead - and every one of them would start
        /// the model again. Refused at once, they are over in a moment, and the
        /// translator who lands on a segment after that gets a translation.
        /// </summary>
        private static readonly TimeSpan StopFor = TimeSpan.FromSeconds(15);

        private static readonly object StopLock = new object();
        private static CancellationTokenSource _stop = new CancellationTokenSource();
        private static DateTime _stoppedUntil = DateTime.MinValue;

        /// <summary>
        /// The translator pressed Stop on the waiting notice: everything waiting
        /// is refused, everything under way is cancelled - closing the connection,
        /// which makes the server stop working on it - and anything new is
        /// refused for <see cref="StopFor"/>.
        ///
        /// <para>The only way out there was. On 2026-10-13 one Pre-translate
        /// batch to a local model ran for thirteen minutes, memoQ's own Cancel
        /// waited for it, and ending Ollama's worker made the batch come back
        /// row by row. Only quitting Ollama altogether ended it.</para>
        /// </summary>
        internal static void Stop()
        {
            CancellationTokenSource stopping;
            lock (StopLock)
            {
                stopping = _stop;
                _stop = new CancellationTokenSource();
                _stoppedUntil = DateTime.UtcNow + StopFor;
            }

            var refused = LocalQueue.RefuseAll(() => new StoppedException());
            PluginLog.Write($"local server: Stop pressed - {refused} waiting refused, any under way cancelled, "
                + $"new ones refused for {StopFor.TotalSeconds:0} s");

            // Last, and outside the lock: cancelling runs the requests' own
            // callbacks, which must not find this half done.
            stopping.Cancel();
        }

        private static void RefuseIfStopped()
        {
            lock (StopLock)
            {
                if (DateTime.UtcNow < _stoppedUntil) throw new StoppedException();
            }
        }

        /// <summary>The token Stop cancels, or a refusal while just stopped.</summary>
        private static CancellationToken StopToken()
        {
            lock (StopLock)
            {
                if (DateTime.UtcNow < _stoppedUntil) throw new StoppedException();
                return _stop.Token;
            }
        }

        /// <summary>
        /// The translator stopped it. Not a fault, and never retried: a batch
        /// stopped is not sent again one row at a time.
        /// </summary>
        internal sealed class StoppedException : InvalidOperationException
        {
            public StoppedException()
                : base("Not translated: Stop was pressed on Supervertaler's waiting notice. "
                    + "Go back to the segment, or run Pre-translate again, to have it translated.") { }
        }

        // -- the model's own limit -----------------------------------------------

        /// <summary>
        /// The most tokens the model can hold at all, as Ollama reports it, or
        /// null when there is no asking: another kind of server, no answer, a
        /// model Ollama does not have.
        ///
        /// <para>A model's window is part of the model, and no setting raises it.
        /// Ollama loads each model with the smaller of its own window and the
        /// Context length setting: measured 2026-10-13, under one setting of
        /// 32,768, qwen2.5:7b loaded with 32,768 and aya-expanse:8b with 8,192.
        /// One local request, asked for every request rather than remembered:
        /// about a tenth of a second, beside answers that take half a minute or
        /// more.</para>
        /// </summary>
        internal static async Task<int?> ModelWindowAsync(SupervertalerGeneralSettings general)
        {
            if (!string.Equals(general.Provider, LlmProviders.Ollama, StringComparison.OrdinalIgnoreCase)) return null;

            var model = (general.Model ?? string.Empty).Trim();
            if (model.Length == 0) return null;

            try
            {
                var body = new StringContent(
                    "{\"model\":\"" + model.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"}",
                    Encoding.UTF8, "application/json");
                using (var response = await Http.PostAsync(LlmProviders.OllamaAddress(general.Endpoint) + "/api/show", body)
                           .ConfigureAwait(false))
                {
                    if (!response.IsSuccessStatusCode) return null;
                    return WindowIn(await response.Content.ReadAsStringAsync().ConfigureAwait(false));
                }
            }
            catch (Exception)
            {
                // No judgement, and the request goes as it always has.
                return null;
            }
        }

        private static readonly Regex ContextLength = new Regex(
            "\"[A-Za-z0-9_.-]+\\.context_length\"\\s*:\\s*(?<n>\\d+)", RegexOptions.Compiled);

        /// <summary>
        /// The window in Ollama's description of a model: model_info carries it
        /// under the architecture's name - "qwen2.context_length",
        /// "command-r.context_length" - so the key is matched, not named.
        /// </summary>
        internal static int? WindowIn(string showJson)
        {
            if (string.IsNullOrEmpty(showJson)) return null;

            var info = showJson.IndexOf("\"model_info\"", StringComparison.Ordinal);
            if (info < 0) return null;

            var m = ContextLength.Match(showJson, info);
            return m.Success && int.TryParse(m.Groups["n"].Value, out var n) && n > 0 ? n : (int?)null;
        }

        /// <summary>
        /// Refuses, before anything is sent, a prompt far larger than the model
        /// can hold.
        ///
        /// <para>With the shared memory bank, a memoQ prompt was 16,446 tokens
        /// to aya-expanse:8b, whose window is 8,192. Ollama kept 4,099 of them
        /// and answered after five minutes of reading, and only then did
        /// <see cref="EnsureWholePromptRead"/> refuse the answer - with advice to
        /// raise a setting that cannot help. Judged on core's estimate, so only
        /// when the prompt is half as large again as the window: real tokenisers
        /// land within a third of the estimate, so such a prompt cannot fit.
        /// Nearer the line the request goes, and the server's own count
        /// decides.</para>
        /// </summary>
        internal static void RefuseIfTooLarge(string model, int? window, string user, string system)
        {
            if (window == null) return;

            var sent = TokenEstimator.EstimateInputTokens(user, system);
            if (sent < MinTokensToJudge || sent <= window.Value * 3L / 2) return;

            PluginLog.Write($"local server: about {sent:N0} prompt tokens for a model that holds {window.Value:N0}; not sent");
            throw new ContextTooSmallException($"Not sent: {Name(model)} can hold at most {window.Value:N0} tokens, "
                + $"and this prompt is about {sent:N0}. " + ModelLimit);
        }

        /// <summary>What to do when the model itself is too small for the prompt.</summary>
        private const string ModelLimit = "That limit is part of the model, and no setting raises it. Choose a "
            + "model that holds more, or send less: switching off \"Send the memory bank to the model\" in "
            + "Settings usually does it.";

        private static string Name(string model) =>
            string.IsNullOrWhiteSpace(model) ? "the model" : model.Trim();

        // -- Ollama's cloud ------------------------------------------------------

        /// <summary>
        /// What the hit's Info line names as its source: "Ollama cloud" for a
        /// model that runs on Ollama's servers, otherwise the provider.
        ///
        /// <para>Asks Ollama's model list, which marks a cloud model with
        /// remote_host whatever it is called - one local request, beside an
        /// answer that took seconds at least. When the list cannot be read, or
        /// does not list the model, the name decides (see
        /// <see cref="LlmProviders.IsOllamaCloudModel"/>). Never refuses: cloud
        /// models are allowed, and this is how the translator sees one is in
        /// use, on every segment it translates.</para>
        /// </summary>
        public static async Task<string> ProviderLabelAsync(SupervertalerGeneralSettings general)
        {
            if (!string.Equals(general.Provider, LlmProviders.Ollama, StringComparison.OrdinalIgnoreCase))
                return general.Provider;

            string host = null;
            var listed = false;
            try
            {
                var json = await Http.GetStringAsync(LlmProviders.OllamaAddress(general.Endpoint) + "/api/tags")
                    .ConfigureAwait(false);
                host = RemoteHostIn(json, general.Model, out listed);
            }
            catch (Exception)
            {
                // The name decides instead.
            }

            var cloud = listed ? host != null : LlmProviders.IsOllamaCloudModel(general.Provider, general.Model);
            if (!cloud) return general.Provider;

            ReportCloud(general.Model, host ?? "Ollama's servers");
            return CloudLabel;
        }

        internal const string CloudLabel = "Ollama cloud";

        /// <summary>
        /// The remote_host Ollama's model list gives this model, or null for one
        /// that runs where Ollama does. <paramref name="listed"/> says whether the
        /// list had the model at all. "qwen2.5" finds "qwen2.5:latest", as Ollama
        /// itself resolves it.
        /// </summary>
        internal static string RemoteHostIn(string tagsJson, string model, out bool listed)
        {
            listed = false;
            var wanted = (model ?? string.Empty).Trim();
            if (wanted.Length == 0 || string.IsNullOrWhiteSpace(tagsJson)) return null;

            TagList list;
            using (var stream = new MemoryStream(Encoding.UTF8.GetBytes(tagsJson)))
                list = new DataContractJsonSerializer(typeof(TagList)).ReadObject(stream) as TagList;

            foreach (var entry in list?.Models ?? new TagEntry[0])
            {
                if (entry == null) continue;
                if (!Same(entry.Name, wanted) && !Same(entry.Model, wanted)) continue;

                listed = true;
                return string.IsNullOrWhiteSpace(entry.RemoteHost) ? null : entry.RemoteHost.Trim();
            }

            return null;
        }

        private static bool Same(string listedName, string wanted)
        {
            if (string.IsNullOrWhiteSpace(listedName)) return false;
            if (string.Equals(listedName, wanted, StringComparison.OrdinalIgnoreCase)) return true;
            return wanted.IndexOf(':') < 0
                && string.Equals(listedName, wanted + ":latest", StringComparison.OrdinalIgnoreCase);
        }

#pragma warning disable 0649 // written by the deserialiser
        [DataContract] private sealed class TagList { [DataMember(Name = "models")] public TagEntry[] Models; }

        [DataContract]
        private sealed class TagEntry
        {
            [DataMember(Name = "name")] public string Name;
            [DataMember(Name = "model")] public string Model;
            [DataMember(Name = "remote_host")] public string RemoteHost;
        }
#pragma warning restore 0649

        private static readonly object CloudLock = new object();
        private static string _cloudReported;

        /// <summary>Says once, each time it changes, which cloud model is in use and where it runs.</summary>
        private static void ReportCloud(string model, string host)
        {
            var key = (model ?? string.Empty).Trim() + " @ " + host;
            lock (CloudLock)
            {
                if (string.Equals(_cloudReported, key, StringComparison.Ordinal)) return;
                _cloudReported = key;
            }

            PluginLog.Write($"Ollama: {model} runs on {host}, not this computer - "
                + "the text of each request is sent there");
        }

        /// <summary>The address requests go to, for a message.</summary>
        private static string Address(SupervertalerGeneralSettings general)
        {
            return string.Equals(general.Provider, LlmProviders.Ollama, StringComparison.OrdinalIgnoreCase)
                ? LlmProviders.OllamaAddress(general.Endpoint)
                : (general.Endpoint ?? string.Empty).Trim();
        }

        private static Exception Innermost(Exception ex)
        {
            while (ex.InnerException != null) ex = ex.InnerException;
            return ex;
        }

        /// <summary>Nothing answered at that address, as opposed to something answering badly.</summary>
        internal static bool Unreachable(Exception ex)
        {
            for (var e = ex; e != null; e = e.InnerException)
            {
                if (e is SocketException) return true;
                if (e is WebException web
                    && (web.Status == WebExceptionStatus.ConnectFailure
                        || web.Status == WebExceptionStatus.NameResolutionFailure))
                    return true;
            }
            return false;
        }

        /// <summary>
        /// Below this, a prompt is not judged. Nothing that short is cut by any
        /// server's context window, and the estimate is too rough to compare at
        /// that size.
        /// </summary>
        internal const int MinTokensToJudge = 1500;

        /// <summary>
        /// Throws when the server says it read less than half of what was sent.
        ///
        /// <para>Ollama's context window is 4,096 tokens unless it is told
        /// otherwise, on a computer without a graphics card at least. Given more,
        /// it keeps the first five tokens and the last two thousand or so, drops
        /// everything in between, and answers as if nothing had happened: HTTP
        /// 200, stop reason "stop", a fluent translation. Measured 2026-10-12 with
        /// a 25,000-token prompt whose first line said to reply with one fixed
        /// word: the reply was a correct Dutch translation, because that line was
        /// gone. A memoQ prompt puts the instructions, the glossary and the memory
        /// bank first and the segments last, so what goes missing is exactly the
        /// part that makes it a Supervertaler translation.</para>
        ///
        /// <para>The server's own count is the evidence. It reports how many
        /// tokens it read, after cutting, and the count stays whole when the
        /// prompt is served from its cache. Half is a wide margin: core's estimate
        /// is four characters a token, and real tokenisers land within a third of
        /// that either way. No count, no judgement.</para>
        /// </summary>
        internal static void EnsureWholePromptRead(ApiUsage usage, string user, string system,
            string model = null, int? window = null)
        {
            if (usage == null) return;

            var sent = TokenEstimator.EstimateInputTokens(user, system);
            if (sent < MinTokensToJudge) return;

            var read = usage.RegularInputTokens + usage.CacheReadTokens + usage.CacheWriteTokens;
            if (read <= 0 || read * 2L >= sent) return;

            PluginLog.Write($"local server: read {read:N0} of about {sent:N0} prompt tokens; reply refused");
            throw new ContextTooSmallException(TooSmallMessage(read, sent, model, window));
        }

        /// <summary>
        /// The server's context window is smaller than the prompt. A setting on
        /// the server, not a fault in one reply, so asking again - one segment at
        /// a time, as a failed batch otherwise is - sends the same instructions
        /// into the same window and costs a slow request per row to learn nothing.
        /// </summary>
        internal sealed class ContextTooSmallException : InvalidOperationException
        {
            public ContextTooSmallException(string message) : base(message) { }
        }

        /// <param name="window">
        /// The model's own window, when known. A prompt larger than that is not
        /// fixed by any setting, and saying "raise the context length" sent the
        /// translator to a setting that could not help.
        /// </param>
        internal static string TooSmallMessage(int read, int sent, string model = null, int? window = null)
        {
            var text = $"The model's server read only {read:N0} of about {sent:N0} tokens of the prompt. The rest - "
                + "instructions, glossary, memory bank - was cut off, so the answer was not used. ";

            if (window != null && sent >= window.Value)
                return text + $"{Name(model)} can hold at most {window.Value:N0} tokens. " + ModelLimit;

            return text + "Raise the server's context length to at least " + Suggested(sent, window)
                + ": in Ollama, Settings > Context length (or OLLAMA_CONTEXT_LENGTH), then restart it; in "
                + "LM Studio, the model's Context Length when it is loaded.";
        }

        /// <summary>
        /// The next of the sizes the servers offer that fits the prompt and a
        /// reply, and no more than the model holds. Ollama cuts a prompt only
        /// when it fills the whole window (llama_server.go, read 2026-10-13), so
        /// the reply is the only room needed beside it.
        /// </summary>
        private static string Suggested(int sent, int? window)
        {
            var needed = sent + 4096;
            var size = 8192;
            while (size < needed && size < 262144) size *= 2;
            if (window != null && size > window.Value) size = window.Value;
            return size.ToString("N0") + " tokens";
        }
    }
}
