// ViewModels/OnboardingViewModelTests.cs — B4 (Settings + Onboarding), Wave 4. Covers
// OnboardingViewModel's step clamping/advance/complete behavior and the App.xaml.cs
// `HasOnboardedKey` literal cross-check (this VM's own doc comment flags the duplication risk —
// this test is what actually pins the two literals in sync).
using Volar.Domain;
using Volar.App.ViewModels;
using Xunit;

namespace Volar.App.Tests.ViewModels;

public sealed class OnboardingViewModelTests
{
    [Fact]
    public void Constructor_DefaultsToStepOne()
    {
        var vm = new OnboardingViewModel(new InMemorySettingsStore());
        Assert.Equal(1, vm.Step);
    }

    [Theory]
    [InlineData(0, 1)]
    [InlineData(1, 1)]
    [InlineData(2, 2)]
    [InlineData(3, 3)]
    [InlineData(4, 3)]
    public void Constructor_ClampsInitialStep_ToValidRange(int requested, int expected)
    {
        var vm = new OnboardingViewModel(new InMemorySettingsStore(), initialStep: requested);
        Assert.Equal(expected, vm.Step);
    }

    [Fact]
    public void Advance_MovesForwardOneStepAtATime_AndStopsAtTotalSteps()
    {
        var vm = new OnboardingViewModel(new InMemorySettingsStore());

        vm.Advance();
        Assert.Equal(2, vm.Step);

        vm.Advance();
        Assert.Equal(3, vm.Step);

        vm.Advance(); // already at the last step — clamped, not thrown.
        Assert.Equal(3, vm.Step);
    }

    [Fact]
    public void GoToStep_RaisesPropertyChanged_OnlyWhenStepActuallyChanges()
    {
        var vm = new OnboardingViewModel(new InMemorySettingsStore());
        var raiseCount = 0;
        vm.PropertyChanged += (_, e) =>
        {
            if (e.PropertyName == nameof(OnboardingViewModel.Step))
            {
                raiseCount++;
            }
        };

        vm.GoToStep(1); // no-op, already step 1.
        Assert.Equal(0, raiseCount);

        vm.GoToStep(2);
        Assert.Equal(1, raiseCount);
    }

    [Fact]
    public void Complete_PersistsHasOnboardedFlag_AndRaisesCompleted()
    {
        var settings = new InMemorySettingsStore();
        var vm = new OnboardingViewModel(settings);
        var completedRaised = 0;
        vm.Completed += (_, _) => completedRaised++;

        vm.Complete();

        Assert.True(settings.GetBool(OnboardingViewModel.HasOnboardedSettingsKey, false));
        Assert.Equal(1, completedRaised);
    }

    /// <summary>Pins the exact literal App.xaml.cs's own (private) `HasOnboardedKey` uses — see
    /// OnboardingViewModel.cs's own doc comment on why this can't be a shared constant reference
    /// (App.xaml.cs is off-limits to every Stage A/B agent).</summary>
    [Fact]
    public void HasOnboardedSettingsKey_MatchesTheLiteralAppXamlCsUses()
    {
        Assert.Equal("hasOnboardedV1", OnboardingViewModel.HasOnboardedSettingsKey);
    }

    [Fact]
    public void Complete_FromSkipForNow_IsIdenticalToStartUsingVolar_BothJustCallComplete()
    {
        // OnboardingView.swift:257-286: both step-3 buttons call the SAME onComplete() — this VM
        // has exactly one Complete() method for both, so there is nothing to distinguish; this test
        // documents that intentional non-distinction rather than asserting on private wiring.
        var settings = new InMemorySettingsStore();
        var vm = new OnboardingViewModel(settings, initialStep: 3);

        vm.Complete();

        Assert.True(settings.GetBool(OnboardingViewModel.HasOnboardedSettingsKey, false));
    }
}
