using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using Supervertaler.Core;

namespace Supervertaler.MemoQ.Core
{
    /// <summary>
    /// The document's source text as a block for the system half of a request:
    /// Supervertaler for Trados's <c># DOCUMENT CONTENT</c>, built from what memoQ
    /// lets a plugin see. Pure functions of the rows they are given;
    /// <see cref="EngineContext.DocumentContextBlock"/> decides whether to send it
    /// and keeps the block between rebuilds. The design, and what it costs, is in
    /// docs/design/whole-document-context.md.
    ///
    /// <para>The block sits in the half the provider caches, so it has to come out
    /// the same to the byte for as long as the document does. Everything here is
    /// therefore decided by the rows alone - no clock, no count of requests - and
    /// the captured rows are cut at a fixed point (<see cref="CapturedPrefix"/>).</para>
    /// </summary>
    internal static class DocumentContext
    {
        /// <summary>
        /// About 25,000 tokens at four characters a token: roughly what Trados's
        /// 500 segments come to on a patent. Characters rather than rows, because
        /// a row from the live link is a paragraph and can be three grid rows.
        /// </summary>
        internal const int NormalChars = 100000;

        /// <summary>
        /// About 200,000 tokens, the length of a book: the "Send long documents
        /// whole" box. Not the model's limit - every recommended cloud model holds
        /// a million - but a bound, so a document of 50,000 paragraphs cannot
        /// quietly cost dollars a request.
        /// </summary>
        internal const int WholeChars = 800000;

        /// <summary>
        /// Captured text shorter than this is not sent, and it is the first
        /// doubling point - the same 500 characters the memory bank's selection
        /// counts its doublings from (EngineContext.GrowthStep).
        /// </summary>
        internal const int FirstStepChars = 500;

        /// <summary>What a build produced, for the log line that announces it.</summary>
        internal sealed class Result
        {
            public string Text;

            /// <summary>Rows the document had to offer: the live link's paragraphs with text, or every captured row.</summary>
            public int Available;

            /// <summary>Rows in the block.</summary>
            public int Sent;

            /// <summary>Rows left out by the 80/20 cut, between the start and the end.</summary>
            public int Omitted;
        }

        /// <summary>
        /// The rows' length as the memory bank measures the document - tags cut
        /// out, rows joined by a line break - so the two rebuild at the same
        /// doubling, and a large bank's new selection and a longer document cost
        /// one cache write between them, not two.
        /// </summary>
        internal static long Measure(IList<string> rows)
        {
            if (rows == null || rows.Count == 0) return 0;
            long length = rows.Count - 1;
            foreach (var row in rows) length += TagBridge.StripTagMarkers(row).Length;
            return length;
        }

        /// <summary>Which doubling of the text this is: -1 under 500 characters, 0 up to 1,000, 1 up to 2,000…</summary>
        internal static int Step(long length) =>
            length < FirstStepChars ? -1 : (int)Math.Floor(Math.Log(length / (double)FirstStepChars, 2));

        /// <summary>
        /// The captured rows to send: the shortest run from the start that
        /// reaches the current doubling point (500, 1,000, 2,000… characters).
        ///
        /// <para>Captured rows only ever grow at the end, so every engine, at any
        /// moment within one doubling, cuts at the same row and builds the same
        /// bytes. Sending "whatever had arrived when this engine looked" would
        /// give memoQ's two engines per language pair two different blocks, and
        /// every switch between them a cache write. The cost is that the block
        /// holds between half and all of what has been captured: the doubling
        /// point is never more than the text, and never less than half of it.</para>
        /// </summary>
        internal static List<string> CapturedPrefix(IList<string> rows)
        {
            var prefix = new List<string>();
            var step = Step(Measure(rows));
            if (step < 0) return prefix;

            var boundary = (long)FirstStepChars << step;
            long used = -1;   // no line break before the first row
            foreach (var row in rows)
            {
                if (used >= boundary) break;
                used += 1 + TagBridge.StripTagMarkers(row).Length;
                prefix.Add(row);
            }
            return prefix;
        }

        /// <summary>
        /// The block for <paramref name="rows"/> - the live link's paragraphs, or
        /// memoQ's captured segments - or null when there is nothing to send.
        ///
        /// <para>Past <paramref name="maxChars"/> it keeps the first 80% and the
        /// last 20%, with a line saying how many rows were left out between: the
        /// cut Trados makes, by characters instead of segments. On a patent the
        /// end is the claims and the abstract.</para>
        /// </summary>
        internal static Result Build(IList<string> rows, bool liveLink, int maxChars)
        {
            rows = rows ?? new List<string>();
            var source = liveLink ? rows : CapturedPrefix(rows);

            // Tags out and escapes undone: the model reads text, and the live link
            // and memoQ's segment XML then read the same.
            var texts = source
                .Select(r => StagedTranslations.Loose(r).Trim())
                .Where(t => t.Length > 0)
                .ToList();
            if (texts.Count == 0) return null;

            // Each row as it is written: "12. text" and a line break. The limit is
            // what the model reads, numbers included.
            long Line(int i) => (i + 1).ToString(System.Globalization.CultureInfo.InvariantCulture).Length
                                + 2 + texts[i].Length + Environment.NewLine.Length;

            var head = texts.Count;
            var tail = 0;
            if (Enumerable.Range(0, texts.Count).Sum(i => Line(i)) > maxChars)
            {
                var headBudget = maxChars * 4L / 5;
                var tailBudget = maxChars - headBudget;

                head = 0;
                for (long used = 0; head < texts.Count && used + Line(head) <= headBudget; head++)
                    used += Line(head);

                for (long used = 0; tail < texts.Count - head && used + Line(texts.Count - 1 - tail) <= tailBudget; tail++)
                    used += Line(texts.Count - 1 - tail);

                // The first paragraph too long for 80% and the last for 20%:
                // nothing fits, and half a paragraph is not worth sending.
                if (head == 0 && tail == 0) return null;
            }

            var omitted = texts.Count - head - tail;
            var rowWord = liveLink ? "paragraphs" : "segments";

            var sb = new StringBuilder();
            sb.AppendLine("# DOCUMENT CONTENT");

            // Core's own words (TranslationPrompt.BuildSystemPrompt), so a library
            // prompt written for Trados's block finds the same one here.
            sb.AppendLine("The following is the source document content. Analyze it to determine the document type");
            sb.AppendLine("(legal, medical, technical, marketing, financial, patent, scientific, etc.) and use that");
            sb.AppendLine("assessment to inform your translation style, terminology choices, and register.");

            // memoQ's own. A live-link row is a paragraph, so its number never
            // matches the grid, and a comment citing it would send the translator
            // to the wrong row.
            sb.AppendLine(liveLink
                ? "Each numbered line is one paragraph of the document."
                : "Each numbered line is one segment, in the order memoQ sent them; the list may stop before the end of the document.");
            sb.AppendLine("The numbers are positions in this list, not memoQ's row numbers, so never cite them.");
            sb.AppendLine();

            DocumentContent.AppendNumbered(sb, Numbered(texts, 0, head));
            if (omitted > 0)
            {
                sb.AppendLine();
                sb.Append("[... ").Append(omitted).Append(' ').Append(rowWord).AppendLine(" omitted ...]");
                sb.AppendLine();
                DocumentContent.AppendNumbered(sb, Numbered(texts, texts.Count - tail, tail));
            }

            return new Result
            {
                Text = sb.ToString().TrimEnd(),
                Available = liveLink ? texts.Count : rows.Count,
                Sent = head + tail,
                Omitted = omitted
            };
        }

        /// <summary><paramref name="count"/> rows from <paramref name="start"/>, numbered by their place in the whole list.</summary>
        private static List<DocumentSegment> Numbered(List<string> texts, int start, int count)
        {
            var list = new List<DocumentSegment>(count);
            for (var i = start; i < start + count; i++)
                list.Add(new DocumentSegment(texts[i], (i + 1).ToString(System.Globalization.CultureInfo.InvariantCulture)));
            return list;
        }
    }
}
