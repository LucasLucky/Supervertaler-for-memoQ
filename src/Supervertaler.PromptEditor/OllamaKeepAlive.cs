using System;
using Supervertaler.MemoQ.Core;

namespace Supervertaler.PromptEditor
{
    /// <summary>
    /// Whether Ollama keeps a model loaded for as long as it runs, through
    /// Ollama's own OLLAMA_KEEP_ALIVE variable for this Windows account.
    ///
    /// <para>Ollama unloads a model five minutes after its last request, and with
    /// it everything it had read of Supervertaler's prompt; on a computer without
    /// a graphics card the next segment then takes ten minutes or more again
    /// (measured 2026-10-13, after a 34-minute pause). The proper place for a
    /// longer value is the request itself, which core builds - proposed to its
    /// owner, and until then this is the switch that works: Ollama reads the
    /// variable when it starts.</para>
    ///
    /// <para>It is Ollama's setting, not Supervertaler's: it applies to every
    /// program that uses Ollama, and the loaded model keeps its memory until
    /// Ollama is quit. Hence a box the translator ticks, never a default.</para>
    /// </summary>
    internal static class OllamaKeepAlive
    {
        internal const string Variable = "OLLAMA_KEEP_ALIVE";

        /// <summary>
        /// Whether a value of the variable means "never unload". Ollama reads a
        /// negative duration - "-1", "-1m" - as forever; anything else, including
        /// nothing, is a time limit.
        /// </summary>
        internal static bool IsForever(string value) =>
            !string.IsNullOrWhiteSpace(value) && value.Trim().StartsWith("-", StringComparison.Ordinal);

        /// <summary>The variable as Windows holds it for this account, or null.</summary>
        internal static string Current()
        {
            try { return Environment.GetEnvironmentVariable(Variable, EnvironmentVariableTarget.User); }
            catch { return null; }
        }

        /// <summary>
        /// Sets "keep loaded" on or off, and returns whether anything changed.
        /// Off removes the variable only when it says "forever"; a value of the
        /// translator's own - 30 minutes, say - is left as it is. Never under a
        /// harness: the variable is the user's real one.
        /// </summary>
        internal static bool Set(bool forever)
        {
            if (SharedSettings.InHarness) return false;

            var current = Current();
            if (forever == IsForever(current)) return false;

            // Off means Ollama's own default again, five minutes: the variable
            // is removed rather than set to it.
            Environment.SetEnvironmentVariable(Variable, forever ? "-1" : null, EnvironmentVariableTarget.User);
            return true;
        }
    }
}
