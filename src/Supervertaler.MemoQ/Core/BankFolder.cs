using System;
using System.IO;
using System.Linq;
using System.Text;
using Supervertaler.Core;

namespace Supervertaler.MemoQ.Core
{
    /// <summary>
    /// Making a memory bank's folder, and making sure the shared bank exists.
    ///
    /// <para>In the plugin rather than the editor because both need it: the
    /// editor's New memory bank makes client banks, and both make the shared
    /// one at start-up. Compiled into the editor as a link, like
    /// <see cref="DefaultPrompts"/>.</para>
    /// </summary>
    internal static class BankFolder
    {
        private static readonly string[] Files = { "brief.md", "terminology.md", "style.md" };

        /// <summary>
        /// Makes the shared bank when there is none, so nobody has to know it
        /// is a folder they must create by hand. Until 2026-10-23 nothing did,
        /// in either product, and the only route was File Explorer.
        ///
        /// <para>Only when the folder is missing. A bank that exists is the
        /// translator's, and a file they deleted from it stays deleted.</para>
        ///
        /// <para>Costs no tokens: the files are core's skeletons, and the reader
        /// leaves out a file that is still exactly one, so the bank adds nothing
        /// to a prompt until someone writes in it.</para>
        ///
        /// <para>Called by the plugin when memoQ loads it, in the background,
        /// and by the editor before its window is built. Never under a harness,
        /// which must not write the translator's real banks.</para>
        /// </summary>
        public static void EnsureShared(Action<string> log)
        {
            if (SharedSettings.InHarness) return;
            EnsureShared(MemoryBanks.Root, SupervertalerPaths.Root, log);
        }

        /// <summary><see cref="EnsureShared(Action{string})"/> under a given banks
        /// folder and data folder, for tests.</summary>
        internal static void EnsureShared(string root, string dataRoot, Action<string> log)
        {
            try
            {
                if (string.IsNullOrEmpty(root)) return;
                if (Directory.Exists(Path.Combine(root, MemoryBankReader.SharedBankName))) return;

                // Supervertaler for Trados offers to move a bank from before
                // there were several (memory-bank\ or supermemory\ in the data
                // folder) into memory-banks\, but only while memory-banks\ does
                // not exist. Making _shared first would end that offer for good
                // and leave the old bank sending nothing. Trados waits for it
                // too (dd5e71d); once it is moved, the next start makes _shared.
                var legacy = Directory.Exists(root) ? null : LegacyBank(dataRoot);
                if (legacy != null)
                {
                    log?.Invoke("Not making the shared memory bank yet: " + legacy
                        + " is waiting to be moved into memory banks by Supervertaler for Trados.");
                    return;
                }

                var made = Create(root, MemoryBankReader.SharedBankName, out var error);
                log?.Invoke(made != null
                    ? "Made the shared memory bank at " + Path.Combine(root, made)
                    : "Could not make the shared memory bank: " + error);
            }
            catch (Exception ex)
            {
                // Never worth failing a start over: without the folder the shared
                // bank simply contributes nothing, which is what it does empty.
                log?.Invoke("Could not make the shared memory bank: " + ex.Message);
            }
        }

        /// <summary>The old single bank Trados has yet to move, or null. The same
        /// two folders Trados's <c>LegacySingleBankPath</c> looks for.</summary>
        private static string LegacyBank(string dataRoot)
        {
            if (string.IsNullOrEmpty(dataRoot)) return null;

            foreach (var name in new[] { "memory-bank", "supermemory" })
            {
                var dir = Path.Combine(dataRoot, name);
                if (Directory.Exists(dir)) return dir;
            }
            return null;
        }

        /// <summary>
        /// Creates the bank under <paramref name="root"/>, writing only the files
        /// that are missing, and returns the folder's own name - for a bank that
        /// already existed, however it is actually spelt. Null, with
        /// <paramref name="error"/> set, when it could not be made.
        ///
        /// <para><c>_shared</c> keeps its name. The sanitiser strips a leading
        /// underscore, so asking for the shared bank used to make an ordinary
        /// bank called "shared", which is never sent as the shared one.</para>
        /// </summary>
        internal static string Create(string root, string rawName, out string error)
        {
            error = null;

            var name = MemoryBanks.IsSharedName(rawName)
                ? MemoryBankReader.SharedBankName
                : MemoryBanks.Sanitize((rawName ?? "").Trim());
            if (name.Length == 0)
            {
                error = "That name has nothing in it that can be used for a folder.";
                return null;
            }

            var dir = Path.Combine(root, name);

            try
            {
                // Windows matches the existing folder whatever its case, and this
                // returns it as it is spelt on disk.
                if (Directory.Exists(root))
                    dir = Directory.GetDirectories(root, name).FirstOrDefault() ?? dir;

                Directory.CreateDirectory(dir);
                Directory.CreateDirectory(Path.Combine(dir, "reference"));

                // Core's skeletons, named for the folder as it is spelt: the
                // reader recognises an untouched one by the name in it, and
                // leaves it out of the prompt.
                var folder = Path.GetFileName(dir);
                foreach (var f in Files)
                    WriteIfMissing(Path.Combine(dir, f), MemoryBanks.SkeletonBody(f, folder));
            }
            catch (Exception ex)
            {
                error = "Could not create the memory bank folder:" + Environment.NewLine + dir
                    + Environment.NewLine + Environment.NewLine + ex.Message;
                return null;
            }

            return Path.GetFileName(dir);
        }

        /// <summary>
        /// Writes the file only if it does not exist, in one step. memoQ and the
        /// editor both make the shared bank at start-up, and in a team folder so
        /// does everyone else; a check followed by a write could put a skeleton
        /// over a file someone else had just written.
        /// </summary>
        private static void WriteIfMissing(string path, string text)
        {
            try
            {
                using (var stream = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                {
                    var bytes = new UTF8Encoding(false).GetBytes(text);
                    stream.Write(bytes, 0, bytes.Length);
                }
            }
            catch (IOException) when (File.Exists(path))
            {
                // Someone was first. Theirs stands.
            }
        }
    }
}
