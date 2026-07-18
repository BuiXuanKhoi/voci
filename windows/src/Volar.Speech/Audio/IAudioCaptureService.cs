// Audio/IAudioCaptureService.cs — extracted so GroqEngine/WhisperNetEngine can be unit-tested
// with a fake in place of real WASAPI hardware (per the W1-D brief: "Phần chạm phần cứng ...
// không unit-test được — hãy đặt sau interface và test bằng fake/mock").
namespace Volar.Speech.Audio;

public interface IAudioCaptureService : IDisposable
{
    bool IsRunning { get; }

    /// <summary>See <see cref="AudioCaptureService.MaxDuration"/>.</summary>
    TimeSpan? MaxDuration { get; set; }

    event Action<Exception>? OnError;

    Task<bool> RequestAuthorizationAsync(CancellationToken cancellationToken = default);

    void Start();

    Task<string> StopAsync(CancellationToken cancellationToken = default);

    void Cancel();
}
