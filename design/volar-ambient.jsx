// volar-ambient.jsx — ambient focus backgrounds (rain/snow/fireflies/custom image),
// ambient sound (Web Audio), and voice playback (speech synthesis)

const { useRef: useRefAmb, useEffect: useEffectAmb, useState: useStateAmb } = React;

const AMBIENT_MODES = [
  { value: 'none',   label: 'None' },
  { value: 'rain',   label: 'Rain' },
  { value: 'snow',   label: 'Snow' },
  { value: 'embers', label: 'Fireflies' },
  { value: 'custom', label: 'Custom image' },
];

const AMBIENT_BACKDROPS = {
  rain:   'linear-gradient(180deg, #0c1220 0%, #101a2e 55%, #090e1a 100%)',
  snow:   'linear-gradient(180deg, #0e1422 0%, #16203a 60%, #0b101e 100%)',
  embers: 'linear-gradient(180deg, #120d0c 0%, #1c120e 60%, #0d0908 100%)',
  custom: '#101014',
};

// ─── Animated background canvas ──────────────────────────────────────────────
function AmbientBackground({ mode = 'rain', imageUrl = '', animated = true, intensity = 1 }) {
  const canvasRef = useRefAmb(null);

  useEffectAmb(() => {
    if (mode === 'none' || mode === 'custom' || intensity <= 0) return;
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext('2d');
    const dpr = window.devicePixelRatio || 1;
    let W = 0, H = 0, raf = 0, running = true;

    const resize = () => {
      W = canvas.width = Math.max(1, canvas.offsetWidth * dpr);
      H = canvas.height = Math.max(1, canvas.offsetHeight * dpr);
    };
    resize();
    const ro = new ResizeObserver(resize);
    ro.observe(canvas);

    const rand = (a, b) => a + Math.random() * (b - a);
    const base = mode === 'rain' ? 130 : mode === 'snow' ? 90 : 38;
    const count = Math.max(1, Math.round(base * intensity));
    const oMul = 0.35 + 0.65 * intensity;
    const ps = [];
    for (let i = 0; i < count; i++) {
      if (mode === 'rain') {
        ps.push({ x: rand(0, 1), y: rand(0, 1), len: rand(0.02, 0.05), sp: rand(0.55, 1.25), o: rand(0.10, 0.34) * oMul });
      } else if (mode === 'snow') {
        ps.push({ x: rand(0, 1), y: rand(0, 1), r: rand(0.8, 2.6), sp: rand(0.03, 0.09), o: rand(0.18, 0.6) * oMul, ph: rand(0, 6.28) });
      } else {
        ps.push({ x: rand(0.04, 0.96), y: rand(0.1, 0.95), r: rand(1, 2.6), sp: rand(0.006, 0.02), o: rand(0.25, 0.7) * oMul, ph: rand(0, 6.28) });
      }
    }

    let t = 0;
    const frame = () => {
      t += 0.016;
      ctx.clearRect(0, 0, W, H);
      if (mode === 'rain') {
        ctx.lineWidth = dpr;
        ctx.lineCap = 'round';
        for (const p of ps) {
          p.y += p.sp * 0.016;
          if (p.y > 1.04) { p.y = -0.06; p.x = Math.random(); }
          const x = p.x * W, y = p.y * H;
          ctx.strokeStyle = `rgba(172,194,235,${p.o})`;
          ctx.beginPath();
          ctx.moveTo(x, y);
          ctx.lineTo(x - p.len * H * 0.12, y + p.len * H);
          ctx.stroke();
        }
      } else if (mode === 'snow') {
        for (const p of ps) {
          p.y += p.sp * 0.016;
          p.x += Math.sin(t * 0.7 + p.ph) * 0.0004;
          if (p.y > 1.03) { p.y = -0.03; p.x = Math.random(); }
          ctx.fillStyle = `rgba(230,238,252,${p.o})`;
          ctx.beginPath();
          ctx.arc(p.x * W, p.y * H, p.r * dpr, 0, 6.283);
          ctx.fill();
        }
      } else {
        for (const p of ps) {
          p.y -= p.sp * 0.016;
          p.x += Math.sin(t * 0.35 + p.ph) * 0.0004;
          if (p.y < -0.03) { p.y = 1.03; p.x = rand(0.04, 0.96); }
          const pulse = 0.45 + 0.55 * Math.abs(Math.sin(t * 1.4 + p.ph));
          ctx.shadowBlur = 9 * dpr;
          ctx.shadowColor = 'rgba(255,190,110,0.8)';
          ctx.fillStyle = `rgba(255,198,122,${(p.o * pulse).toFixed(3)})`;
          ctx.beginPath();
          ctx.arc(p.x * W, p.y * H, p.r * dpr, 0, 6.283);
          ctx.fill();
          ctx.shadowBlur = 0;
        }
      }
      if (animated && running) raf = requestAnimationFrame(frame);
    };
    frame();

    return () => { running = false; cancelAnimationFrame(raf); ro.disconnect(); };
  }, [mode, animated, intensity]);

  if (mode === 'none') return null;

  return (
    <div style={{
      position: 'absolute', inset: 0, zIndex: 0, overflow: 'hidden',
      background: AMBIENT_BACKDROPS[mode] || AMBIENT_BACKDROPS.rain,
    }}>
      {mode === 'custom' && imageUrl && (
        <img src={imageUrl} alt="" style={{
          position: 'absolute', inset: 0, width: '100%', height: '100%',
          objectFit: 'cover', filter: 'brightness(0.55) saturate(0.9)',
        }} />
      )}
      {mode === 'custom' && !imageUrl && (
        <div style={{
          position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center',
          color: 'rgba(255,255,255,0.28)', fontFamily: VOLAR_MONO, fontSize: 12, letterSpacing: '0.04em',
          background: 'repeating-linear-gradient(135deg, #14141a 0 14px, #17171e 14px 28px)',
        }}>paste an image URL in Tweaks → Focus</div>
      )}
      {mode !== 'custom' && (
        <canvas ref={canvasRef} style={{ position: 'absolute', inset: 0, width: '100%', height: '100%' }} />
      )}
      {/* Vignette so content pops */}
      <div style={{
        position: 'absolute', inset: 0,
        background: 'radial-gradient(120% 90% at 50% 30%, transparent 40%, rgba(0,0,0,0.45) 100%)',
      }} />
    </div>
  );
}

// ─── Ambient sound (synthesized — no assets) ─────────────────────────────────
function useAmbientSound() {
  const ref = useRefAmb(null);
  const [playing, setPlaying] = useStateAmb(false);

  const stop = () => {
    if (ref.current) { try { ref.current.ctx.close(); } catch (e) {} ref.current = null; }
    setPlaying(false);
  };

  const start = (mode = 'rain') => {
    stop();
    try {
      const Ctx = window.AudioContext || window.webkitAudioContext;
      const ctx = new Ctx();
      const len = 2 * ctx.sampleRate;
      const buf = ctx.createBuffer(1, len, ctx.sampleRate);
      const data = buf.getChannelData(0);
      let last = 0;
      for (let i = 0; i < len; i++) {
        const w = Math.random() * 2 - 1;
        last = (last + 0.02 * w) / 1.02;
        data[i] = mode === 'rain' ? w * 0.5 : last * 3.5; // white for rain, brown-ish for wind/fire
      }
      const src = ctx.createBufferSource();
      src.buffer = buf; src.loop = true;
      const filt = ctx.createBiquadFilter();
      filt.type = 'lowpass';
      filt.frequency.value = mode === 'rain' ? 1500 : mode === 'snow' ? 420 : 300;
      const gain = ctx.createGain();
      gain.gain.value = 0;
      src.connect(filt); filt.connect(gain); gain.connect(ctx.destination);
      src.start();
      gain.gain.linearRampToValueAtTime(mode === 'rain' ? 0.10 : 0.13, ctx.currentTime + 1.4);
      ref.current = { ctx };
      setPlaying(true);
    } catch (e) { /* audio unavailable */ }
  };

  const toggle = (mode) => { playing ? stop() : start(mode); };
  useEffectAmb(() => stop, []);
  return { playing, toggle, stop };
}

// ─── Voice playback (speech synthesis) ───────────────────────────────────────
function volarSpeak(text) {
  try {
    const synth = window.speechSynthesis;
    if (!synth) return;
    synth.cancel();
    const u = new SpeechSynthesisUtterance(text);
    u.rate = 1.03; u.pitch = 1;
    synth.speak(u);
  } catch (e) {}
}
function volarStopSpeak() {
  try { window.speechSynthesis && window.speechSynthesis.cancel(); } catch (e) {}
}

Object.assign(window, { AmbientBackground, AMBIENT_MODES, useAmbientSound, volarSpeak, volarStopSpeak });
