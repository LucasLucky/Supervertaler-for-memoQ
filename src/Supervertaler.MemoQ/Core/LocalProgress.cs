using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using Supervertaler.MemoQ.Settings;

namespace Supervertaler.MemoQ.Core
{
    /// <summary>
    /// A notice in the corner of memoQ while a model on the translator's own
    /// computer is working, saying that it is and how far it has got.
    ///
    /// <para>memoQ shows only a spinning circle while it waits for an MT answer,
    /// and on a computer without a graphics card the first segment of a document
    /// can take ten minutes: the model reads Supervertaler's whole prompt once
    /// (measured 2026-10-12: 13,903 tokens at about 20 a second) and reuses it
    /// for every segment after. A translator watching the circle has every
    /// reason to think it has hung and move on - Michael did, testing it.</para>
    ///
    /// <para>Ollama writes its progress through a prompt to its own log, every
    /// 1,024 tokens. When that log is on this computer the notice reads it and
    /// shows the share read and the time left; otherwise it shows how long the
    /// wait has lasted. Reading the log is a courtesy, never a dependency: a
    /// line it does not recognise means no percentage, nothing else.</para>
    ///
    /// <para>One notice for however many requests are waiting, on a thread of
    /// its own, never taking the focus, and shown only while memoQ is the
    /// window in front - a ten-minute wait should not float over other
    /// programs. It appears after <see cref="Delay"/>, so a quick answer
    /// never shows it, and closes when the last request is answered. A click
    /// hides it until the next wait; its Stop link ends the wait altogether
    /// (<see cref="LocalServer.Stop"/>).</para>
    ///
    /// <para>It names the segment the model is on, with that segment's own
    /// clock: with memoQ fetching rows ahead, a clock that had run since the
    /// first segment - eighteen minutes, on 2026-10-13 - said nothing about the
    /// one the translator was looking at. And it says when an answer
    /// arrives that memoQ has probably stopped showing: memoQ gives up on a
    /// slow lookup, an answer after that never reaches the grid, and the
    /// translator has no way to know it is there - in the cache, a click away.
    /// </para>
    /// </summary>
    internal static class LocalProgress
    {
        private static readonly TimeSpan Delay = TimeSpan.FromSeconds(8);

        /// <summary>How many tokens Ollama reads between two progress lines in its log.</summary>
        private const int ChunkTokens = 1024;

        /// <summary>
        /// After this long, memoQ has probably stopped waiting for the answer and
        /// will not show it until the translator lands on the segment again.
        /// Seen 2026-10-13: answers after several minutes never reached the grid,
        /// and clicking away and back showed them at once, from the cache.
        /// </summary>
        private static readonly TimeSpan ReadyAfter = TimeSpan.FromMinutes(3);

        /// <summary>How long "ready" is shown, counted only while memoQ is in front.</summary>
        private const int ReadySeconds = 20;

        /// <summary>How much of a segment the notice quotes.</summary>
        private const int LabelChars = 40;

        private static readonly object Lock = new object();
        private static int _waiting;
        private static DateTime _since;
        private static string _provider;
        private static string _model;
        private static string _logPath;
        private static long _logFrom;
        private static object _notice;
        private static bool _dismissed;

        /// <summary>The requests the server is working on now, oldest first.</summary>
        private static readonly System.Collections.Generic.List<Work> Running =
            new System.Collections.Generic.List<Work>();

        /// <summary>A segment whose answer came after memoQ stopped waiting, or null.</summary>
        private static string _ready;
        private static int _readyShown;

        /// <summary>
        /// A request has started waiting on a local server. Dispose the result
        /// when it is answered, whatever the answer was: a count that is not
        /// brought down on a failure keeps the notice up for good.
        /// </summary>
        public static IDisposable Begin(SupervertalerGeneralSettings general)
        {
            object token = null;
            lock (Lock)
            {
                _waiting++;
                if (_waiting == 1)
                {
                    // A new wait, after none: its own clock, and only the log
                    // written from now on, so an earlier request's progress
                    // cannot be shown as this one's.
                    _since = DateTime.UtcNow;
                    _provider = general.Provider;
                    _model = general.Model;
                    _logPath = OllamaLogFor(general);
                    _logFrom = LengthOf(_logPath);
                    _dismissed = false;
                }

                if (_notice == null)
                {
                    _notice = new object();
                    token = _notice;
                }
            }

            if (token != null) StartNotice(token);
            return new Ending();
        }

        /// <summary>
        /// The server has started on a request - it has its place and is being
        /// sent. Dispose it however the request ends; call
        /// <see cref="Work.Answered"/> first when it was answered.
        /// </summary>
        public static Work Working(string label)
        {
            var work = new Work(label);
            lock (Lock) Running.Add(work);
            return work;
        }

        internal sealed class Work : IDisposable
        {
            internal readonly string Label;
            internal readonly DateTime Since = DateTime.UtcNow;
            private int _done;

            internal Work(string label) { Label = label; }

            /// <summary>
            /// The answer is in. When someone was looking at a segment and memoQ
            /// asked for it long enough ago that it has probably stopped waiting,
            /// the notice says the translation is ready and how to see it.
            /// </summary>
            public void Answered(bool interactive, DateTime asked)
            {
                if (Label == null || !interactive || DateTime.UtcNow - asked < ReadyAfter) return;
                lock (Lock)
                {
                    _ready = Label;
                    _readyShown = 0;
                    // News, so it is shown even after a click hid the waiting.
                    _dismissed = false;
                }
            }

            public void Dispose()
            {
                if (Interlocked.Exchange(ref _done, 1) == 1) return;
                lock (Lock) Running.Remove(this);
            }
        }

        /// <summary>What the notice calls a segment: its first words, quoted.</summary>
        internal static string SegmentLabel(string plainSource)
        {
            var text = System.Text.RegularExpressions.Regex.Replace(plainSource ?? string.Empty, @"\s+", " ").Trim();
            if (text.Length == 0) return null;

            if (text.Length > LabelChars)
            {
                var cut = text.LastIndexOf(' ', LabelChars);
                text = text.Substring(0, cut > LabelChars / 2 ? cut : LabelChars).TrimEnd() + "\u2026";
            }

            return "\u201C" + text + "\u201D";
        }

        /// <summary>What the notice calls a Pre-translate batch.</summary>
        internal static string BatchLabel(int segments) =>
            segments == 1 ? "1 segment for Pre-translate" : segments + " segments for Pre-translate";

        private sealed class Ending : IDisposable
        {
            private int _done;

            public void Dispose()
            {
                if (Interlocked.Exchange(ref _done, 1) == 1) return;
                lock (Lock) { _waiting = Math.Max(0, _waiting - 1); }
            }
        }

        /// <summary>
        /// The state the notice shows, or null when nothing is waiting any more -
        /// in which case the notice is marked gone in the same step, so that a
        /// request beginning a moment later starts a new one rather than relying
        /// on one that is closing.
        /// </summary>
        private static Snapshot Take(object token)
        {
            lock (Lock)
            {
                if (_waiting == 0 && _ready == null)
                {
                    Forget(token);
                    return null;
                }

                // The oldest request the server is on: with one place, the only one.
                var work = Running.Count > 0 ? Running[0] : null;
                var now = DateTime.UtcNow;

                return new Snapshot
                {
                    Waiting = _waiting,
                    Elapsed = now - _since,
                    Label = work?.Label,
                    Clock = work?.Label != null ? now - work.Since : now - _since,
                    Ready = _ready,
                    Provider = _provider,
                    Model = _model,
                    LogPath = _logPath,
                    LogFrom = _logFrom,
                    Dismissed = _dismissed
                };
            }
        }

        /// <summary>
        /// Marks this notice gone, if it is still the current one. Never a newer
        /// one's: clearing that would let the next request start a second notice
        /// beside it.
        /// </summary>
        private static void Forget(object token)
        {
            if (ReferenceEquals(_notice, token)) _notice = null;
        }

        private static void Dismiss()
        {
            lock (Lock)
            {
                _dismissed = true;
                _ready = null;
            }
        }

        /// <summary>One more second of "ready" seen; after <see cref="ReadySeconds"/> it goes.</summary>
        private static void ReadySeen()
        {
            lock (Lock)
            {
                if (_ready != null && ++_readyShown >= ReadySeconds) _ready = null;
            }
        }

        private sealed class Snapshot
        {
            public int Waiting;
            public TimeSpan Elapsed;
            public string Label;
            public TimeSpan Clock;
            public string Ready;
            public string Provider;
            public string Model;
            public string LogPath;
            public long LogFrom;
            public bool Dismissed;
        }

        // -- what Ollama's log says ------------------------------------------

        /// <summary>
        /// Ollama's own log, when the server is the one on this computer that the
        /// Ollama app started. Null for anything else: a log on another computer
        /// cannot be read, and an OpenAI-compatible server writes none we know.
        /// </summary>
        internal static string OllamaLogFor(SupervertalerGeneralSettings general)
        {
            if (!string.Equals(general.Provider, LlmProviders.Ollama, StringComparison.OrdinalIgnoreCase)) return null;
            if (LlmProviders.IsOllamaCloudModel(general.Provider, general.Model)) return null;

            if (!Uri.TryCreate(LlmProviders.OllamaAddress(general.Endpoint), UriKind.Absolute, out var uri)) return null;
            if (!uri.IsLoopback) return null;

            var path = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Ollama", "server.log");
            return File.Exists(path) ? path : null;
        }

        private static long LengthOf(string path)
        {
            if (path == null) return 0;
            try { return new FileInfo(path).Length; }
            catch { return 0; }
        }

        /// <summary>How far the server has got with the request it is working on.</summary>
        internal sealed class Reading
        {
            /// <summary>Tokens in the prompt.</summary>
            public int Total;

            /// <summary>Tokens read so far.</summary>
            public int Done;

            /// <summary>Tokens a second, as the server last measured it.</summary>
            public double Rate;

            /// <summary>The whole prompt has been read and the answer is being written.</summary>
            public bool Writing;
        }

        private static readonly Regex NewPrompt = new Regex(
            @"task (?<task>\d+) \| new prompt,.*?task\.n_tokens = (?<total>\d+)", RegexOptions.Compiled);

        private static readonly Regex Processing = new Regex(
            @"task (?<task>\d+) \| prompt processing, n_tokens = +(?<done>\d+), progress = [0-9.]+, t = +[0-9.]+ s / +(?<rate>[0-9.]+) tokens per second",
            RegexOptions.Compiled);

        /// <summary>
        /// What Ollama already had from an earlier request with the same start -
        /// read, as far as the translator is concerned. Without it the second
        /// request of a job, 13,312 of whose 13,933 tokens were cached, showed
        /// "0%" for the half minute it took (2026-10-13). The same line repeats
        /// between progress lines with the running count, which changes nothing.
        /// </summary>
        private static readonly Regex Cached = new Regex(
            @"task (?<task>\d+) \| cached n_tokens = (?<cached>\d+)", RegexOptions.Compiled);

        private static readonly Regex PromptDone = new Regex(
            @"task (?<task>\d+) \| prompt eval time", RegexOptions.Compiled);

        /// <summary>
        /// Reads the latest request's progress out of a piece of Ollama's log: its
        /// last "new prompt" line, then the last progress line for the same task,
        /// and whether reading has finished. Null when the piece holds no request.
        /// Line formats from Ollama 0.35-0.40 (llama.cpp's server); a format it
        /// does not know gives null, and the notice shows the time alone.
        /// </summary>
        internal static Reading Parse(string log)
        {
            if (string.IsNullOrEmpty(log)) return null;

            Reading reading = null;
            string task = null;

            foreach (var line in log.Split('\n'))
            {
                var m = NewPrompt.Match(line);
                if (m.Success)
                {
                    task = m.Groups["task"].Value;
                    reading = new Reading { Total = int.Parse(m.Groups["total"].Value, CultureInfo.InvariantCulture) };
                    continue;
                }

                if (reading == null) continue;

                m = Cached.Match(line);
                if (m.Success && m.Groups["task"].Value == task)
                {
                    reading.Done = Math.Max(reading.Done,
                        int.Parse(m.Groups["cached"].Value, CultureInfo.InvariantCulture));
                    continue;
                }

                m = Processing.Match(line);
                if (m.Success && m.Groups["task"].Value == task)
                {
                    reading.Done = Math.Max(reading.Done,
                        int.Parse(m.Groups["done"].Value, CultureInfo.InvariantCulture));
                    double.TryParse(m.Groups["rate"].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out reading.Rate);
                    continue;
                }

                m = PromptDone.Match(line);
                if (m.Success && m.Groups["task"].Value == task) reading.Writing = true;
            }

            return reading;
        }

        /// <summary>The log written since the wait began, at most its last 256 KB.</summary>
        private static string ReadLog(string path, long from)
        {
            if (path == null) return null;
            try
            {
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
                           FileShare.ReadWrite | FileShare.Delete))
                {
                    var length = stream.Length;
                    // A log that was started afresh is shorter than where we began.
                    var start = from <= length ? from : 0;
                    start = Math.Max(start, length - 256 * 1024);
                    stream.Seek(start, SeekOrigin.Begin);
                    using (var reader = new StreamReader(stream, Encoding.UTF8))
                        return reader.ReadToEnd();
                }
            }
            catch
            {
                return null;
            }
        }

        // -- the words ------------------------------------------------------

        private const string ReadyHint = "If memoQ isn't showing it, click another segment and then back.";

        /// <summary>The notice's way out (<see cref="LocalServer.Stop"/>).</summary>
        internal const string StopText = "Stop translating these segments";

        /// <summary>
        /// What the notice says. Separate from the window so it can be checked.
        /// </summary>
        /// <param name="elapsed">
        /// The clock: how long the server has been on <paramref name="label"/>,
        /// or how long the wait has lasted when there is no label.
        /// </param>
        /// <param name="label">What the server is working on, or null.</param>
        /// <param name="ready">A segment whose answer memoQ has probably stopped waiting for, or null.</param>
        internal static string Describe(string provider, string model, TimeSpan elapsed, int waiting, Reading reading,
            string label = null, string ready = null)
        {
            var text = new StringBuilder();

            if (waiting <= 0)
            {
                return ready == null
                    ? string.Empty
                    : "Supervertaler: translation ready for " + ready + "." + Environment.NewLine + ReadyHint;
            }

            text.Append("Supervertaler is waiting for ").Append(provider);
            if (!string.IsNullOrWhiteSpace(model)) text.Append(" (").Append(model.Trim()).Append(')');
            if (label == null) text.Append(" \u00B7 ").Append(Clock(elapsed));

            if (ready != null)
            {
                text.AppendLine();
                text.Append("Ready: ").Append(ready).Append(". ").Append(ReadyHint);
            }

            if (label != null)
            {
                text.AppendLine();
                text.Append("Translating ").Append(label).Append(" \u00B7 ").Append(Clock(elapsed));
            }

            // In a translator's words. The token counts follow in brackets: worth
            // knowing - tokens are what models are priced and limited by - but
            // not the thing the sentence is about (Michael, 2026-10-13).
            var known = reading != null && reading.Total > 0;
            var stillReading = false;

            if (known)
            {
                text.AppendLine();
                var share = (int)Math.Floor(100.0 * Math.Min(reading.Done, reading.Total) / reading.Total);
                var total = reading.Total.ToString("N0", CultureInfo.InvariantCulture);

                if (reading.Writing || reading.Total - reading.Done < ChunkTokens)
                {
                    // Ollama reports every 1,024 tokens read and says nothing while
                    // it writes; its "prompt read" line comes only with the answer.
                    // Inside the last chunk, the percentage would sit still for the
                    // whole of the writing, looking stuck - so say what is next.
                    text.Append("Instructions read (").Append(total).Append(" tokens); now writing the translation.");
                }
                else
                {
                    stillReading = true;
                    text.Append("Reading the instructions: ").Append(share).Append("% done (")
                        .Append(Math.Min(reading.Done, reading.Total).ToString("N0", CultureInfo.InvariantCulture))
                        .Append(" of ").Append(total).Append(" tokens)");

                    if (reading.Rate > 0 && reading.Done > 0)
                    {
                        var left = TimeSpan.FromSeconds((reading.Total - reading.Done) / reading.Rate);
                        text.Append(" \u00B7 about ").Append(Roughly(left)).Append(" left");
                    }
                }
            }

            if (waiting > 1)
            {
                text.AppendLine();
                text.Append(waiting - 1).Append(waiting == 2
                    ? " more translation is waiting its turn."
                    : " more translations are waiting their turn.");
            }

            // Why it is slow - only while it is, or when there is no telling.
            if (stillReading || !known)
            {
                text.AppendLine();
                text.Append("The first translation is the slow one: the model reads the instructions once and then "
                    + "reuses them, so the next ones are much quicker.");
            }

            return text.ToString();
        }

        private static string Clock(TimeSpan t) =>
            ((int)t.TotalMinutes).ToString(CultureInfo.InvariantCulture) + ":" + t.Seconds.ToString("00", CultureInfo.InvariantCulture);

        private static string Roughly(TimeSpan t)
        {
            if (t.TotalSeconds < 90) return "a minute";
            return Math.Ceiling(t.TotalMinutes).ToString(CultureInfo.InvariantCulture) + " minutes";
        }

        // -- the window -----------------------------------------------------

        private static void StartNotice(object token)
        {
            var thread = new Thread(() =>
            {
                try
                {
                    // Not handed to the context as its main form, which would show
                    // it at once: it shows itself after the delay, or never.
                    using (new NoticeForm(token)) Application.Run(new ApplicationContext());
                }
                catch (Exception ex)
                {
                    PluginLog.Write("Waiting notice failed", ex);
                }
                finally
                {
                    // However the thread ends, the next wait must be able to show
                    // a notice of its own.
                    lock (Lock) { Forget(token); }
                }
            })
            { IsBackground = true, Name = "Supervertaler waiting notice" };

            thread.SetApartmentState(ApartmentState.STA);
            thread.Start();
        }

        private sealed class NoticeForm : Form
        {
            private const int WS_EX_NOACTIVATE = 0x08000000;
            private const int WS_EX_TOOLWINDOW = 0x00000080;
            private const int WS_EX_TOPMOST = 0x00000008;

            /// <summary>This process, looked up once: the notice asks twice a second.</summary>
            private static readonly uint OwnId = CurrentId();

            private static uint CurrentId()
            {
                using (var self = Process.GetCurrentProcess()) return (uint)self.Id;
            }

            private readonly Label _text;
            private readonly LinkLabel _stop;
            private readonly System.Windows.Forms.Timer _tick;

            public NoticeForm(object token)
            {
                FormBorderStyle = FormBorderStyle.None;
                StartPosition = FormStartPosition.Manual;
                ShowInTaskbar = false;
                TopMost = true;
                BackColor = Color.FromArgb(32, 32, 32);
                ForeColor = Color.White;
                Padding = new Padding(14, 11, 14, 11);

                _text = new Label
                {
                    AutoSize = true,
                    MaximumSize = new Size(460, 0),
                    Font = new Font(SystemFonts.MessageBoxFont.FontFamily, 9.5f),
                    ForeColor = Color.White,
                    Location = new Point(Padding.Left, Padding.Top)
                };
                _text.Click += (s, e) => { Dismiss(); Hide(); };
                Click += (s, e) => { Dismiss(); Hide(); };
                Controls.Add(_text);

                // The way out when a wait is longer than anyone wants: memoQ's
                // own Cancel waits for the request under way, however long.
                _stop = new LinkLabel
                {
                    AutoSize = true,
                    Text = StopText,
                    Font = _text.Font,
                    LinkColor = Color.FromArgb(140, 190, 255),
                    ActiveLinkColor = Color.White,
                    VisitedLinkColor = Color.FromArgb(140, 190, 255)
                };
                _stop.LinkClicked += (s, e) =>
                {
                    Dismiss();
                    Hide();
                    // On the pool: cancelling runs the requests' continuations,
                    // which have no business on this window's thread.
                    Task.Run(() => LocalServer.Stop());
                };
                Controls.Add(_stop);

                _tick = new System.Windows.Forms.Timer { Interval = 1000 };
                _tick.Tick += (s, e) => ShowState(Take(token));
                _tick.Start();
            }

            private void ShowState(Snapshot now)
            {
                if (now == null)
                {
                    _tick.Stop();
                    Hide();
                    Application.ExitThread();
                    return;
                }

                // "Ready" is news and shows at once; a wait shows after the delay.
                var early = now.Ready == null && now.Elapsed < Delay;
                if (early || now.Dismissed || !MemoQInFront())
                {
                    if (Visible) Hide();
                    return;
                }

                var reading = now.Waiting > 0 ? Parse(ReadLog(now.LogPath, now.LogFrom)) : null;
                _text.Text = Describe(now.Provider, now.Model, now.Clock, now.Waiting, reading, now.Label, now.Ready);
                // Stop only while something is waiting; "ready" alone has nothing to stop.
                _stop.Visible = now.Waiting > 0;
                _stop.Location = new Point(Padding.Left, _text.Top + _text.PreferredHeight + 8);
                var height = _text.PreferredHeight + (_stop.Visible ? _stop.PreferredHeight + 8 : 0);
                ClientSize = new Size(Math.Max(_text.PreferredWidth, _stop.Visible ? _stop.PreferredWidth : 0)
                    + Padding.Horizontal, height + Padding.Vertical);
                PlaceInMemoQCorner();

                if (!Visible) Show();
                if (now.Ready != null) ReadySeen();
            }

            /// <summary>Bottom right of memoQ's window, above its status bar.</summary>
            private void PlaceInMemoQCorner()
            {
                var area = Screen.PrimaryScreen.WorkingArea;
                IntPtr main;
                using (var self = Process.GetCurrentProcess()) main = self.MainWindowHandle;
                if (main != IntPtr.Zero && GetWindowRect(main, out var r))
                    area = Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);

                var screen = Screen.FromRectangle(area).WorkingArea;
                var x = Math.Min(area.Right, screen.Right) - Width - 24;
                var y = Math.Min(area.Bottom, screen.Bottom) - Height - 48;
                Location = new Point(Math.Max(screen.Left + 8, x), Math.Max(screen.Top + 8, y));
            }

            /// <summary>Whether the window in front belongs to memoQ - its grid, or one of its dialogs.</summary>
            private static bool MemoQInFront()
            {
                var front = GetForegroundWindow();
                if (front == IntPtr.Zero) return false;
                GetWindowThreadProcessId(front, out var pid);
                return pid == OwnId;
            }

            /// <summary>memoQ keeps the caret and the keyboard.</summary>
            protected override bool ShowWithoutActivation => true;

            /// <summary>
            /// Topmost in the window's own style, not through <see cref="Form.TopMost"/>:
            /// WinForms applies that on activation, and this window is never
            /// activated, so it came up as an ordinary window. The first click
            /// into memoQ's grid then lifted memoQ over it, and in memoQ on
            /// 2026-10-13 it sat there for ten minutes, visible to Windows and
            /// to nobody else.
            /// </summary>
            protected override CreateParams CreateParams
            {
                get
                {
                    var p = base.CreateParams;
                    p.ExStyle |= WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TOPMOST;
                    return p;
                }
            }

            protected override void Dispose(bool disposing)
            {
                if (disposing) { _tick.Stop(); _tick.Dispose(); }
                base.Dispose(disposing);
            }

            [StructLayout(LayoutKind.Sequential)]
            private struct RECT { public int Left, Top, Right, Bottom; }

            [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
            [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
            [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
        }
    }
}
