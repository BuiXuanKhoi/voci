// Ambient/AmbientMode.cs — ported from Sources/Audio/AmbientSound.swift's `AmbientMode` usage.
//
// The Swift file references an `AmbientMode` type defined elsewhere (Sources/Design or similar) —
// not itself one of the 8 files in scope for this port, so its cases are reconstructed here from
// how AmbientSound.swift uses them (`.none`, `.rain`, `.snow`, `.embers`, `.custom`, plus the
// guard `mode == .rain || mode == .snow || mode == .embers || mode == .custom` implying at least
// one more case exists that IS silently a no-op — the guard wouldn't be needed otherwise). Kept
// minimal and scoped to exactly what AmbientSoundPlayer needs.
namespace Volar.Speech.Ambient;

public enum AmbientMode
{
    /// <summary>No ambient sound (and, on mac, no ambient visual either).</summary>
    None,
    Rain,
    Snow,
    Embers,
    /// <summary>User-supplied background image with no synthesized sound of its own — mapped to
    /// the same sound as <see cref="Rain"/>, exactly like the mac source.</summary>
    Custom,
}
