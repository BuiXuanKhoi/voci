// ViewModels/AccountViewModel.cs — backs the new Settings "Account" tab (account-auth contract,
// specs/002-workflow-command-center/contracts/account-auth.md, 2026-07-26). Follows the SAME
// pattern SettingsViewModel.cs's own header comment establishes for this wave: plain
// INotifyPropertyChanged class, no XAML types, no ICommand wrapper — "commands" are just plain
// public methods the View's code-behind calls directly from a control's click/selection event.
using Volar.App.Services.Account;

namespace Volar.App.ViewModels;

/// <summary>
/// Sign-in (email OTP), sign-out, tier/quota display, and delete-account flow. Headless-constructible
/// against any <see cref="IAccountService"/> (real or fake) — <see cref="Views.SettingsView"/>'s
/// code-behind constructs the real one via <c>App.Services.GetRequiredService&lt;IAccountService&gt;()</c>
/// (see that file's <c>Attach</c> method), never resolving THIS view-model type through DI itself —
/// matches this port's "ViewModels are plain `new`, only Wave-3-C SERVICES are container-resolved"
/// convention (CompositionRoot.cs's own closing doc comment).
/// </summary>
public sealed class AccountViewModel : System.ComponentModel.INotifyPropertyChanged
{
    private readonly IAccountService _account;
    private readonly Microsoft.UI.Dispatching.DispatcherQueue? _dispatcherQueue;

    private string _emailInput = string.Empty;
    private string _codeInput = string.Empty;
    private bool _codeSent;
    private bool _busy;
    private string? _errorMessage;
    private bool _deleteConfirmationPending;

    public AccountViewModel(IAccountService accountService, Microsoft.UI.Dispatching.DispatcherQueue? dispatcherQueue = null)
    {
        _account = accountService ?? throw new ArgumentNullException(nameof(accountService));
        _dispatcherQueue = dispatcherQueue;
        _account.Changed += OnAccountChanged;

        if (_account.State == AccountSessionState.SignedIn)
        {
            // Fire-and-forget: the Account tab should show a fresh quota line as soon as it's
            // opened, not whatever was cached from the last app launch. AccountService.RefreshStatusAsync
            // already swallows every failure into a "keep whatever was cached" no-op.
            _ = _account.RefreshStatusAsync();
        }
    }

    public event System.ComponentModel.PropertyChangedEventHandler? PropertyChanged;

    private void OnAccountChanged() =>
        UiDispatch.Post(_dispatcherQueue, () => Raise(
            nameof(IsSignedIn), nameof(Email), nameof(IsPro), nameof(TierLabel), nameof(QuotaLine), nameof(CanUpgrade)));

    private void Raise(params string[] propertyNames)
    {
        foreach (var name in propertyNames)
        {
            PropertyChanged?.Invoke(this, new System.ComponentModel.PropertyChangedEventArgs(name));
        }
    }

    // ============================================================================================
    // MARK: - Signed-out flow (email OTP)
    // ============================================================================================

    /// <summary>Live-typed text, read by the View's code-behind on every keystroke. Deliberately
    /// does NOT raise <see cref="PropertyChanged"/> on every set — this view is rebuilt wholesale on
    /// each notification (see SettingsView.xaml.cs's own "programmatic tab" design), and raising here
    /// would rebuild (and lose focus/cursor position in) the email TextBox on every keystroke.</summary>
    public string EmailInput
    {
        get => _emailInput;
        set => _emailInput = value ?? string.Empty;
    }

    /// <summary>Same "no PropertyChanged per keystroke" rationale as <see cref="EmailInput"/>.</summary>
    public string CodeInput
    {
        get => _codeInput;
        set => _codeInput = value ?? string.Empty;
    }

    public bool CodeSent => _codeSent;

    public bool Busy => _busy;

    public string? ErrorMessage => _errorMessage;

    /// <summary>Apple sign-in on the Mac app hides the real email address behind a relay UNTIL the
    /// user chooses to share it — the account still gets created either way (contract §2's Apple
    /// path), but Windows has no native Sign in with Apple (no Windows equivalent to
    /// `ASAuthorizationAppleIDRequest`), so Email OTP is the ONLY sign-in path this port implements.
    /// A user whose account has no real email on file (they used Apple's private-relay option)
    /// cannot complete OTP here — surfaced as a permanent, non-error explanatory line under the
    /// email field, never a crash or a dead-end error after they try.</summary>
    public const string AppleSignInLimitationNote =
        "Signed up with Apple and hid your email on Mac? Email code sign-in won't work for that account here — sign in on the Mac app instead, or create a new Volar account with your real email.";

    public async Task SendCodeAsync()
    {
        if (_busy)
        {
            return;
        }
        SetBusy(true);
        var result = await _account.SendOtpAsync(_emailInput).ConfigureAwait(false);
        UiDispatch.Post(_dispatcherQueue, () =>
        {
            _busy = false;
            if (result.Outcome == OtpSendOutcome.Sent)
            {
                _codeSent = true;
                _errorMessage = null;
            }
            else
            {
                _errorMessage = result.ErrorMessage ?? "Couldn't send the code. Try again.";
            }
            Raise(nameof(Busy), nameof(CodeSent), nameof(ErrorMessage));
        });
    }

    public async Task VerifyCodeAsync()
    {
        if (_busy)
        {
            return;
        }
        SetBusy(true);
        var result = await _account.VerifyOtpAsync(_emailInput, _codeInput).ConfigureAwait(false);
        UiDispatch.Post(_dispatcherQueue, () =>
        {
            _busy = false;
            if (result.Outcome == VerifyOtpOutcome.SignedIn)
            {
                _errorMessage = null;
                _codeSent = false;
                _codeInput = string.Empty;
                _emailInput = string.Empty;
            }
            else
            {
                _errorMessage = result.ErrorMessage ?? "Couldn't verify that code. Try again.";
            }
            Raise(nameof(Busy), nameof(CodeSent), nameof(ErrorMessage), nameof(IsSignedIn), nameof(Email), nameof(IsPro), nameof(TierLabel), nameof(QuotaLine), nameof(CanUpgrade));
        });
    }

    private void SetBusy(bool value)
    {
        _busy = value;
        Raise(nameof(Busy));
    }

    // ============================================================================================
    // MARK: - Signed-in flow
    // ============================================================================================

    public bool IsSignedIn => _account.State == AccountSessionState.SignedIn;

    public string? Email => _account.CurrentUser?.Email;

    private SubscriptionStatusSnapshot? Status => _account.CachedStatus;

    public bool IsPro => Status?.IsPro ?? false;

    public string TierLabel => IsPro ? "Pro" : "Free";

    public string QuotaLine
    {
        get
        {
            var status = Status;
            if (status is null)
            {
                return "Usage — checking…";
            }
            var parseLeft = Math.Max(status.ParseLimit - status.ParseUsedToday, 0);
            var parseLine = $"{parseLeft}/{status.ParseLimit} AI parses left today";
            if (!status.IsPro)
            {
                return parseLine;
            }
            var speechLeft = Math.Max(status.SpeechLimit - status.SpeechUsedToday, 0);
            return $"{parseLine} · {speechLeft}/{status.SpeechLimit} cloud transcriptions left today";
        }
    }

    /// <summary>Windows has no Store IAP (unpackaged app — <c>EnableMsixTooling=false</c>), so this
    /// is purely informational: a free-tier signed-in user should see an explanation that Pro is
    /// purchased in the Mac app and applies here automatically once active, NEVER a purchase
    /// button.</summary>
    public bool CanUpgrade => IsSignedIn && !IsPro;

    public const string UpgradeHint =
        "Volar Pro is purchased in the Volar Mac app. Once it's active on your account, this PC picks it up automatically — no separate purchase needed here.";

    public async Task SignOutAsync()
    {
        if (_busy)
        {
            return;
        }
        SetBusy(true);
        await _account.SignOutAsync().ConfigureAwait(false);
        UiDispatch.Post(_dispatcherQueue, () =>
        {
            _busy = false;
            _errorMessage = null;
            _deleteConfirmationPending = false;
            Raise(nameof(Busy), nameof(IsSignedIn), nameof(Email), nameof(IsPro), nameof(TierLabel), nameof(QuotaLine), nameof(CanUpgrade), nameof(DeleteConfirmationPending));
        });
    }

    public bool DeleteConfirmationPending => _deleteConfirmationPending;

    /// <summary>Step 1 of the destructive delete-account flow — just asks the View to show the
    /// confirmation UI; performs no network call yet.</summary>
    public void RequestDeleteAccount()
    {
        _deleteConfirmationPending = true;
        Raise(nameof(DeleteConfirmationPending));
    }

    public void CancelDeleteAccount()
    {
        _deleteConfirmationPending = false;
        Raise(nameof(DeleteConfirmationPending));
    }

    /// <summary>Step 2 — the actual destructive call, only reachable after
    /// <see cref="RequestDeleteAccount"/> already flipped <see cref="DeleteConfirmationPending"/>.</summary>
    public async Task ConfirmDeleteAccountAsync()
    {
        if (_busy)
        {
            return;
        }
        SetBusy(true);
        var result = await _account.DeleteAccountAsync().ConfigureAwait(false);
        UiDispatch.Post(_dispatcherQueue, () =>
        {
            _busy = false;
            _deleteConfirmationPending = false;
            _errorMessage = result.Outcome == DeleteAccountOutcome.Deleted
                ? null
                : result.ErrorMessage ?? "Couldn't delete your account. Try again.";
            Raise(nameof(Busy), nameof(DeleteConfirmationPending), nameof(ErrorMessage), nameof(IsSignedIn), nameof(Email), nameof(IsPro), nameof(TierLabel), nameof(QuotaLine), nameof(CanUpgrade));
        });
    }
}
