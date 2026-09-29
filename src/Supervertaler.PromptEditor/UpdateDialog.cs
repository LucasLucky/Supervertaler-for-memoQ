using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using Supervertaler.MemoQ.Core;

namespace Supervertaler.PromptEditor
{
    /// <summary>
    /// Offers a newer Supervertaler for memoQ (see UpdateCheck): what is new,
    /// download and install it, skip it, or decide later.
    ///
    /// <para>Installing downloads the release's installer, checks it against
    /// what GitHub lists, runs it and closes the editor - the installer replaces
    /// the editor's own file, and refuses by itself while memoQ is running, which
    /// is why memoQ is checked first rather than after a 30 MB download.</para>
    /// </summary>
    internal sealed class UpdateDialog : Form
    {
        private readonly ReleaseInfo _release;
        private readonly Label _status;
        private readonly Button _install, _notes, _skip, _later;

        /// <summary>True once the installer has been started: the editor should close.</summary>
        internal bool InstallerStarted { get; private set; }

        public UpdateDialog(ReleaseInfo release, string current)
        {
            _release = release;

            Font = Ui.Default;
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;

            Text = "Update – Supervertaler";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterParent;
            MinimizeBox = false;
            MaximizeBox = false;
            ShowInTaskbar = false;
            AppIcon.Apply(this);

            const int width = 460;
            const int margin = 14;
            const int inner = width - margin * 2;
            var y = margin;

            Label Paragraph(string text, bool bold = false, Color? colour = null)
            {
                var label = new Label { Text = text, AutoSize = true, MaximumSize = new Size(inner, 0), Location = new Point(margin, y) };
                if (bold) label.Font = new Font(Ui.Default, FontStyle.Bold);
                if (colour.HasValue) label.ForeColor = colour.Value;
                Controls.Add(label);
                y += label.Height + 8;
                return label;
            }

            Button AddButton(string text)
            {
                var b = new Button { Text = text, AutoSize = true, AutoSizeMode = AutoSizeMode.GrowAndShrink, Font = Font };
                Controls.Add(b);
                return b;
            }

            Paragraph("Supervertaler for memoQ " + release.Version + " is available.", bold: true);
            Paragraph("You have version " + current + ". To install it, close memoQ first; the installer "
                + "asks for administrator rights once, as before, and keeps your settings, prompts, "
                + "termbases, memory banks and licence.");
            _status = Paragraph(string.Empty, colour: SystemColors.GrayText);
            y += 4;

            _install = AddButton("Download and install");
            _notes = AddButton("What's new");
            _skip = AddButton("Skip this version");
            _later = AddButton("Later");

            var x = margin;
            foreach (var b in new[] { _install, _notes, _skip, _later })
            {
                b.Location = new Point(x, y);
                x = b.Right + 8;
            }

            ClientSize = new Size(Math.Max(width, x + margin - 8), _install.Bottom + margin);
            AcceptButton = _install;
            CancelButton = _later;

            _install.Click += async (s, e) => await InstallAsync();
            _notes.Click += (s, e) => Open(_release.NotesUrl);
            _skip.Click += (s, e) =>
            {
                SharedSettings.UpdateSkipped = _release.Version;
                DialogResult = DialogResult.Cancel;
            };
            _later.Click += (s, e) => DialogResult = DialogResult.Cancel;
        }

        private async System.Threading.Tasks.Task InstallAsync()
        {
            if (Process.GetProcessesByName("memoQ").Length > 0)
            {
                MessageBox.Show(this,
                    "Please close memoQ first. The installer replaces files memoQ keeps open while it runs.",
                    Text, MessageBoxButtons.OK, MessageBoxIcon.Information);
                return;
            }

            foreach (var b in new[] { _install, _notes, _skip, _later }) b.Enabled = false;
            _status.Text = "Downloading the installer…";

            var path = Path.Combine(Path.GetTempPath(), "Supervertaler-for-memoQ-Setup-" + _release.Version + ".exe");
            var problem = await UpdateCheck.DownloadAsync(_release, path);

            if (problem != null)
            {
                _status.Text = string.Empty;
                foreach (var b in new[] { _install, _notes, _skip, _later }) b.Enabled = true;
                MessageBox.Show(this,
                    "The update could not be installed: " + problem + ".\r\n\r\n"
                    + "You can download it yourself from supervertaler.com/download/memoq.",
                    Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            try
            {
                Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
                InstallerStarted = true;
                DialogResult = DialogResult.OK;
            }
            catch (Exception ex)
            {
                // Declining the administrator prompt lands here too.
                _status.Text = string.Empty;
                foreach (var b in new[] { _install, _notes, _skip, _later }) b.Enabled = true;
                MessageBox.Show(this, "The installer did not start: " + ex.Message, Text,
                    MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void Open(string url)
        {
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
            catch { /* no browser to hand it to: nothing more to do */ }
        }
    }
}
