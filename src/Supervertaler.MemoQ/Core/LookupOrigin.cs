using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;

namespace Supervertaler.MemoQ.Core
{
    /// <summary>
    /// Who in memoQ asked for a translation. Only bridge mode cares: it captures a
    /// Pre-translate for Claude, but the row the translator lands on should still
    /// get a suggestion from the model.
    /// </summary>
    internal enum LookupOrigin
    {
        /// <summary>
        /// Neither caller recognised. Wherever it matters this counts as a
        /// Pre-translate, so a rename in memoQ brings back the old behaviour
        /// (the row is captured) rather than model calls nobody asked for.
        /// </summary>
        Unknown,

        /// <summary>memoQ's grid, for the row the translator has just landed on.</summary>
        Grid,

        /// <summary>A Pre-translate run, one row or many.</summary>
        PreTranslate,
    }

    /// <summary>
    /// Tells a grid lookup from a Pre-translate by memoQ's own code on the stack,
    /// because the MT SDK gives a plugin no other way. Both arrive on
    /// <c>ISession</c>'s array overload with the same metadata, from the same
    /// engine, and a one-row Pre-translate is one row like a lookup; memoQ 12.5
    /// sends even a single grid lookup through the array overload.
    ///
    /// Measured live on 2026-10-22 (memoQ 12.5, branch probe-lookup-engines): every
    /// click into a row came from
    /// <c>MemoQ.TranslationEnvironment.MT.Managers.Local.ClientMTManager.SyncLookupSingle</c>,
    /// and every Pre-translate - the one-row one included - from
    /// <c>MemoQ.Project.PreTranslateAndStatisticsJob`1.preTranslateBatchMT</c>.
    /// Both names are in memoQ 11's DLLs as well as 12's.
    ///
    /// These are memoQ internals, not a contract, so the rule is built to fail
    /// safe. A request counts as a grid lookup only when the grid's method is
    /// positively on the stack and nothing Pre-translate is; anything else is
    /// <see cref="LookupOrigin.Unknown"/>, which bridge mode captures exactly as
    /// it did before this existed. A future memoQ that renames either method can
    /// only bring the old bug back - the log says so on every captured batch - and
    /// never sends a Pre-translate to the model.
    /// </summary>
    internal static class LookupOriginDetector
    {
        /// <summary>
        /// The origin of the call in progress on this thread. Must be read where
        /// memoQ called the session, before any <c>Task.Run</c>: on another thread
        /// memoQ's frames are not on the stack. Never throws.
        /// </summary>
        internal static LookupOrigin Current()
        {
            try
            {
                var frames = new StackTrace(1, false).GetFrames();
                if (frames == null) return LookupOrigin.Unknown;

                return FromFrames(frames
                    .Select(f => f.GetMethod())
                    .Where(m => m != null && m.DeclaringType != null)
                    .Select(m => m.DeclaringType.FullName + "." + m.Name));
            }
            catch
            {
                return LookupOrigin.Unknown;
            }
        }

        /// <summary>
        /// The rule itself, over "Namespace.Type.Method" names, so it can be tested
        /// without memoQ. Only memoQ's own frames count: a method of ours, or of
        /// the framework, whose name happens to say PreTranslate decides nothing.
        /// </summary>
        internal static LookupOrigin FromFrames(IEnumerable<string> frames)
        {
            if (frames == null) return LookupOrigin.Unknown;

            var grid = false;
            foreach (var frame in frames)
            {
                if (frame == null || !frame.StartsWith("MemoQ.", StringComparison.Ordinal)) continue;

                // Pre-translate wins wherever it appears: capturing a row the
                // translator wanted costs a suggestion, translating a row the
                // translator wanted captured costs money and fills the target.
                if (frame.IndexOf("PreTranslate", StringComparison.OrdinalIgnoreCase) >= 0)
                    return LookupOrigin.PreTranslate;

                if (frame.EndsWith(".SyncLookupSingle", StringComparison.Ordinal))
                    grid = true;
            }

            return grid ? LookupOrigin.Grid : LookupOrigin.Unknown;
        }
    }
}
