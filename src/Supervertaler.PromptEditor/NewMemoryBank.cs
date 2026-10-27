using System.Windows.Forms;
using Supervertaler.Core;
using Supervertaler.MemoQ.Core;

namespace Supervertaler.PromptEditor
{
    /// <summary>
    /// Making a memory bank.
    ///
    /// <para>This existed only inside the FigureLens images dialog, offered as a
    /// link when a project had no bank and an image needed one. So the answer to
    /// "how do I start a bank for this job" was to open an unrelated dialog and
    /// notice a link that is hidden once a bank exists. Starting a new project -
    /// the moment you most want a fresh bank - was the one case with no route to
    /// it at all, short of making the folder by hand.</para>
    ///
    /// <para>The folder layout and the skeleton files are core's, so a bank made
    /// here is the same as one made by Trados or Workbench. The making itself is
    /// <see cref="BankFolder"/>, shared with the start-up that makes the shared
    /// bank.</para>
    /// </summary>
    internal static class NewMemoryBank
    {
        /// <summary>
        /// Asks for a name, creates the bank and returns the folder's own name,
        /// or null if the user changed their mind or it could not be made.
        ///
        /// <para>Defaults to the open memoQ project's name, which is the answer
        /// nine times in ten and the reason the FigureLens link only ever offered
        /// that one. It is a default here, not the only choice.</para>
        ///
        /// <para>The answer can be <c>_shared</c>, if that is what was typed. The
        /// caller must not record that as the project's bank: check
        /// <see cref="MemoryBanks.IsSharedName"/>.</para>
        /// </summary>
        public static string Ask(IWin32Window owner)
        {
            var suggestion = MemoryBanks.Sanitize((SharedSettings.MemoryBankProjectName ?? "").Trim());

            string raw;
            using (var ask = new TextInputDialog(
                "New memory bank",
                "A name for this client or project. An existing name reuses that bank; "
                + "nothing already written in it is overwritten.",
                suggestion))
            {
                if (ask.ShowDialog(owner) != DialogResult.OK) return null;
                raw = ask.Value;
            }

            if (raw == null) return null;

            var made = BankFolder.Create(MemoryBanks.Root, raw, out var error);
            if (made == null)
                MessageBox.Show(owner, error, "New memory bank", MessageBoxButtons.OK, MessageBoxIcon.Warning);

            return made;
        }
    }
}
