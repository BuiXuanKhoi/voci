// Services/Account/Dpapi.cs — thin P/Invoke wrapper around Windows DPAPI (crypt32.dll's
// CryptProtectData/CryptUnprotectData), CurrentUser scope.
//
// WHY RAW P/INVOKE INSTEAD OF System.Security.Cryptography.ProtectedData: that BCL wrapper type
// ships either in the `System.Security.Cryptography.ProtectedData` NuGet package or as part of the
// `Microsoft.WindowsDesktop.App` shared framework (confirmed present under
// `C:\Program Files\dotnet\shared\Microsoft.WindowsDesktop.App\...` on this machine) — Volar.App is
// a plain `Microsoft.NET.Sdk` + `UseWinUI=true` project (NOT `Microsoft.NET.Sdk.WindowsDesktop`),
// and its restored NuGet graph does not currently pull that package in transitively (checked
// `obj/project.assets.json` — no hit). Adding either is a Volar.App.csproj edit, which is outside
// this task's file-ownership scope ("No new NuGet packages... the csproj is owned by another
// agent"). `crypt32.dll` is a standard Windows system DLL present on every supported Windows
// version with zero extra dependencies, so this wrapper needs nothing new added anywhere.
//
// Scope: NO `CRYPTPROTECT_LOCAL_MACHINE` flag is ever passed, so protection is implicitly
// per-current-Windows-user — identical semantics to
// `ProtectedData.Protect(data, entropy, DataProtectionScope.CurrentUser)`. No optional entropy is
// used (an empty/absent entropy blob is a null pointer, same as `ProtectedData`'s own default when
// no `optionalEntropy` is supplied).
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace Volar.App.Services.Account;

/// <summary>
/// <see langword="public"/> (not <see langword="internal"/>) so <c>Volar.App.Tests</c> can exercise
/// the real P/Invoke round-trip directly (see Services/Account/DpapiTokenStoreTests.cs) without an
/// <c>InternalsVisibleTo</c> entry — Volar.App.csproj carries none today, and adding one is a csproj
/// edit outside this task's scope (same constraint <c>AppNotificationToastChannel.cs</c>'s own doc
/// comment and <c>ThemeState.cs</c>'s already establish elsewhere in this project: widen visibility
/// instead of touching the csproj).
/// </summary>
public static class Dpapi
{
    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int CbData;
        public IntPtr PbData;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn,
        string? dataDescr,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr promptStruct,
        uint flags,
        out DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn,
        IntPtr dataDescr,
        IntPtr optionalEntropy,
        IntPtr reserved,
        IntPtr promptStruct,
        uint flags,
        out DataBlob dataOut);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr hMem);

    /// <summary>CRYPTPROTECT_UI_FORBIDDEN — never allow the OS to show a UI prompt. There should
    /// never be one for CurrentUser-scope protection on the same machine anyway; this is
    /// belt-and-suspenders so a headless/service context can never hang on a hidden dialog.</summary>
    private const uint CryptProtectUiForbidden = 0x1;

    /// <summary>Encrypts <paramref name="plaintext"/> for the CURRENT Windows user only — only a
    /// process running as this same user account on this same machine can ever decrypt the
    /// result.</summary>
    /// <exception cref="Win32Exception">The OS call itself failed (should be exceedingly rare —
    /// e.g. no user profile loaded). Callers (<see cref="DpapiTokenStore"/>) catch this and degrade
    /// to "couldn't persist," never propagating it further, per this feature's "a token-storage
    /// problem must never crash the app" contract.</exception>
    public static byte[] Protect(byte[] plaintext)
    {
        var inBlob = ToBlob(plaintext);
        try
        {
            if (!CryptProtectData(ref inBlob, null, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CryptProtectUiForbidden, out var outBlob))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return FromBlobAndFree(outBlob);
        }
        finally
        {
            FreeInputBlob(inBlob);
        }
    }

    /// <returns><see langword="null"/> on ANY failure (corrupt data, encrypted by a different user/
    /// machine, OS error) — callers treat that identically to "no session stored," never throwing
    /// further (matches <see cref="Volar.Data.JsonFileSettingsStore"/>'s own "a settings/token
    /// problem must never crash the app" convention).</returns>
    public static byte[]? Unprotect(byte[] ciphertext)
    {
        var inBlob = ToBlob(ciphertext);
        try
        {
            if (!CryptUnprotectData(ref inBlob, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, CryptProtectUiForbidden, out var outBlob))
            {
                return null;
            }
            return FromBlobAndFree(outBlob);
        }
        catch
        {
            return null;
        }
        finally
        {
            FreeInputBlob(inBlob);
        }
    }

    private static DataBlob ToBlob(byte[] data)
    {
        var handle = data.Length == 0 ? Marshal.AllocHGlobal(1) : Marshal.AllocHGlobal(data.Length);
        if (data.Length > 0)
        {
            Marshal.Copy(data, 0, handle, data.Length);
        }
        return new DataBlob { CbData = data.Length, PbData = handle };
    }

    private static void FreeInputBlob(DataBlob blob)
    {
        if (blob.PbData != IntPtr.Zero)
        {
            Marshal.FreeHGlobal(blob.PbData);
        }
    }

    /// <summary>The OS allocates <paramref name="blob"/>'s buffer via <c>LocalAlloc</c> internally
    /// (per the CryptProtectData/CryptUnprotectData docs) — it MUST be freed with
    /// <see cref="LocalFree"/>, never <see cref="Marshal.FreeHGlobal"/>.</summary>
    private static byte[] FromBlobAndFree(DataBlob blob)
    {
        try
        {
            if (blob.PbData == IntPtr.Zero || blob.CbData <= 0)
            {
                return Array.Empty<byte>();
            }
            var result = new byte[blob.CbData];
            Marshal.Copy(blob.PbData, result, 0, blob.CbData);
            return result;
        }
        finally
        {
            if (blob.PbData != IntPtr.Zero)
            {
                LocalFree(blob.PbData);
            }
        }
    }
}
