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

        /// <summary>
        /// In place of the model note, in red, while an Ollama cloud model is
        /// chosen. It does not stop anything: the translator may want Ollama's
        /// cloud, and only has to know that the text leaves the computer.
        /// </summary>
        public const string CloudWarning = "Cloud model: your text goes to Ollama's servers, not this computer.";

        /// <summary>A cloud model's verdict in the dropdown, where it is chosen.</summary>
        public const string CloudDescription = "runs on Ollama's servers - the text leaves this computer";

        /// <summary>Beside Parallel requests.</summary>
        public const string ParallelHint = "Cloud and local servers each keep their own.";

        private static bool Is(string provider, string name) =>
            string.Equals(provider, name, StringComparison.OrdinalIgnoreCase);
    }
}
