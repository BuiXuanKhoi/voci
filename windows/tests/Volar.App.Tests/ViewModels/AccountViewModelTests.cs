// ViewModels/AccountViewModelTests.cs — account-auth contract (2026-07-26). Exercises
// AccountViewModel against a FakeAccountService (no real HTTP/DPAPI — that's AccountService's own
// test responsibility, see Services/Account/AccountServiceTests.cs). Constructed with no
// DispatcherQueue (null), same "headless test host" pattern every other Wave-4 VM test in this
// assembly uses (UiDispatch.Post falls back to running inline when the queue is null).
using System.ComponentModel;
using Volar.App.Services.Account;
using Volar.App.ViewModels;
using Xunit;

namespace Volar.App.Tests.ViewModels;

internal sealed class FakeAccountService : IAccountService
{
    public event Action? Changed;

    public void RaiseChanged() => Changed?.Invoke();

    public AccountSessionState State { get; set; } = AccountSessionState.SignedOut;
    public AccountUser? CurrentUser { get; set; }
    public SubscriptionStatusSnapshot? CachedStatus { get; set; }

    public OtpSendResult SendOtpResult { get; set; } = OtpSendResult.Ok();
    public int SendOtpCallCount { get; private set; }
    public string? LastSendOtpEmail { get; private set; }

    public VerifyOtpResult VerifyOtpResult { get; set; } = new(VerifyOtpOutcome.SignedIn);
    public int VerifyOtpCallCount { get; private set; }
    public (string Email, string Code)? LastVerifyOtpArgs { get; private set; }
    /// <summary>Mimics AccountService's real "persist session" side effect when the fake is told to
    /// report success — lets tests assert AccountViewModel actually re-reads State/CurrentUser/
    /// CachedStatus after a successful verify, not just that it called the method.</summary>
    public Action? OnVerifyOtpSucceeded { get; set; }

    public int SignOutCallCount { get; private set; }
    public Action? OnSignOut { get; set; }

    public int DeleteAccountCallCount { get; private set; }
    public DeleteAccountResult DeleteAccountResult { get; set; } = new(DeleteAccountOutcome.Deleted);
    public Action? OnDeleteAccountSucceeded { get; set; }

    public int RefreshStatusAsyncCallCount { get; private set; }
    public int RefreshStatusIfStaleCallCount { get; private set; }

    public Task<OtpSendResult> SendOtpAsync(string email, CancellationToken cancellationToken = default)
    {
        SendOtpCallCount++;
        LastSendOtpEmail = email;
        return Task.FromResult(SendOtpResult);
    }

    public Task<VerifyOtpResult> VerifyOtpAsync(string email, string code, CancellationToken cancellationToken = default)
    {
        VerifyOtpCallCount++;
        LastVerifyOtpArgs = (email, code);
        if (VerifyOtpResult.Outcome == VerifyOtpOutcome.SignedIn)
        {
            OnVerifyOtpSucceeded?.Invoke();
        }
        return Task.FromResult(VerifyOtpResult);
    }

    public Task SignOutAsync(CancellationToken cancellationToken = default)
    {
        SignOutCallCount++;
        OnSignOut?.Invoke();
        return Task.CompletedTask;
    }

    public Task<DeleteAccountResult> DeleteAccountAsync(CancellationToken cancellationToken = default)
    {
        DeleteAccountCallCount++;
        if (DeleteAccountResult.Outcome == DeleteAccountOutcome.Deleted)
        {
            OnDeleteAccountSucceeded?.Invoke();
        }
        return Task.FromResult(DeleteAccountResult);
    }

    public Task<string?> GetValidAccessTokenAsync(CancellationToken cancellationToken = default) =>
        Task.FromResult<string?>(State == AccountSessionState.SignedIn ? "fake-token" : null);

    public Task<SubscriptionStatusSnapshot?> RefreshStatusAsync(CancellationToken cancellationToken = default)
    {
        RefreshStatusAsyncCallCount++;
        return Task.FromResult(CachedStatus);
    }

    public void RefreshStatusIfStale(TimeSpan? maxAge = null) => RefreshStatusIfStaleCallCount++;
}

public class AccountViewModelTests
{
    private static SubscriptionStatusSnapshot FreeStatus(int parseUsed = 2) =>
        new("free", null, parseUsed, 20, 0, 0, DateTimeOffset.UtcNow);

    private static SubscriptionStatusSnapshot ProStatus(int parseUsed = 5, int speechUsed = 1) =>
        new("pro", DateTimeOffset.UtcNow.AddMonths(1), parseUsed, 500, speechUsed, 500, DateTimeOffset.UtcNow);

    [Fact]
    public void Constructor_SignedOut_DoesNotTriggerStatusRefresh()
    {
        var fake = new FakeAccountService { State = AccountSessionState.SignedOut };

        _ = new AccountViewModel(fake);

        Assert.Equal(0, fake.RefreshStatusAsyncCallCount);
    }

    [Fact]
    public void Constructor_SignedIn_TriggersStatusRefresh()
    {
        var fake = new FakeAccountService { State = AccountSessionState.SignedIn };

        _ = new AccountViewModel(fake);

        Assert.Equal(1, fake.RefreshStatusAsyncCallCount);
    }

    [Fact]
    public async Task SendCodeAsync_Success_SetsCodeSentTrue_ClearsError()
    {
        var fake = new FakeAccountService { SendOtpResult = OtpSendResult.Ok() };
        var vm = new AccountViewModel(fake) { EmailInput = "me@example.com" };

        await vm.SendCodeAsync();

        Assert.True(vm.CodeSent);
        Assert.Null(vm.ErrorMessage);
        Assert.False(vm.Busy);
        Assert.Equal("me@example.com", fake.LastSendOtpEmail);
        Assert.Equal(1, fake.SendOtpCallCount);
    }

    [Fact]
    public async Task SendCodeAsync_Failure_SetsErrorMessage_CodeNotSent()
    {
        var fake = new FakeAccountService { SendOtpResult = new OtpSendResult(OtpSendOutcome.InvalidEmail, "bad email") };
        var vm = new AccountViewModel(fake) { EmailInput = "not-an-email" };

        await vm.SendCodeAsync();

        Assert.False(vm.CodeSent);
        Assert.Equal("bad email", vm.ErrorMessage);
    }

    [Fact]
    public async Task VerifyCodeAsync_Success_ClearsInputsAndError_ReflectsSignedInState()
    {
        var fake = new FakeAccountService
        {
            VerifyOtpResult = new VerifyOtpResult(VerifyOtpOutcome.SignedIn),
        };
        fake.OnVerifyOtpSucceeded = () =>
        {
            fake.State = AccountSessionState.SignedIn;
            fake.CurrentUser = new AccountUser("u1", "me@example.com");
        };
        var vm = new AccountViewModel(fake) { EmailInput = "me@example.com", CodeInput = "123456" };

        await vm.VerifyCodeAsync();

        Assert.True(vm.IsSignedIn);
        Assert.Equal("me@example.com", vm.Email);
        Assert.Null(vm.ErrorMessage);
        Assert.False(vm.CodeSent);
        Assert.Equal(string.Empty, vm.CodeInput);
        Assert.Equal(string.Empty, vm.EmailInput);
        Assert.Equal(("me@example.com", "123456"), fake.LastVerifyOtpArgs);
    }

    [Fact]
    public async Task VerifyCodeAsync_InvalidCode_SetsErrorMessage_StaysSignedOut()
    {
        var fake = new FakeAccountService { VerifyOtpResult = new VerifyOtpResult(VerifyOtpOutcome.InvalidCode, "wrong code") };
        var vm = new AccountViewModel(fake) { EmailInput = "me@example.com", CodeInput = "000000" };

        await vm.VerifyCodeAsync();

        Assert.False(vm.IsSignedIn);
        Assert.Equal("wrong code", vm.ErrorMessage);
    }

    [Fact]
    public async Task SignOutAsync_CallsService_ClearsErrorAndDeleteConfirmation()
    {
        var fake = new FakeAccountService { State = AccountSessionState.SignedIn };
        fake.OnSignOut = () => fake.State = AccountSessionState.SignedOut;
        var vm = new AccountViewModel(fake);
        vm.RequestDeleteAccount();

        await vm.SignOutAsync();

        Assert.Equal(1, fake.SignOutCallCount);
        Assert.False(vm.IsSignedIn);
        Assert.False(vm.DeleteConfirmationPending);
        Assert.Null(vm.ErrorMessage);
    }

    [Fact]
    public void RequestDeleteAccount_SetsConfirmationPending_NoNetworkCallYet()
    {
        var fake = new FakeAccountService { State = AccountSessionState.SignedIn };
        var vm = new AccountViewModel(fake);

        vm.RequestDeleteAccount();

        Assert.True(vm.DeleteConfirmationPending);
        Assert.Equal(0, fake.DeleteAccountCallCount);
    }

    [Fact]
    public void CancelDeleteAccount_ClearsConfirmationPending()
    {
        var fake = new FakeAccountService { State = AccountSessionState.SignedIn };
        var vm = new AccountViewModel(fake);
        vm.RequestDeleteAccount();

        vm.CancelDeleteAccount();

        Assert.False(vm.DeleteConfirmationPending);
        Assert.Equal(0, fake.DeleteAccountCallCount);
    }

    [Fact]
    public async Task ConfirmDeleteAccountAsync_Success_SignsOutAndClearsConfirmation()
    {
        var fake = new FakeAccountService { State = AccountSessionState.SignedIn, DeleteAccountResult = new DeleteAccountResult(DeleteAccountOutcome.Deleted) };
        fake.OnDeleteAccountSucceeded = () => fake.State = AccountSessionState.SignedOut;
        var vm = new AccountViewModel(fake);
        vm.RequestDeleteAccount();

        await vm.ConfirmDeleteAccountAsync();

        Assert.Equal(1, fake.DeleteAccountCallCount);
        Assert.False(vm.IsSignedIn);
        Assert.False(vm.DeleteConfirmationPending);
        Assert.Null(vm.ErrorMessage);
    }

    [Fact]
    public async Task ConfirmDeleteAccountAsync_Failure_SetsErrorMessage_ClearsConfirmationAnyway()
    {
        var fake = new FakeAccountService { State = AccountSessionState.SignedIn, DeleteAccountResult = new DeleteAccountResult(DeleteAccountOutcome.ServerError, "try again") };
        var vm = new AccountViewModel(fake);
        vm.RequestDeleteAccount();

        await vm.ConfirmDeleteAccountAsync();

        Assert.Equal("try again", vm.ErrorMessage);
        Assert.True(vm.IsSignedIn); // account was NOT deleted on failure
        // Confirmation UI collapses either way — user can just click Delete again rather than being
        // stuck in a permanent "are you sure" state.
        Assert.False(vm.DeleteConfirmationPending);
    }

    // MARK: - Quota / tier display

    [Fact]
    public void QuotaLine_NoStatusYet_ShowsChecking()
    {
        var fake = new FakeAccountService { State = AccountSessionState.SignedIn, CachedStatus = null };
        var vm = new AccountViewModel(fake);

        Assert.Contains("checking", vm.QuotaLine, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void QuotaLine_FreeTier_ShowsOnlyParseCount()
    {
        var fake = new FakeAccountService { State = AccountSessionState.SignedIn, CachedStatus = FreeStatus(parseUsed: 5) };
        var vm = new AccountViewModel(fake);

        Assert.Equal("15/20 AI parses left today", vm.QuotaLine);
        Assert.False(vm.IsPro);
        Assert.Equal("Free", vm.TierLabel);
    }

    [Fact]
    public void QuotaLine_ProTier_ShowsBothParseAndSpeechCounts()
    {
        var fake = new FakeAccountService { State = AccountSessionState.SignedIn, CachedStatus = ProStatus(parseUsed: 10, speechUsed: 2) };
        var vm = new AccountViewModel(fake);

        Assert.Equal("490/500 AI parses left today · 498/500 cloud transcriptions left today", vm.QuotaLine);
        Assert.True(vm.IsPro);
        Assert.Equal("Pro", vm.TierLabel);
    }

    [Theory]
    [InlineData(AccountSessionState.SignedOut, null, false)]
    [InlineData(AccountSessionState.SignedIn, "free", true)]
    [InlineData(AccountSessionState.SignedIn, "pro", false)]
    public void CanUpgrade_OnlyTrueWhenSignedInAndFreeTier(AccountSessionState state, string? tier, bool expected)
    {
        var fake = new FakeAccountService
        {
            State = state,
            CachedStatus = tier is null ? null : new SubscriptionStatusSnapshot(tier, null, 0, 20, 0, 0, DateTimeOffset.UtcNow),
        };
        var vm = new AccountViewModel(fake);

        Assert.Equal(expected, vm.CanUpgrade);
    }

    // MARK: - Changed event propagation

    [Fact]
    public void AccountServiceChanged_RaisesRelevantProperties()
    {
        var fake = new FakeAccountService();
        var vm = new AccountViewModel(fake);
        var raised = new List<string>();
        vm.PropertyChanged += (_, e) => raised.Add(e.PropertyName!);

        fake.State = AccountSessionState.SignedIn;
        fake.RaiseChanged();

        Assert.Contains(nameof(AccountViewModel.IsSignedIn), raised);
        Assert.Contains(nameof(AccountViewModel.QuotaLine), raised);
    }

    // MARK: - No PropertyChanged storm while typing (UX regression guard — see AccountViewModel's
    // own EmailInput/CodeInput doc comments for why this matters: the View rebuilds its whole tab on
    // every PropertyChanged, which would steal focus/cursor position from a TextBox on every
    // keystroke if these setters raised it).

    [Fact]
    public void EmailInput_Set_NeverRaisesPropertyChanged()
    {
        var vm = new AccountViewModel(new FakeAccountService());
        var raisedAnything = false;
        vm.PropertyChanged += (_, _) => raisedAnything = true;

        vm.EmailInput = "a@b.com";
        vm.EmailInput = "a@b.co";

        Assert.False(raisedAnything);
    }

    [Fact]
    public void CodeInput_Set_NeverRaisesPropertyChanged()
    {
        var vm = new AccountViewModel(new FakeAccountService());
        var raisedAnything = false;
        vm.PropertyChanged += (_, _) => raisedAnything = true;

        vm.CodeInput = "1";
        vm.CodeInput = "12";

        Assert.False(raisedAnything);
    }
}
