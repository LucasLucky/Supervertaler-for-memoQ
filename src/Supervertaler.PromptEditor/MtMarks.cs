using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using Supervertaler.Core;

namespace Supervertaler.PromptEditor
{
    /// <summary>
    /// Removes the machine-translation marks from a memoQ XLIFF that memoQ
    /// exported: an .mqxliff, or an .mqxlz, the zip memoQ writes when the
    /// export includes the skeleton.
    ///
    /// <para><b>What memoQ keeps.</b> Every MT hit inserted into a row is stored
    /// with the row as its inserted match, <c>&lt;mq:insertedmatch
    /// matchtype="1" source="MT / Supervertaler"&gt;</c>, holding the MT output
    /// as it arrived. It survives editing and confirming, and it is what the
    /// Review pane, the edit distance report and the bilingual exports show. A
    /// row typed by hand has none, and retyping a row does not clear it
    /// (measured 2026-10-23, memoQ 12).</para>
    ///
    /// <para><b>Every engine's marks go</b>, not only Supervertaler's: a row
    /// filled from DeepL or memoQ's own AGT carries the same record with
    /// another name in it. The result counts them by engine, so the translator
    /// sees what was removed.</para>
    ///
    /// <para><b>Edited as text, never parsed and written back as XML.</b> A
    /// serializer would rewrite quoting, whitespace and namespace declarations
    /// throughout a file memoQ has to read back in. The marks are the only
    /// thing that changes, byte for byte.</para>
    ///
    /// <para><b>Back into memoQ, the clean file is not an update.</b> Imported
    /// over the existing document, memoQ takes the rows' statuses but keeps
    /// their old inserted matches, and adds a history version holding them.
    /// The document has to be removed and the clean file imported as new;
    /// memoQ then keeps the document's id and every segment's (measured
    /// 2026-10-23). The editor's message says so.</para>
    /// </summary>
    internal static class MtMarks
    {
        internal sealed class Result
        {
            /// <summary>Marks removed, from rows and from earlier versions of rows.</summary>
            public int Removed;

            /// <summary>Rows, or earlier versions, whose status went from Machine translated to Edited.</summary>
            public int StatusesChanged;

            /// <summary>Marks removed, counted by memoQ's name for the engine ("MT / DeepL MT Plugin").</summary>
            public readonly SortedDictionary<string, int> Engines = new SortedDictionary<string, int>(StringComparer.Ordinal);

            /// <summary>Where the clean copy was written; null when there was nothing to remove.</summary>
            public string WrittenTo;

            /// <summary>An .mqxlz, which carries the skeleton memoQ needs to import the document again.</summary>
            public bool Packaged;
        }

        private static readonly Regex TransUnit =
            new Regex(@"<trans-unit\b.*?</trans-unit>", RegexOptions.Singleline | RegexOptions.Compiled);

        private static readonly Regex MinorVersions =
            new Regex(@"<mq:minorversions\b.*?</mq:minorversions>", RegexOptions.Singleline | RegexOptions.Compiled);

        private static readonly Regex HistoricalUnit =
            new Regex(@"<mq:historical-unit\b.*?</mq:historical-unit>", RegexOptions.Singleline | RegexOptions.Compiled);

        // Self-closing in older exports; memoQ 12 nests the inserted source and
        // target inside it. The indentation before it and the line break after
        // it go too, so the unit reads as though it had never had one.
        private static readonly Regex InsertedMatch =
            new Regex(@"[ \t]*<mq:insertedmatch\b([^>]*?)(?:/>|>.*?</mq:insertedmatch>)[ \t]*(?:\r?\n)?",
                RegexOptions.Singleline | RegexOptions.Compiled);

        // Stands in for a row's earlier versions while the row itself is
        // cleaned. A control character, which XML cannot contain.
        private const string VersionsPlaceholder = "\u0001versions\u0001";

        // Strict, so a file that is not valid UTF-8 is refused rather than
        // written back with replacement characters where its text was.
        private static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);

        /// <summary>
        /// Cleans <paramref name="path"/> into a copy beside it, named with
        /// " (clean)" (<see cref="CleanPath"/>), and never changes the original.
        /// Writes nothing when the file holds no MT marks. Throws
        /// <see cref="InvalidDataException"/> for a file that is not a memoQ
        /// XLIFF, and <see cref="IOException"/> when the copy cannot be written.
        /// </summary>
        internal static Result Clean(string path)
        {
            var bytes = AtomicFile.ReadAllBytes(path);
            var result = new Result { Packaged = IsZip(bytes) };

            var output = result.Packaged
                ? CleanPackage(bytes, result)
                : CleanDocument(bytes, result, Path.GetFileName(path));

            if (result.Removed == 0)
                return result;

            var target = CleanPath(path);
            string why = null;
            if (AtomicFile.Write(target, output, replaceExisting: true, log: m => why = m) != AtomicFile.Outcome.Written)
                throw new IOException(why ?? Path.GetFileName(target) + " could not be written.");

            result.WrittenTo = target;
            return result;
        }

        internal static string CleanPath(string path) =>
            Path.Combine(Path.GetDirectoryName(path) ?? "",
                Path.GetFileNameWithoutExtension(path) + " (clean)" + Path.GetExtension(path));

        /// <summary>memoQ's name for an engine as a translator would say it: "DeepL MT Plugin", not "MT / DeepL MT Plugin".</summary>
        internal static string EngineLabel(string source) =>
            source.StartsWith("MT / ", StringComparison.Ordinal) ? source.Substring(5) : source;

        /// <summary>The memoQ XLIFF text with its MT marks removed, counted into <paramref name="result"/>.</summary>
        internal static string CleanText(string text, Result result) =>
            TransUnit.Replace(text, m => CleanTransUnit(m.Value, result));

        private static string CleanTransUnit(string unit, Result result)
        {
            // A row's earlier versions sit inside it, each a unit with a status
            // and an inserted match of its own. They are cleaned one by one and
            // set aside, so that what is left is the row itself.
            string versions = null;
            var row = MinorVersions.Replace(unit, m =>
            {
                versions = HistoricalUnit.Replace(m.Value, h => CleanUnit(h.Value, result));
                return VersionsPlaceholder;
            }, 1);

            var cleaned = CleanUnit(row, result);
            return versions == null ? cleaned : cleaned.Replace(VersionsPlaceholder, versions);
        }

        /// <summary>One row, or one earlier version of a row. Its opening tag comes first.</summary>
        private static string CleanUnit(string unit, Result result)
        {
            var removed = false;
            var cleaned = InsertedMatch.Replace(unit, m =>
            {
                // matchtype 0 is a TM or LiveDocs match, which stays.
                if (Attribute(m.Groups[1].Value, "matchtype") != "1")
                    return m.Value;

                var source = Attribute(m.Groups[1].Value, "source") ?? "";
                result.Engines.TryGetValue(source, out var count);
                result.Engines[source] = count + 1;
                result.Removed++;
                removed = true;
                return "";
            });

            if (!removed)
                return unit;

            // A row not yet confirmed also says Machine translated in its
            // status, which would give it away on its own. Edited is what memoQ
            // shows for a row someone has typed into and not yet confirmed.
            var headEnd = cleaned.IndexOf('>') + 1;
            var head = cleaned.Substring(0, headEnd);
            var newHead = head.Replace("mq:status=\"MachineTranslated\"", "mq:status=\"PartiallyEdited\"");
            if (newHead == head)
                return cleaned;

            result.StatusesChanged++;
            return newHead + cleaned.Substring(headEnd);
        }

        private static string Attribute(string attributes, string name)
        {
            var m = Regex.Match(attributes, @"\b" + Regex.Escape(name) + "=\"([^\"]*)\"");
            return m.Success ? WebUtility.HtmlDecode(m.Groups[1].Value) : null;
        }

        /// <summary>One .mqxliff, as bytes. Returns the input itself when there was nothing to remove.</summary>
        private static byte[] CleanDocument(byte[] bytes, Result result, string name)
        {
            var bom = bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF;
            var start = bom ? 3 : 0;

            string text;
            try
            {
                text = Utf8.GetString(bytes, start, bytes.Length - start);
            }
            catch (DecoderFallbackException)
            {
                throw new InvalidDataException(name + " is not a memoQ XLIFF file: it is not valid UTF-8 text.");
            }

            if (text.IndexOf("xmlns:mq=\"MQXliff\"", StringComparison.Ordinal) < 0)
                throw new InvalidDataException(name + " is not a memoQ XLIFF file.");

            var removedBefore = result.Removed;
            var cleaned = CleanText(text, result);
            if (result.Removed == removedBefore)
                return bytes;

            var body = Utf8.GetBytes(cleaned);
            if (!bom)
                return body;

            var withBom = new byte[body.Length + 3];
            withBom[0] = 0xEF; withBom[1] = 0xBB; withBom[2] = 0xBF;
            Buffer.BlockCopy(body, 0, withBom, 3, body.Length);
            return withBom;
        }

        /// <summary>
        /// An .mqxlz: the document, its skeleton, and earlier major versions
        /// under Versions/, every .mqxliff among them cleaned.
        /// </summary>
        private static byte[] CleanPackage(byte[] bytes, Result result)
        {
            var entries = ReadEntries(bytes);
            if (!entries.Any(e => IsDocument(e.Name)))
                throw new InvalidDataException("This .mqxlz holds no memoQ XLIFF document.");

            // Every entry is written afresh. memoQ's own zips carry a Zip64
            // field with each entry's sizes, and memoQ's zip reader believes that
            // field over everything else: an entry that kept its old header
            // after its content changed was refused with "Size mismatch between
            // central header and local header" (2026-10-23).
            var output = new MemoryStream();
            using (var zip = new ZipArchive(output, ZipArchiveMode.Create, true))
            {
                foreach (var entry in entries)
                {
                    var data = IsDocument(entry.Name) ? CleanDocument(entry.Data, result, entry.Name) : entry.Data;
                    var copy = zip.CreateEntry(entry.Name, CompressionLevel.Optimal);
                    copy.LastWriteTime = entry.LastWriteTime;
                    using (var stream = copy.Open())
                        stream.Write(data, 0, data.Length);
                }
            }
            return output.ToArray();
        }

        private static List<(string Name, DateTimeOffset LastWriteTime, byte[] Data)> ReadEntries(byte[] bytes)
        {
            var entries = new List<(string, DateTimeOffset, byte[])>();
            try
            {
                using (var zip = new ZipArchive(new MemoryStream(bytes), ZipArchiveMode.Read))
                {
                    foreach (var entry in zip.Entries)
                    {
                        using (var stream = entry.Open())
                        using (var buffer = new MemoryStream())
                        {
                            stream.CopyTo(buffer);
                            entries.Add((entry.FullName, entry.LastWriteTime, buffer.ToArray()));
                        }
                    }
                }
            }
            catch (InvalidDataException ex)
            {
                throw new InvalidDataException("This .mqxlz is damaged and cannot be read: " + ex.Message, ex);
            }
            return entries;
        }

        private static bool IsDocument(string entryName) =>
            entryName.EndsWith(".mqxliff", StringComparison.OrdinalIgnoreCase);

        private static bool IsZip(byte[] bytes) =>
            bytes.Length >= 4 && bytes[0] == (byte)'P' && bytes[1] == (byte)'K' && bytes[2] == 3 && bytes[3] == 4;
    }
}
