using System;
using Supervertaler.Core;

namespace Supervertaler.MemoQ.Settings
{
    /// <summary>
    /// Provider identifiers. Strings, not an enum, so an unknown value in an old
    /// settings file degrades rather than throws.
    ///
    /// In its own file because the prompt editor compiles it too: the editor
    /// offers the same choice of providers and must not carry a second copy of
    /// the list that can fall behind this one.
    /// </summary>
    public static class LlmProviders
    {
        public const string Anthropic = "Anthropic";
        public const string OpenAI = "OpenAI";
        public const string Google = "Google";

        /// <summary>Ollama, on this computer or another one the translator runs.</summary>
        public const string Ollama = "Ollama";

        /// <summary>
        /// Any server that speaks OpenAI's chat completions API at an address the
        /// translator gives: LM Studio, llama.cpp, vLLM, Jan, a company gateway.
        /// </summary>
        public const string OpenAICompatible = "OpenAI-compatible";

        public static readonly string[] All = { Anthropic, OpenAI, Google, Ollama, OpenAICompatible };

        /// <summary>Where Ollama listens unless it has been told otherwise.</summary>
        public const string OllamaDefaultEndpoint = "http://localhost:11434";

        /// <summary>
        /// The id core uses for the same provider, or null when there is none.
        ///
        /// memoQ names its providers for the user; core names all nine for the
        /// wire, the model lists and the shared key file. One translation, in one
        /// place, because getting it wrong is silent both ways: an unmapped name
        /// shows as an empty model list, and a wrong one reads somebody else's key.
        ///
        /// <para><b>Google is the trap.</b> Core calls Gemini <c>gemini</c>, and
        /// the shared key file keeps <c>google</c> for Supervertaler Sidekick's
        /// Google Translate key - a different service entirely. Passing the
        /// user-facing word "Google" through unmapped would read that one.</para>
        /// </summary>
        public static string CoreKey(string provider)
        {
            if (string.Equals(provider, Anthropic, StringComparison.OrdinalIgnoreCase)) return LlmModels.ProviderClaude;
            if (string.Equals(provider, OpenAI, StringComparison.OrdinalIgnoreCase)) return LlmModels.ProviderOpenAi;
            if (string.Equals(provider, Google, StringComparison.OrdinalIgnoreCase)) return LlmModels.ProviderGemini;
            if (string.Equals(provider, Ollama, StringComparison.OrdinalIgnoreCase)) return LlmModels.ProviderOllama;
            if (string.Equals(provider, OpenAICompatible, StringComparison.OrdinalIgnoreCase)) return LlmModels.ProviderCustomOpenAi;
            return null;
        }

        /// <summary>
        /// True when requests go to an address the translator chose rather than to
        /// the provider's own servers, so the endpoint setting applies. Only these
        /// two: core sends Anthropic, OpenAI and Google to their own addresses
        /// whatever the endpoint says.
        /// </summary>
        public static bool TakesEndpoint(string provider)
        {
            return string.Equals(provider, Ollama, StringComparison.OrdinalIgnoreCase)
                || string.Equals(provider, OpenAICompatible, StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>
        /// True when the name says this Ollama model runs on Ollama's servers
        /// rather than on the computer Ollama is on. Ollama names its cloud models
        /// with a "-cloud" ending or a ":cloud" tag, and checks for exactly those
        /// two itself (found in ollama.exe 0.40.3, 2026-10-13).
        ///
        /// <para>The name is what a dialog has to go on while the model is being
        /// typed. A request asks Ollama instead - its model list marks a cloud
        /// model with remote_host, whatever the model is called - and falls back
        /// on this. Allowed, never refused: the translator is told, and
        /// decides.</para>
        /// </summary>
        public static bool IsOllamaCloudModel(string provider, string model)
        {
            if (!string.Equals(provider, Ollama, StringComparison.OrdinalIgnoreCase)) return false;
            var name = (model ?? string.Empty).Trim();
            return name.EndsWith("-cloud", StringComparison.OrdinalIgnoreCase)
                || name.EndsWith(":cloud", StringComparison.OrdinalIgnoreCase);
        }

        /// <summary>
        /// Whether a request cannot be made without a key. Ollama has none, and a
        /// server of the translator's own may or may not want one.
        /// </summary>
        public static bool NeedsKey(string provider)
        {
            return CoreKey(provider) != null && !TakesEndpoint(provider);
        }

        /// <summary>
        /// The client for a provider. The one place a memoQ provider name becomes
        /// a core client, so that no caller can map it differently.
        ///
        /// <para>It refuses rather than guesses. An unknown provider used to be
        /// translated as Anthropic, and an OpenAI-compatible provider with no
        /// address would go to api.openai.com, which is core's fallback: both
        /// would send a confidential document somewhere the translator did not
        /// choose - most likely someone who picked a local model precisely so that
        /// it would not leave the building. The message reaches memoQ's grid.</para>
        /// </summary>
        public static LlmClient CreateClient(string provider, string model, string apiKey, string endpoint)
        {
            var core = CoreKey(provider);
            if (core == null)
                throw new InvalidOperationException("Supervertaler does not know the provider \"" + provider
                    + "\". Choose one in Supervertaler's translation settings.");

            string address = null;
            if (TakesEndpoint(provider))
            {
                address = string.IsNullOrWhiteSpace(endpoint) ? null : endpoint.Trim();
                if (core == LlmModels.ProviderOllama)
                    address = OllamaAddress(address);
                else if (address == null)
                    throw new InvalidOperationException("No endpoint is set for the OpenAI-compatible server. "
                        + "Enter its address in Supervertaler's translation settings, for example "
                        + "http://localhost:1234/v1 for LM Studio.");
            }

            return new LlmClient(core, model, apiKey ?? string.Empty, address,
                ollamaTimeoutMinutes: LocalTimeoutMinutes);
        }

        /// <summary>
        /// Ollama's base address as core wants it, which appends /api/chat itself.
        /// Blank means the default. A trailing /v1 or /api is taken off: /v1 is
        /// the address of Ollama's OpenAI-compatible API, which is what every
        /// other local server's instructions say to type, and keeping it would
        /// send requests to /v1/api/chat, which does not exist.
        /// </summary>
        public static string OllamaAddress(string endpoint)
        {
            if (string.IsNullOrWhiteSpace(endpoint)) return OllamaDefaultEndpoint;

            // Only the path is trimmed, never the host: a server called "api"
            // is a host name, not a suffix.
            var typed = endpoint.Trim();
            if (!Uri.TryCreate(typed, UriKind.Absolute, out var uri)) return typed.TrimEnd('/');

            var path = uri.AbsolutePath.TrimEnd('/');
            foreach (var suffix in new[] { "/v1", "/api" })
            {
                if (path.EndsWith(suffix, StringComparison.OrdinalIgnoreCase))
                    path = path.Substring(0, path.Length - suffix.Length).TrimEnd('/');
            }

            return uri.GetLeftPart(UriPartial.Authority) + path;
        }

        /// <summary>
        /// How long one request to Ollama may take. Core's own guess goes by the
        /// size in the model's name - three minutes for a name without one - and
        /// that is far too short for the first request of a job on a computer
        /// without a graphics card. Measured 2026-10-12, TranslateGemma 4B on a
        /// CPU: a 25,000-token prompt took 622 seconds to read the first time and
        /// 6 seconds every time after, from Ollama's cache. A 12B model is about
        /// three times slower. A server that is down fails at once whatever this
        /// says; the limit only decides how long a slow one is waited for.
        /// </summary>
        internal const int LocalTimeoutMinutes = 30;
    }
}
