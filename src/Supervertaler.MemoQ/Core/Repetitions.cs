using System.Collections.Generic;
using System.Globalization;
using System.Net;
using System.Text.RegularExpressions;
using MemoQ.Addins.Common.DataStructures;
using MemoQ.MTInterfaces;
using Supervertaler.Core;

namespace Supervertaler.MemoQ.Core
{
    /// <summary>
    /// memoQ's side of consistent repetitions (core's <see cref="RepetitionRun"/>;
    /// docs/design/consistent-repetitions.md §4 in the Trados repo): the match key
    /// of a memoQ segment, and the step that gives each row of a Pre-translate call
    /// its group's translation.
    ///
    /// <para>memoQ writes the results itself, so this cannot touch a row it has
    /// already answered - only what this call hands back. The AI still translates
    /// every row exactly as before; a later repetition is given its group's
    /// translation in place of its own.</para>
    /// </summary>
    internal static class Repetitions
    {
        /// <summary>
        /// The match key of a source row, or null for a row that is not grouped:
        /// empty, or nothing to translate (tags and punctuation only, which are
        /// copied from the source anyway). Exact text - case, a non-breaking space,
        /// a tab all count - with each tag reduced to its kind and place, never its
        /// number.
        /// </summary>
        public static string KeyOf(Segment source)
        {
            if (source == null || source.IsEmptyText || NothingToTranslate.Applies(source)) return null;
            return RepetitionKey.Of(Tokens(TagBridge.ToTaggedText(source), source.ITags));
        }

        // memoQ's segment XML, as TagBridge.ToTaggedText writes it: a pair is an
        // element, <inline_tag id="0">B</inline_tag>; a single tag is
        // <inline_tag id="2"/>; a tag whose partner is in another segment is a
        // bare <inline_tag id="1"> or </inline_tag>; a character XML reserves is
        // <spec_char val="&amp;"/>. Anything else is kept whole as a tag of its own.
        private static readonly Regex Markup = new Regex(
            "<inline_tag id=\"(?<id>\\d+)\"\\s*(?<single>/)?>|(?<close></inline_tag>)|<spec_char val=\"(?<char>[^\"]*)\"\\s*/>|<[^<>]*>",
            RegexOptions.Compiled);

        /// <summary>
        /// The tokens of tagged text, with each tag's kind taken from
        /// <paramref name="tags"/>, the segment's own tag list. memoQ numbers a
        /// tag by its place in that list, which is the order the tags stand in
        /// the segment, closings included - so a closing, which carries no number,
        /// is the list entry after the last tag passed. A tag's kind is its name
        /// (bold, image, ...): its attributes stay out, because the model never
        /// sees them and every row is given its own tags back.
        /// </summary>
        internal static IEnumerable<RepetitionToken> Tokens(string tagged, IList<InlineTag> tags)
        {
            var text = tagged ?? "";
            var next = 0;
            var at = 0;

            foreach (Match m in Markup.Matches(text))
            {
                if (m.Index > at) yield return RepetitionToken.Text(WebUtility.HtmlDecode(text.Substring(at, m.Index - at)));
                at = m.Index + m.Length;

                if (m.Groups["id"].Success)
                {
                    var index = int.Parse(m.Groups["id"].Value, CultureInfo.InvariantCulture);
                    next = index + 1;
                    var kind = KindAt(tags, index);
                    yield return m.Groups["single"].Success ? RepetitionToken.Standalone(kind) : RepetitionToken.Open(kind);
                }
                else if (m.Groups["close"].Success)
                {
                    yield return RepetitionToken.Close(KindAt(tags, next));
                    next++;
                }
                else if (m.Groups["char"].Success)
                {
                    yield return RepetitionToken.Text(WebUtility.HtmlDecode(m.Groups["char"].Value));
                }
                else
                {
                    yield return RepetitionToken.Standalone("markup:" + m.Value);
                }
            }

            if (at < text.Length) yield return RepetitionToken.Text(WebUtility.HtmlDecode(text.Substring(at)));
        }

        private static string KindAt(IList<InlineTag> tags, int index)
        {
            return tags != null && index >= 0 && index < tags.Count && tags[index] != null ? tags[index].Name ?? "" : "";
        }

        /// <summary>
        /// Gives each row of one call its group's translation, in row order, and
        /// returns <paramref name="results"/>. The first translation a group gets
        /// in the run is its translation - in this call or in another session
        /// running beside it - and a later row whose own was worded differently,
        /// or failed, gets that one instead, with its own tags. A row that is not
        /// grouped, or whose translation carries a tag that cannot be traced to
        /// its source, is left as it is.
        /// </summary>
        public static TranslationResult[] Align(RepetitionRun run, Segment[] sources, TranslationResult[] results)
        {
            if (run == null || sources == null || results == null) return results;

            int aligned = 0, filled = 0, differed = 0;

            for (var i = 0; i < results.Length && i < sources.Length; i++)
            {
                var key = KeyOf(sources[i]);
                if (string.IsNullOrEmpty(key)) continue;

                var result = results[i];
                var succeeded = result != null && result.Exception == null
                                && result.Translation != null && !result.Translation.IsEmpty;

                string own = null;
                if (succeeded)
                {
                    own = TagBridge.ToTaggedTextIn(result.Translation, sources[i]);
                    if (own == null)
                    {
                        PluginLog.Write($"repetitions: row {i + 1} of this call left as it is - its translation "
                            + "carries a tag that is not one of its source's");
                        continue;
                    }
                }

                var delivery = run.Settle(key, own);
                if (delivery.Source != RepetitionSource.Group || !(delivery.OwnFailed || delivery.Differed)) continue;

                results[i] = new TranslationResult
                {
                    Translation = TagBridge.FromTaggedText(delivery.Text, sources[i]),
                    Info = (succeeded && !string.IsNullOrEmpty(result.Info) ? result.Info : "Supervertaler")
                           + " – same translation as an earlier repetition in this run"
                };

                aligned++;
                if (delivery.OwnFailed) filled++;
                if (delivery.Differed) differed++;
            }

            if (aligned > 0)
            {
                var details = new List<string>();
                if (differed > 0) details.Add($"{differed} worded differently by the model");
                if (filled > 0) details.Add($"{filled} in place of a failed translation");
                PluginLog.Write($"repetitions: {aligned} row(s) given the translation of an earlier repetition in this run ("
                    + string.Join(", ", details) + ")");
            }

            return results;
        }
    }
}
