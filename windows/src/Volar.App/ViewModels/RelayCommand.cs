// ViewModels/RelayCommand.cs — tiny System.Windows.Input.ICommand helper shared by this wave's B3
// modal ViewModels (TaskDetail/TaskBreakdown/Triage/Sweep/MorningFrog). No MVVM toolkit dependency
// exists in this solution yet (wave4-contract.md frozen decision 2: "No new NuGet packages") and
// `Views/Controls/ToolButton.xaml.cs` already exposes a plain `ICommand? Command` property, so a
// standard WinUI `Button.Command="{x:Bind ...}"` binding needs a concrete `ICommand` on the VM side
// — this is that concrete type. Plain BCL `System.Windows.Input.ICommand`, not a XAML/UI type, so
// holding one on a VM does not violate wave4-contract.md decision 12's "no XAML control types
// inside VMs" rule (same reasoning ToolButton.xaml.cs's own `Command` property already relies on).
using System.Windows.Input;

namespace Volar.App.ViewModels;

/// <summary>Parameterless command — wraps a synchronous <see cref="Action"/>. For an
/// async/fire-and-forget handler (e.g. a command that awaits a service call), pass a lambda that
/// starts the async work and discards the task (`() => _ = DoWorkAsync()`); every VM in this wave
/// that needs this documents the discard at its call site.</summary>
public sealed class RelayCommand : ICommand
{
    private readonly Action _execute;
    private readonly Func<bool>? _canExecute;

    public RelayCommand(Action execute, Func<bool>? canExecute = null)
    {
        _execute = execute ?? throw new ArgumentNullException(nameof(execute));
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    public bool CanExecute(object? parameter) => _canExecute?.Invoke() ?? true;

    public void Execute(object? parameter) => _execute();

    /// <summary>Call after whatever external state <see cref="_canExecute"/> reads has changed, so
    /// a bound `Button.IsEnabled` (WinUI wires this to `CanExecute` automatically) re-evaluates.</summary>
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

/// <summary>Single-parameter command — every row-scoped action in Triage/Sweep/MorningFrog
/// (Keep/Break down/Defer/Drop/Complete/Skip/Pick, each keyed by the row's <c>TaskItem</c>/
/// <c>Guid</c>) needs the acted-on item passed through, which the parameterless
/// <see cref="RelayCommand"/> above cannot carry. Deliberately NOT generic over `T?` (a value-type
/// `T` like `TaskItem` would make every caller juggle `Nullable&lt;TaskItem&gt;`): every caller in
/// this wave always supplies a real, non-null `CommandParameter` (a live row's `TaskItem`/`Guid`),
/// so a null `parameter` is treated as caller error (throws on unbox), not a silent no-op.</summary>
public sealed class RelayCommand<T> : ICommand
{
    private readonly Action<T> _execute;
    private readonly Func<T, bool>? _canExecute;

    public RelayCommand(Action<T> execute, Func<T, bool>? canExecute = null)
    {
        _execute = execute ?? throw new ArgumentNullException(nameof(execute));
        _canExecute = canExecute;
    }

    public event EventHandler? CanExecuteChanged;

    /// <summary>An unresolved/null `CommandParameter` (e.g. before XAML data-binding first runs)
    /// is treated as "not yet executable" rather than an error, matching how a plain WinUI
    /// `Button.Command` binding probes `CanExecute` before the row's `CommandParameter` is set.</summary>
    public bool CanExecute(object? parameter) => parameter is T value && (_canExecute?.Invoke(value) ?? true);

    public void Execute(object? parameter)
    {
        if (parameter is T value)
        {
            _execute(value);
        }
    }

    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
