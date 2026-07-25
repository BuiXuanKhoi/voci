// Services/DelegationHandoffAdapter.cs — the two-line seam wave3c-services.md's "Opus review notes
// from stage 2" assigns to C5: C3's CaptureFlowService.cs declares IDelegationHandoff (voice-done
// ".Delegate" action) with the shape DelegateAsync(Guid taskId, string? label, int
// checkBackMinutes, CancellationToken); C4's DelegationOrchestratorService.cs exposes
// DelegateTaskAsync(Guid taskId, string? label = null, int checkBackMinutes = 10). Neither agent
// could edit the other's file, so the seam was left for whoever owns wiring (this file). Until this
// adapter is registered, a voice "giao cho Claude rồi" logs a warning and silently drops the
// hand-off (CaptureFlowService.RouteDelegateActionAsync's documented behavior when
// IDelegationHandoff is null) — see Wiring/DelegationHandoffWiringTests.cs for the regression test.
using Volar.App.Services.State;

namespace Volar.App.Services;

public sealed class DelegationHandoffAdapter : IDelegationHandoff
{
    private readonly DelegationOrchestratorService _orchestrator;

    public DelegationHandoffAdapter(DelegationOrchestratorService orchestrator)
    {
        _orchestrator = orchestrator ?? throw new ArgumentNullException(nameof(orchestrator));
    }

    public Task DelegateAsync(Guid taskId, string? label, int checkBackMinutes, CancellationToken cancellationToken = default) =>
        _orchestrator.DelegateTaskAsync(taskId, label, checkBackMinutes);
}
