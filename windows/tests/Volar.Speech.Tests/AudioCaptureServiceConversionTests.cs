// AudioCaptureServiceConversionTests.cs — the one piece of AudioCaptureService that can run
// without a real microphone: the post-capture format conversion (downmix + resample + 16-bit PCM
// WAV write). Per the W1-D brief: "chuyển đổi format audio" is one of the required coverage areas.
using NAudio.Wave;
using Volar.Speech.Audio;
using Xunit;

namespace Volar.Speech.Tests;

public class AudioCaptureServiceConversionTests
{
    [Fact]
    public void ConvertToWavFile_MonoInput_ProducesTargetFormat()
    {
        var format = new WaveFormat(44_100, 16, 1);
        var raw = MakeSilentPcm16(format, TimeSpan.FromMilliseconds(500));

        var path = AudioCaptureService.ConvertToWavFile(raw, format);
        try
        {
            using var reader = new WaveFileReader(path);
            Assert.Equal(AudioCaptureService.TargetSampleRate, reader.WaveFormat.SampleRate);
            Assert.Equal(AudioCaptureService.TargetChannels, reader.WaveFormat.Channels);
            Assert.Equal(AudioCaptureService.TargetBitsPerSample, reader.WaveFormat.BitsPerSample);
            Assert.True(reader.Length > 0);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ConvertToWavFile_StereoInput_DownmixesToMono()
    {
        var format = new WaveFormat(48_000, 16, 2);
        var raw = MakeSilentPcm16(format, TimeSpan.FromMilliseconds(300));

        var path = AudioCaptureService.ConvertToWavFile(raw, format);
        try
        {
            using var reader = new WaveFileReader(path);
            Assert.Equal(1, reader.WaveFormat.Channels);
            Assert.Equal(16_000, reader.WaveFormat.SampleRate);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ConvertToWavFile_AlreadyAtTargetRate_StillProducesValidMono16Bit()
    {
        var format = new WaveFormat(16_000, 16, 1);
        var raw = MakeSilentPcm16(format, TimeSpan.FromMilliseconds(200));

        var path = AudioCaptureService.ConvertToWavFile(raw, format);
        try
        {
            using var reader = new WaveFileReader(path);
            Assert.Equal(16_000, reader.WaveFormat.SampleRate);
            Assert.Equal(1, reader.WaveFormat.Channels);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void DownmixToMonoSampleProvider_AveragesInterleavedChannels()
    {
        // Two channels, 3 frames: (L,R) pairs (1,3) (2,4) (0,0) -> mono averages should be (2,3,0).
        var source = new StubSampleProvider(WaveFormat.CreateIeeeFloatWaveFormat(44_100, 2), [1f, 3f, 2f, 4f, 0f, 0f]);
        var downmix = new AudioCaptureService.DownmixToMonoSampleProvider(source);

        var buffer = new float[3];
        var read = downmix.Read(buffer, 0, 3);

        Assert.Equal(3, read);
        Assert.Equal(2f, buffer[0]);
        Assert.Equal(3f, buffer[1]);
        Assert.Equal(0f, buffer[2]);
        Assert.Equal(1, downmix.WaveFormat.Channels);
    }

    [Fact]
    public void DownmixToMonoSampleProvider_PassesThroughMonoSourceUnchanged()
    {
        var source = new StubSampleProvider(WaveFormat.CreateIeeeFloatWaveFormat(44_100, 1), [0.5f, -0.25f]);
        var downmix = new AudioCaptureService.DownmixToMonoSampleProvider(source);

        var buffer = new float[2];
        downmix.Read(buffer, 0, 2);

        Assert.Equal(0.5f, buffer[0]);
        Assert.Equal(-0.25f, buffer[1]);
    }

    private static byte[] MakeSilentPcm16(WaveFormat format, TimeSpan duration)
    {
        var frameCount = (int)(format.SampleRate * duration.TotalSeconds);
        var byteCount = frameCount * format.Channels * (format.BitsPerSample / 8);
        return new byte[byteCount]; // all-zero == silence, valid 16-bit PCM
    }

    /// <summary>Hands back fixed float samples regardless of how many are requested — enough for
    /// the small, exact reads these tests perform.</summary>
    private sealed class StubSampleProvider(WaveFormat waveFormat, float[] samples) : NAudio.Wave.ISampleProvider
    {
        private int _position;
        public WaveFormat WaveFormat { get; } = waveFormat;

        public int Read(float[] buffer, int offset, int count)
        {
            var toCopy = Math.Min(count, samples.Length - _position);
            Array.Copy(samples, _position, buffer, offset, toCopy);
            _position += toCopy;
            return toCopy;
        }
    }
}
