using System;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
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
    /// <para>Applies to Ollama and OpenAI-compatible only. Every call to a model
    /// made inside memoQ's process goes through <see cref="AskAsync"/>, so a
    /// provider added later cannot skip either half by accident.</para>
    /// </summary>
    internal static class LocalServer
    {
        /// <summary>
        /// Sends one request, waiting first for a free place when the server is
        /// the translator's own, and refuses an answer made from part of the
        /// prompt.
        ///
        /// <para>The queue is here and not at the server because the timeout
        /// starts when the request is sent. memoQ calls the plugin from several
        /// threads at once and Ollama works on one request at a time unless told
        /// otherwise, so the fourth request of a Pre-translate used to spend three
        /// requests' worth of its own time limit waiting in Ollama's queue.</para>
        ///
        /// <para>How many go at once is the Parallel requests setting, read for
        /// every request, so a change in the settings applies to the next one.
        /// memoQ itself reads that setting only when the MT settings resource is
        /// created, which makes this the only place a change to it does anything
        /// for an existing resource.</para>
        /// </summary>
        /// <param name="client">The client <paramref name="request"/> uses; its usage is read afterwards.</param>
        /// <param name="user">The user prompt sent, for judging how much of it was read.</param>
        /// <param name="system">The system prompt sent, likewise.</param>
        public static async Task<string> AskAsync(
            SupervertalerGeneralSettings general,
            LlmClient client,
            Func<Task<string>> request,
            string user,
            string system,
            CancellationToken cancellationToken)
        {
            if (!LlmProviders.TakesEndpoint(general.Provider))
                return await request().ConfigureAwait(false);

            var gate = Gate(general.MaxParallelRequests);
            await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                string reply;
                try
                {
                    reply = await request().ConfigureAwait(false);
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

                EnsureWholePromptRead(client.LastUsage, user, system);
                return reply;
            }
            finally
            {
                // The semaphore this request took, not whichever is current: a
                // change of setting while it ran replaces the gate, and releasing
                // the new one would let one request too many through it.
                gate.Release();
            }
        }

        /// <summary>The address requests go to, for a message.</summary>
        private static string Address(SupervertalerGeneralSettings general)
        {
            return string.Equals(general.Provider, LlmProviders.Ollama, StringComparison.OrdinalIgnoreCase)
                ? LlmProviders.OllamaAddress(general.Endpoint)
                : (general.Endpoint ?? string.Empty).Trim();
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

        private static readonly object GateLock = new object();
        private static SemaphoreSlim _gate;
        private static int _gateSize;

        /// <summary>
        /// The gate for this many requests at once. A new size gets a new gate and
        /// the old one is left to the requests still holding it, so for as long as
        /// those take, both sizes are in use. That overlap is the price of not
        /// resizing a semaphore in place, which is where a clever lock goes wrong.
        /// </summary>
        private static SemaphoreSlim Gate(int parallel)
        {
            var size = Math.Max(1, Math.Min(16, parallel));
            lock (GateLock)
            {
                if (_gate == null || _gateSize != size)
                {
                    _gate = new SemaphoreSlim(size, size);
                    _gateSize = size;
                }
                return _gate;
            }
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
        internal static void EnsureWholePromptRead(ApiUsage usage, string user, string system)
        {
            if (usage == null) return;

            var sent = TokenEstimator.EstimateInputTokens(user, system);
            if (sent < MinTokensToJudge) return;

            var read = usage.RegularInputTokens + usage.CacheReadTokens + usage.CacheWriteTokens;
            if (read <= 0 || read * 2L >= sent) return;

            PluginLog.Write($"local server: read {read:N0} of about {sent:N0} prompt tokens; reply refused");
            throw new ContextTooSmallException(TooSmallMessage(read, sent));
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

        internal static string TooSmallMessage(int read, int sent)
        {
            return $"The model's server read only {read:N0} of about {sent:N0} tokens of the prompt. The rest - "
                + "instructions, glossary, memory bank - was cut off, so the answer was not used. Raise the "
                + "server's context length to at least " + Suggested(sent) + ": in Ollama, Settings > "
                + "Context length (or OLLAMA_CONTEXT_LENGTH), then restart it; in LM Studio, the model's "
                + "Context Length when it is loaded.";
        }

        /// <summary>The next of the sizes the servers offer that fits the prompt and a reply.</summary>
        private static string Suggested(int sent)
        {
            var needed = sent + 4096;
            var size = 8192;
            while (size < needed && size < 262144) size *= 2;
            return size.ToString("N0") + " tokens";
        }
    }
}
