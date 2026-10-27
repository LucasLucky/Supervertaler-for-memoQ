using System;
using System.Collections.Generic;
using System.Threading;
using Supervertaler.Core;

namespace Supervertaler.MemoQ.Core
{
    /// <summary>
    /// The Pre-translate run in progress for each language pair, which memoQ's
    /// SDK does not have: a Pre-translate arrives as calls from several sessions
    /// at once, with nothing to say they belong together
    /// (docs/design/consistent-repetitions.md §4.1, in the Trados repo).
    ///
    /// <para>A run is continuous Pre-translate activity. It starts with a call
    /// when none is running, and ends once no call has been running for
    /// <see cref="IdleEnd"/>: two Pre-translates started within a minute of each
    /// other become one run, which only makes them consistent with each other
    /// too. Keyed by language pair, not by engine, because memoQ builds two
    /// engines per pair and would split a run between them.</para>
    ///
    /// <para>All the state is a count of calls running and when the last one
    /// left. The run is dropped, and its summary logged, by a timer
    /// <see cref="IdleEnd"/> after the last call leaves - so a large job's groups
    /// are not kept in memory until the next Pre-translate. Every call holds its
    /// place with a <see cref="Lease"/>, which must be disposed in a finally: a
    /// call that threw and never left would keep its run open for good.</para>
    /// </summary>
    internal static class PreTranslateRuns
    {
        /// <summary>How long a run outlives its last call. Settable only for tests.</summary>
        internal static TimeSpan IdleEnd { get; set; } = TimeSpan.FromSeconds(60);

        private static readonly object _lock = new object();
        private static readonly Dictionary<string, Entry> _runs = new Dictionary<string, Entry>(StringComparer.Ordinal);

        private sealed class Entry
        {
            public readonly RepetitionRun Repetitions = new RepetitionRun();
            public int Running;
            public DateTime IdleSinceUtc;
            public Timer EndTimer;
        }

        /// <summary>One call's place in its language pair's run.</summary>
        internal sealed class Lease : IDisposable
        {
            private Action _leave;

            internal Lease(RepetitionRun repetitions, Action leave)
            {
                Repetitions = repetitions;
                _leave = leave;
            }

            public RepetitionRun Repetitions { get; }

            /// <summary>Leaves the run, once however often it is called.</summary>
            public void Dispose() => Interlocked.Exchange(ref _leave, null)?.Invoke();
        }

        /// <summary>Joins the language pair's run, starting one if none is open.</summary>
        public static Lease Enter(string pair)
        {
            pair = pair ?? "";
            string ended = null, started = null;
            Lease lease;

            lock (_lock)
            {
                // A run whose timer has not fired yet but whose minute is up is over:
                // the answer must not depend on how promptly a timer runs.
                if (_runs.TryGetValue(pair, out var entry) && entry.Running == 0
                    && DateTime.UtcNow - entry.IdleSinceUtc >= IdleEnd)
                {
                    ended = EndLocked(pair, entry);
                    entry = null;
                }

                if (entry == null)
                {
                    entry = new Entry();
                    _runs[pair] = entry;
                    started = "repetitions: Pre-translate run started (" + pair + ")";
                }

                entry.Running++;
                var joined = entry;
                lease = new Lease(joined.Repetitions, () => Leave(pair, joined));
            }

            if (ended != null) PluginLog.Write(ended);
            if (started != null) PluginLog.Write(started);
            return lease;
        }

        /// <summary>Whether a run is open for the pair: running, or within its minute. For tests.</summary>
        internal static bool IsOpen(string pair)
        {
            lock (_lock) return _runs.ContainsKey(pair ?? "");
        }

        private static void Leave(string pair, Entry entry)
        {
            lock (_lock)
            {
                entry.Running--;
                if (entry.Running > 0) return;

                entry.IdleSinceUtc = DateTime.UtcNow;
                if (entry.EndTimer == null)
                    entry.EndTimer = new Timer(_ => Expire(pair, entry), null, IdleEnd, Timeout.InfiniteTimeSpan);
                else
                    entry.EndTimer.Change(IdleEnd, Timeout.InfiniteTimeSpan);
            }
        }

        private static void Expire(string pair, Entry entry)
        {
            string ended = null;

            lock (_lock)
            {
                // Already ended by Enter, or replaced; or a call is running again
                // (its own Leave sets the timer anew).
                if (!_runs.TryGetValue(pair, out var current) || !ReferenceEquals(current, entry) || entry.Running > 0) return;

                // A timer may fire a little early. Wait out the rest rather than
                // leave a run nothing will end.
                var left = entry.IdleSinceUtc + IdleEnd - DateTime.UtcNow;
                if (left > TimeSpan.Zero)
                {
                    entry.EndTimer.Change(left, Timeout.InfiniteTimeSpan);
                    return;
                }

                ended = EndLocked(pair, entry);
            }

            PluginLog.Write(ended);
        }

        /// <summary>Removes the run and returns its log line, written by the caller once the lock is released.</summary>
        private static string EndLocked(string pair, Entry entry)
        {
            _runs.Remove(pair);
            entry.EndTimer?.Dispose();
            entry.EndTimer = null;

            return "repetitions: Pre-translate run ended (" + pair + ") - "
                   + entry.Repetitions.Summary().Replace(Environment.NewLine, " | ");
        }
    }
}
