// Services/Adapters/WinAppSdkNotificationGateway.cs — the real
// Microsoft.Windows.AppNotifications-backed INativeAppNotificationGateway. See
// AppNotificationToastChannel.cs's file header for why this OS-facing surface is split into its
// own small type (TESTABILITY SEAM). This is the only file in this folder that references the
// Microsoft.Windows.AppNotifications / .Builder namespaces.
//
// Every member independently honors this interface's "never throws" contract (not just relying on
// AppNotificationToastChannel's own try/catch wrapping), so this gateway is safe to use directly
// too.
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;

namespace Volar.App.Services.Adapters;

public sealed class WinAppSdkNotificationGateway : INativeAppNotificationGateway
{
    /// <summary>Toast argument key carrying the pressed button's <see cref="Volar.Reminders.ReminderAction"/>
    /// id (or absent for a plain body-tap activation).</summary>
    private const string ActionArgumentKey = "volarAction";

    /// <summary>Toast argument key carrying the <see cref="Volar.Reminders.ReminderDelivery.RecordId"/>
    /// — also duplicated as the notification's Tag (see <see cref="Show"/>), but arguments are what
    /// <see cref="Microsoft.Windows.AppNotifications.AppNotificationActivatedEventArgs"/> actually
    /// exposes on activation.</summary>
    private const string RecordArgumentKey = "volarRecordId";

    private bool _subscribed;

    public event Action<string, Guid>? Invoked;

    public WinAppSdkNotificationGateway()
    {
        AppNotificationManager.Default.NotificationInvoked += OnNotificationInvoked;
        _subscribed = true;
    }

    public bool Register()
    {
        try
        {
            AppNotificationManager.Default.Register();
            return true;
        }
        catch
        {
            return false;
        }
    }

    private void OnNotificationInvoked(AppNotificationManager sender, AppNotificationActivatedEventArgs args)
    {
        try
        {
            var arguments = args.Arguments;
            if (arguments is null)
            {
                return;
            }
            if (!arguments.TryGetValue(ActionArgumentKey, out var actionId))
            {
                return;
            }
            if (!arguments.TryGetValue(RecordArgumentKey, out var recordRaw) || !Guid.TryParse(recordRaw, out var recordId))
            {
                return;
            }
            Invoked?.Invoke(actionId, recordId);
        }
        catch
        {
            // Never throw out of an OS-invoked callback.
        }
    }

    public void Show(Guid recordId, string title, string body, IReadOnlyList<ToastButtonSpec> buttons)
    {
        try
        {
            var builder = new AppNotificationBuilder();
            builder.AddText(title);
            builder.AddText(body);
            builder.SetTag(recordId.ToString());
            foreach (var button in buttons)
            {
                var appButton = new AppNotificationButton(button.Label);
                appButton.AddArgument(ActionArgumentKey, button.ActionId);
                appButton.AddArgument(RecordArgumentKey, recordId.ToString());
                builder.AddButton(appButton);
            }
            var notification = builder.BuildNotification();
            AppNotificationManager.Default.Show(notification);
        }
        catch
        {
            // Degrade quietly — Focus Assist, notifications disabled by policy, not registered, ...
        }
    }

    public IReadOnlyList<Guid> GetDeliveredIds()
    {
        try
        {
            var notifications = AppNotificationManager.Default.GetAllAsync().GetAwaiter().GetResult();
            var result = new List<Guid>(notifications.Count);
            foreach (var notification in notifications)
            {
                if (Guid.TryParse(notification.Tag, out var id))
                {
                    result.Add(id);
                }
            }
            return result;
        }
        catch
        {
            return Array.Empty<Guid>();
        }
    }

    public void RemoveByTag(Guid recordId)
    {
        try
        {
            _ = AppNotificationManager.Default.RemoveByTagAsync(recordId.ToString());
        }
        catch
        {
            // Best-effort.
        }
    }

    public void Dispose()
    {
        try
        {
            if (_subscribed)
            {
                AppNotificationManager.Default.NotificationInvoked -= OnNotificationInvoked;
                _subscribed = false;
            }
            AppNotificationManager.Default.Unregister();
        }
        catch
        {
            // Best-effort.
        }
    }
}
