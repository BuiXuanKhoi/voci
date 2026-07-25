// ReminderContextGateTests.cs — xUnit port of the gate-suppression cases in
// Tests/ReminderSchedulerTests.swift (contract §B). One deliberate deviation from the Swift
// original: Swift's `testGateDefaultsToNotSuppressedWithNoSignalsWired` relied on a concrete
// AVFoundation mic-contention check reading `false` in a plain test-runner process. This port
// demoted that fifth signal to an injectable extension point too (see
// ReminderContextGate.IsAnotherAppUsingMicrophone's doc comment for why), so "no signals wired"
// means all five are unset here, not four-plus-one-concrete-check.
using Xunit;

namespace Volar.Reminders.Tests;

public class ReminderContextGateTests
{
    // Swift: testGateSuppressesDuringBusyInterval

    [Fact]
    public void GateSuppressesDuringBusyInterval()
    {
        var gate = new ReminderContextGate();
        var now = Fixtures.ReferenceNow;
        gate.BusyIntervals = new[] { new ReminderTimeRange(now.AddMinutes(-1), now.AddMinutes(1)) };
        Assert.True(gate.ShouldSuppressVoice(now));
    }

    // Swift: testGateAllowsOutsideBusyInterval

    [Fact]
    public void GateAllowsOutsideBusyInterval()
    {
        var gate = new ReminderContextGate();
        var now = Fixtures.ReferenceNow;
        gate.BusyIntervals = new[] { new ReminderTimeRange(now.AddHours(1), now.AddHours(2)) };
        Assert.False(gate.ShouldSuppressVoice(now));
    }

    // Swift: testGateSuppressesWhenDoNotDisturbSignalFires

    [Fact]
    public void GateSuppressesWhenDoNotDisturbSignalFires()
    {
        var gate = new ReminderContextGate { IsDoNotDisturbOn = () => true };
        Assert.True(gate.ShouldSuppressVoice(Fixtures.ReferenceNow));
    }

    // Swift: testGateSuppressesWhenLocalCaptureActive

    [Fact]
    public void GateSuppressesWhenLocalCaptureActive()
    {
        var gate = new ReminderContextGate { IsLocalMicCaptureActive = () => true };
        Assert.True(gate.ShouldSuppressVoice(Fixtures.ReferenceNow));
    }

    // Swift: testGateSuppressesWhenScreenSharingSignalFires

    [Fact]
    public void GateSuppressesWhenScreenSharingSignalFires()
    {
        var gate = new ReminderContextGate { IsScreenBeingShared = () => true };
        Assert.True(gate.ShouldSuppressVoice(Fixtures.ReferenceNow));
    }

    // Swift: testGateSuppressesWhenOtherAudioSignalFires

    [Fact]
    public void GateSuppressesWhenOtherAudioSignalFires()
    {
        var gate = new ReminderContextGate { IsOtherAudioPlaying = () => true };
        Assert.True(gate.ShouldSuppressVoice(Fixtures.ReferenceNow));
    }

    // NEW (Windows-specific extension point, see this project's ReminderContextGate.cs doc comment).

    [Fact]
    public void GateSuppressesWhenAnotherAppUsingMicrophoneSignalFires()
    {
        var gate = new ReminderContextGate { IsAnotherAppUsingMicrophone = () => true };
        Assert.True(gate.ShouldSuppressVoice(Fixtures.ReferenceNow));
    }

    // Swift: testGateDefaultsToNotSuppressedWithNoSignalsWired (adapted — see file header)

    [Fact]
    public void GateDefaultsToNotSuppressedWithNoSignalsWired()
    {
        var gate = new ReminderContextGate();
        Assert.False(gate.ShouldSuppressVoice(Fixtures.ReferenceNow));
    }
}
