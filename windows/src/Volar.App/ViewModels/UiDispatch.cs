// ViewModels/UiDispatch.cs — tiny DispatcherQueue.TryEnqueue wrapper. wave4-contract.md Stage A
// deliverable 7 + frozen decision 12: "ALWAYS marshal event callbacks through
// DispatcherQueue.TryEnqueue before touching VM state" + "VMs must be constructible in a plain
// unit-test host: no XAML control types inside VMs" — a VM built in a headless test host has no
// real `DispatcherQueue` (there is no UI thread/message loop at all), so this helper's null-safe
// fallback (run the action inline instead of enqueuing) is what lets the SAME VM code path run
// under both a real WinUI host and a plain xunit test host without an `#if`/environment check.
using Microsoft.UI.Dispatching;

namespace Volar.App.ViewModels;

public static class UiDispatch
{
    /// <summary>Runs <paramref name="action"/> on <paramref name="dispatcherQueue"/> if one is
    /// supplied, else runs it inline (synchronously, on the calling thread) — the "test host" case.
    /// Also falls back to inline execution if <see cref="DispatcherQueue.TryEnqueue(DispatcherQueueHandler)"/>
    /// itself returns <see langword="false"/> (the queue is shutting down / not accepting new work),
    /// matching this wave's "never silently drop a callback" convention (see e.g. App.xaml.cs's
    /// startup-sequence try/catch) rather than losing the state update.</summary>
    public static void Post(DispatcherQueue? dispatcherQueue, Action action)
    {
        ArgumentNullException.ThrowIfNull(action);

        if (dispatcherQueue is null)
        {
            action();
            return;
        }

        if (!dispatcherQueue.TryEnqueue(new DispatcherQueueHandler(action)))
        {
            action();
        }
    }
}
