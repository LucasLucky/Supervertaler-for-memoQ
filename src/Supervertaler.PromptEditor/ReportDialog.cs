using System;
using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace Supervertaler.PromptEditor
{
    /// <summary>
    /// A report with a documentation page behind it: the text, an OK button,
    /// and the title bar's "?" (and F1) opening the page.
    ///
    /// <para>Not a message box, for two reasons. A message box cannot carry
    /// the title-bar "?", which is how the Trados plugin's dialogs reach their
    /// documentation. And a message box grows with its text until it runs off
    /// the screen; this one shows the text in a box that scrolls past a set
    /// height, so a report on thirty files is as usable as one on a single
    /// file.</para>
    /// </summary>
    internal sealed class ReportDialog : Form
    {
        private readonly string _docsUrl;

        // Past this the text scrolls rather than the window growing. At 96 DPI;
        // the form scales it with everything else.
        private const int MaxTextHeight = 420;

        internal ReportDialog(string title, string text, string docsUrl)
        {
            _docsUrl = docsUrl;

            // The shell's own dialog font, before anything else is built, so
            // every control below inherits it. See Ui.Default.
            Font = Ui.Default;
            AutoScaleDimensions = new SizeF(96F, 96F);
            AutoScaleMode = AutoScaleMode.Dpi;

            Text = title;
            FormBorderStyle = FormBorderStyle.FixedDialog;
            StartPosition = FormStartPosition.CenterParent;

            // The title bar shows "?" only on a window with neither a minimise
            // nor a maximise button.
            MinimizeBox = false;
            MaximizeBox = false;
            HelpButton = true;
            ShowInTaskbar = false;
            AppIcon.Apply(this);

            // Pressed, the "?" would normally turn the pointer into a question
            // mark waiting for a control to be clicked. Cancelling that and
            // opening the page is what the Trados dialogs do.
            HelpButtonClicked += (s, e) =>
            {
                e.Cancel = true;
                OpenDocs();
            };
            HelpRequested += (s, e) =>
            {
                e.Handled = true;
                OpenDocs();
            };

            // Width is a choice, height is measured, as in the other dialogs.
            const int width = 560;
            const int margin = 14;
            const int inner = width - margin * 2;

            // Read-only text in a borderless box rather than a label: it scrolls
            // when it is long, and the steps can be selected and copied. Given
            // the full height here; FitText sizes it once it exists.
            var body = new TextBox
            {
                Text = text.Replace("\r\n", "\n").Replace("\n", "\r\n"),
                Multiline = true,
                ReadOnly = true,
                WordWrap = true,
                BorderStyle = BorderStyle.None,
                BackColor = BackColor,
                TabStop = false,
                ScrollBars = ScrollBars.None,
                Location = new Point(margin, margin),
                Size = new Size(inner, MaxTextHeight),
            };
            Controls.Add(body);

            var ok = new Button
            {
                Text = "OK",
                DialogResult = DialogResult.OK,
                AutoSize = true,
                AutoSizeMode = AutoSizeMode.GrowAndShrink,
            };
            ok.Size = new Size(Math.Max(ok.PreferredSize.Width, 84), ok.PreferredSize.Height);
            ok.Location = new Point(width - margin - ok.Width, body.Bottom + 12);
            Controls.Add(ok);

            AcceptButton = ok;
            CancelButton = ok;
            ClientSize = new Size(width, ok.Bottom + margin);

            Load += (s, e) => FitText(body, ok);

            // Not the text box: focus there would show a caret in text that
            // cannot be edited, and select it all.
            Shown += (s, e) => ok.Focus();
        }

        /// <summary>
        /// Makes the box exactly as tall as the lines the text has wrapped
        /// into, or <see cref="MaxTextHeight"/> with a scroll bar when they do
        /// not fit, and moves the button and the window's bottom with it.
        ///
        /// <para>Measured in the box itself, once it exists, rather than
        /// estimated beforehand: the estimate was a line out, and a line over
        /// showed a scroll bar with nothing to scroll (2026-10-23). A line under
        /// would have cut the last line off with no scroll bar to reach it.
        /// The line height is the box's own too: it set lines 15 px apart in a
        /// font whose Height is 16, and counting 16 left an empty line under a
        /// seventeen-line report.</para>
        /// </summary>
        private void FitText(TextBox body, Button ok)
        {
            var cap = LogicalToDeviceUnits(MaxTextHeight);
            body.ScrollBars = ScrollBars.None;

            // The last line's top, from the box's own layout, plus one line.
            var last = Math.Max(0, body.TextLength - 1);
            var lines = body.GetLineFromCharIndex(last) + 1;
            var lastTop = body.GetPositionFromCharIndex(last).Y - body.GetPositionFromCharIndex(0).Y;
            var lineHeight = lines > 1 ? lastTop / (lines - 1) : body.Font.Height;
            var needed = lastTop + lineHeight + LogicalToDeviceUnits(2);

            // Wrapped at the narrower width a scroll bar leaves, the text is
            // longer still, so past the cap the box simply scrolls.
            if (needed > cap) body.ScrollBars = ScrollBars.Vertical;

            var change = Math.Min(needed, cap) - body.Height;
            body.Height += change;
            ok.Top += change;
            ClientSize = new Size(ClientSize.Width, ClientSize.Height + change);
        }

        private void OpenDocs()
        {
            try
            {
                Process.Start(new ProcessStartInfo(_docsUrl) { UseShellExecute = true });
            }
            catch (Exception ex)
            {
                MessageBox.Show(this, "The documentation could not be opened: " + ex.Message + "\r\n\r\n" + _docsUrl,
                    Text, MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }
    }
}
