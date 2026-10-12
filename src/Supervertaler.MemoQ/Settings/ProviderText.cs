using System;

namespace Supervertaler.MemoQ.Settings
{
    /// <summary>
    /// What the two settings dialogs say about a provider - memoQ's options
    /// dialog and the editor's Translation settings. One copy, compiled into
    /// both, so the dialogs cannot describe the same provider differently.
    ///
    /// Every line fits on one row of the narrower dialog: the labels holding
    /// them are rewritten as the provider changes, after the layout is fixed.
    /// </summary>
    internal static class ProviderText
    {
        /// <summary>Under the endpoint box.</summary>
        public static string EndpointHint(string provider)
        {
            if (Is(provider, LlmProviders.Ollama))
                return "Blank means Ollama on this computer: " + LlmProviders.OllamaDefaultEndpoint;
            if (Is(provider, LlmProviders.OpenAICompatible))
                return "Include /v1. LM Studio: http://localhost:1234/v1";
            return "Only used with Ollama and OpenAI-compatible servers.";
        }

        /// <summary>Under the key box when the key itself gives nothing to say.</summary>
        public static string KeyNote(string provider)
        {
            if (Is(provider, LlmProviders.Ollama)) return "Ollama needs no API key.";
            if (Is(provider, LlmProviders.OpenAICompatible)) return "Optional - only if the server asks for one.";
            return string.Empty;
        }

        /// <summary>
        /// Under the model box before anything has been fetched, or null for the
        /// wording every cloud provider shares.
        /// </summary>
        public static string ModelNote(string provider)
        {
            if (Is(provider, LlmProviders.Ollama))
                return "Suggestions to download. Fetch list shows the models installed.";
            if (Is(provider, LlmProviders.OpenAICompatible))
                return "Type the model's name as the server knows it, or Fetch list.";
            return null;
        }

        private static bool Is(string provider, string name) =>
            string.Equals(provider, name, StringComparison.OrdinalIgnoreCase);
    }
}
