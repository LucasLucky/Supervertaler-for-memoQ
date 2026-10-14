using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace Supervertaler.MemoQ.Core
{
    /// <summary>
    /// How many requests go to a cloud provider at once: the Parallel requests
    /// setting, read for every request.
    ///
    /// <para>memoQ has a limit of its own, but reads it only when the MT settings
    /// resource is created and keeps it in the .mqres. Measured 2026-10-14: a
    /// resource holding 4 still held 4 after the dialog was saved with the cloud
    /// value at 1, and nothing in the plugin limited a cloud provider, so the
    /// setting did nothing at all. Enforced here, lowering it takes effect on the
    /// next request. Raising it above the number memoQ stored still cannot,
    /// because memoQ never asks for more at once.</para>
    ///
    /// <para>Smaller than <see cref="LocalQueue"/> on purpose: a cloud provider
    /// answers in seconds, so there is no joining, no Stop and no notice - only a
    /// count and a line, in which someone looking at the answer still goes before
    /// a Pre-translate batch. The locking is the queue's: one lock, held only to
    /// look at or change the line and the count; a place handed over by
    /// completing the waiter's task; every place given back in a finally.</para>
    /// </summary>
    internal static class CloudGate
    {
        private sealed class Waiter
        {
            public bool Interactive;
            public readonly TaskCompletionSource<bool> Go =
                new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        }

        private static readonly object Lock = new object();
        private static readonly List<Waiter> Waiting = new List<Waiter>();
        private static int _running;

        /// <summary>
        /// Sends <paramref name="request"/> once a place is free, and gives the
        /// place back however it ends. Cancelled while it waits, it is never sent.
        /// </summary>
        internal static async Task<string> RunAsync(
            int parallel,
            bool interactive,
            Func<CancellationToken, Task<string>> request,
            CancellationToken cancellationToken)
        {
            await EnterAsync(parallel, interactive, cancellationToken).ConfigureAwait(false);
            try
            {
                return await request(cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                Leave(parallel);
            }
        }

        private static async Task EnterAsync(int parallel, bool interactive, CancellationToken cancellationToken)
        {
            var capacity = Capacity(parallel);
            Waiter waiter;
            lock (Lock)
            {
                if (_running < capacity && Waiting.Count == 0)
                {
                    _running++;
                    return;
                }

                waiter = new Waiter { Interactive = interactive };
                Waiting.Add(waiter);
            }

            // Outside the lock: a token already cancelled runs this at once.
            // Whichever comes first wins - a place handed over takes the waiter
            // off the line, so a cancellation after that finds nothing to undo.
            using (cancellationToken.Register(() =>
            {
                lock (Lock)
                {
                    if (Waiting.Remove(waiter)) waiter.Go.TrySetCanceled();
                }
            }))
            {
                await waiter.Go.Task.ConfigureAwait(false);
            }
        }

        private static void Leave(int parallel)
        {
            var capacity = Capacity(parallel);
            lock (Lock)
            {
                _running = Math.Max(0, _running - 1);
                while (_running < capacity && Waiting.Count > 0)
                {
                    var next = Waiting.Find(w => w.Interactive) ?? Waiting[0];
                    Waiting.Remove(next);
                    _running++;
                    next.Go.TrySetResult(true);
                }
            }
        }

        private static int Capacity(int parallel) => Math.Max(1, Math.Min(16, parallel));

        /// <summary>For the harness: how many wait, and how many run.</summary>
        internal static string State()
        {
            lock (Lock) return "waiting " + Waiting.Count + ", running " + _running;
        }
    }
}
