using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Supervertaler.MemoQ.Settings;

namespace Supervertaler.MemoQ.Core
{
    /// <summary>
    /// The order in which requests reach a server of the translator's own, and
    /// which of them need sending at all.
    ///
    /// <para>A local server on a computer without a graphics card answers one
    /// request at a time and can take a minute or more each, so requests wait
    /// here. What memoQ does, measured in the plugin log on 2026-10-13: it asks
    /// for the segment the translator lands on, then fetches the following rows
    /// ahead by itself - three rows exactly 10.2 seconds apart while the
    /// translator sat still, and the next row the moment an answer arrived - and
    /// it asks again for a segment it is still waiting on. So the order in which
    /// memoQ asks is the translator's own: their segment, then the ones after it.
    /// The first version of this queue served the newest request first, on the
    /// belief that memoQ did not fetch ahead; it served memoQ's look-ahead rows
    /// before the segment the translator was waiting on. So:</para>
    ///
    /// <list type="bullet">
    /// <item>A request someone is looking at - a segment, a test, an AutoPrompt -
    /// goes before a Pre-translate batch, and among those the oldest goes first.
    /// Batches likewise, which is the document's order.</item>
    /// <item>A second request for a segment already waiting or under way joins it
    /// - one answer, one model call - and if it is still waiting, being asked for
    /// again moves it to the very front: memoQ asks again for the segment the
    /// translator has come back to. A segment is the same segment even when its
    /// prompt has changed meanwhile - a newly confirmed row becoming one of its
    /// examples - which on 2026-10-13 got two segments translated twice.</item>
    /// <item>A request whose segment the translator confirmed while it waited is
    /// not sent (see <see cref="Turn.Overtaken"/>).</item>
    /// </list>
    ///
    /// <para>One lock, held only to look at or change the list and the count; a
    /// place is handed over by completing the waiter's task, never by anything
    /// running under the lock.</para>
    /// </summary>
    internal static class LocalQueue
    {
        /// <summary>What a request is for, which decides its place.</summary>
        internal sealed class Turn
        {
            /// <summary>
            /// Someone is looking at the answer. False for a Pre-translate batch,
            /// which nobody is watching row by row and which runs in document order.
            /// </summary>
            public bool Interactive = true;

            /// <summary>
            /// True once the request no longer needs an answer, asked when its turn
            /// comes. Null: always needs one.
            /// </summary>
            public Func<bool> Overtaken;

            /// <summary>
            /// Which segment this is - document and source - so that a second
            /// request for it joins the first even when the prompt around it has
            /// changed. Null: two requests are the same only with the same prompt.
            /// </summary>
            public string Segment;

            /// <summary>What the waiting notice calls the request, or null.</summary>
            public string Label;
        }

        /// <summary>A request under way or waiting, which an identical one can join.</summary>
        internal sealed class Flight
        {
            internal readonly TaskCompletionSource<string> Answer =
                new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);

            /// <summary>Its place in the line, while it has one.</summary>
            internal Waiter Place;
        }

        internal sealed class Waiter
        {
            public long Stamp;
            public bool Interactive;
            public readonly TaskCompletionSource<bool> Go =
                new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        /// <summary>The segment was confirmed in memoQ before the model got to it.</summary>
        internal sealed class OvertakenException : InvalidOperationException
        {
            public OvertakenException()
                : base("Not translated: this segment was confirmed in memoQ before the model got to it.") { }
        }

        private static readonly object Lock = new object();
        private static readonly List<Waiter> Waiting = new List<Waiter>();
        private static readonly Dictionary<string, Flight> Flights = new Dictionary<string, Flight>(StringComparer.Ordinal);
        private static int _running;
        private static long _stamp;

        /// <summary>
        /// Below every arrival stamp, and lower still for each move to the front,
        /// so the latest segment asked for again goes first of all.
        /// </summary>
        private static long _front;

        /// <summary>
        /// What makes two requests the same request: the same segment, under the
        /// same instructions, to the same model - or, for a request that is not a
        /// segment, the same prompt. Also the translation cache's key for a local
        /// server (SessionRunner), so a segment asked for again after its answer
        /// is served from the cache rather than translated again.
        /// </summary>
        internal static string Identity(SupervertalerGeneralSettings general, string user, string system, Turn turn = null) =>
            TranslationCache.Key(general.Provider, general.Model, general.Endpoint, system ?? string.Empty,
                turn?.Segment != null ? "segment\n" + turn.Segment : user ?? string.Empty);

        /// <summary>
        /// The answer of an identical request already waiting or under way, in
        /// <paramref name="joined"/>, and null; or, when there is none, a new
        /// flight registered for the caller, who must <see cref="Close"/> it.
        /// </summary>
        internal static Flight JoinOrOpen(string identity, out Task<string> joined)
        {
            string note = null;
            Flight mine = null;
            joined = null;

            lock (Lock)
            {
                if (Flights.TryGetValue(identity, out var under))
                {
                    joined = under.Answer.Task;
                    if (under.Place != null && Waiting.Contains(under.Place))
                    {
                        under.Place.Stamp = --_front;
                        note = "queue: memoQ asked again for a segment that is waiting; it moves to the front";
                    }
                    else
                    {
                        note = "queue: memoQ asked again for a segment being translated; it gets that answer";
                    }
                }
                else
                {
                    mine = new Flight();
                    Flights[identity] = mine;
                }
            }

            if (note != null) PluginLog.Write(note);
            return mine;
        }

        /// <summary>Takes a finished flight off the list. Called however it finished.</summary>
        internal static void Close(string identity, Flight flight)
        {
            lock (Lock)
            {
                if (Flights.TryGetValue(identity, out var current) && ReferenceEquals(current, flight))
                    Flights.Remove(identity);
            }
        }

        /// <summary>
        /// A place to send from. Completes at once when one is free and nobody is
        /// waiting; otherwise when <see cref="Leave"/> hands one over. Whoever it
        /// completes for must call <see cref="Leave"/> exactly once, however the
        /// request ends. Cancelled while waiting, it leaves the line and has no
        /// place to give back.
        /// </summary>
        internal static Task EnterAsync(int parallel, Turn turn, Flight flight, CancellationToken cancellationToken)
        {
            var capacity = Math.Max(1, Math.Min(16, parallel));
            lock (Lock)
            {
                if (_running < capacity && Waiting.Count == 0)
                {
                    _running++;
                    return Task.FromResult(true);
                }

                var waiter = new Waiter { Stamp = ++_stamp, Interactive = turn?.Interactive ?? true };
                Waiting.Add(waiter);
                if (flight != null) flight.Place = waiter;

                if (cancellationToken.CanBeCanceled)
                {
                    cancellationToken.Register(() =>
                    {
                        lock (Lock)
                        {
                            if (Waiting.Remove(waiter)) waiter.Go.TrySetCanceled();
                        }
                    });
                }

                return waiter.Go.Task;
            }
        }

        /// <summary>Gives a place back, and hands free places to whoever goes next.</summary>
        internal static void Leave(int parallel)
        {
            var capacity = Math.Max(1, Math.Min(16, parallel));

            lock (Lock)
            {
                _running = Math.Max(0, _running - 1);
                while (_running < capacity && Waiting.Count > 0)
                {
                    var next = Next();
                    Waiting.Remove(next);
                    _running++;
                    next.Go.TrySetResult(true);
                }
            }
        }

        /// <summary>
        /// Who goes next: a request someone is looking at before a Pre-translate
        /// batch, and within each the lowest stamp - the first asked, or the one
        /// moved to the front.
        /// </summary>
        private static Waiter Next()
        {
            var looked = Waiting.Where(w => w.Interactive).ToList();
            return (looked.Count > 0 ? looked : Waiting).OrderBy(w => w.Stamp).First();
        }

        /// <summary>For the harness: how many wait, and how many run.</summary>
        internal static string State()
        {
            lock (Lock) return "waiting " + Waiting.Count + ", running " + _running + ", flights " + Flights.Count;
        }
    }
}
