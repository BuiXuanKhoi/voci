// voci-popover.jsx — animated quick capture popover
// States: idle → recording (waveform + streaming transcript) → parsed (card + buttons) → saving → done | error
//
// Controlled mode: pass `state` + `onCancel` + `onSave`
// Uncontrolled / demo mode: pass `autoplay` and it loops through states for the canvas.

const { useState, useEffect, useRef, useMemo } = React;

// ─── Waveform ────────────────────────────────────────────────────────────────
function Waveform({ active, color, glow, bars = 28, height = 40 }) {
  const rafRef = useRef(null);
  const barRefs = useRef([]);
  const t0 = useRef(performance.now());

  useEffect(() => {
    if (!active) {
      // Settle to a flat line
      barRefs.current.forEach((b) => { if (b) b.style.height = '3px'; });
      return;
    }
    const tick = () => {
      const t = (performance.now() - t0.current) / 1000;
      barRefs.current.forEach((b, i) => {
        if (!b) return;
        const phase = i * 0.35;
        // layered sine for organic feel
        const v = Math.sin(t * 6 + phase) * 0.55 + Math.sin(t * 10 + phase * 1.7) * 0.35 + Math.cos(t * 3 + phase * 0.5) * 0.2;
        const norm = (v + 1.1) / 2.2;
        const env = 0.4 + 0.6 * Math.exp(-Math.pow((i - bars / 2) / (bars / 2.6), 2)); // soft envelope, lower at edges
        const h = Math.max(2, norm * env * (height - 4));
        b.style.height = h + 'px';
      });
      rafRef.current = requestAnimationFrame(tick);
    };
    rafRef.current = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(rafRef.current);
  }, [active, bars, height]);

  return (
    <div style={{
      height, width: '100%', display: 'flex', alignItems: 'center',
      justifyContent: 'center', gap: 3, padding: '0 4px',
    }}>
      {Array.from({ length: bars }).map((_, i) => (
        <div
          key={i}
          ref={(el) => (barRefs.current[i] = el)}
          style={{
            width: 3,
            height: 3,
            background: color,
            borderRadius: 2,
            transition: active ? 'none' : 'height .3s ease',
            boxShadow: active ? `0 0 8px ${glow}` : 'none',
          }}
        />
      ))}
    </div>
  );
}

// ─── Priority badge ──────────────────────────────────────────────────────────
function PriorityBadge({ priority, theme }) {
  const { c } = theme;
  const map = {
    high: { dot: c.high, bg: 'rgba(255,107,107,0.14)', fg: '#ff8b8b', label: 'High' },
    med:  { dot: c.med,  bg: 'rgba(255,179,71,0.14)',  fg: '#ffc279', label: 'Medium' },
    low:  { dot: c.low,  bg: 'rgba(255,255,255,0.05)', fg: c.textSec, label: 'Low' },
  };
  const m = map[priority] || map.low;
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 6,
      height: 22, padding: '0 9px', borderRadius: 20,
      background: m.bg, color: m.fg,
      fontSize: 11.5, fontWeight: 500, letterSpacing: '-0.005em',
    }}>
      <span style={{ width: 6, height: 6, borderRadius: '50%', background: m.dot }} />
      {m.label}
    </span>
  );
}

function TimeBadge({ when, theme }) {
  const { a } = theme;
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', height: 22, padding: '0 9px',
      borderRadius: 20, background: a.surface, color: a.solid,
      fontSize: 11.5, fontWeight: 500, fontVariantNumeric: 'tabular-nums',
    }}>{when}</span>
  );
}

// ─── Main popover ────────────────────────────────────────────────────────────
function VociPopover({
  theme,
  state: ctrlState,
  setState: ctrlSetState,
  transcriptIndex = 0,
  setTranscriptIndex,
  onCancel = () => {},
  onSave = () => {},
  autoplay = false,
  animatedWave = true,
  width = 360,
}) {
  const { c, a, g, font } = theme;

  // local fallback state when uncontrolled
  const [_state, _setState] = useState('recording');
  const state = ctrlState ?? _state;
  const setState = ctrlSetState ?? _setState;

  const example = SAMPLE_TRANSCRIPT_PARSED[transcriptIndex % SAMPLE_TRANSCRIPT_PARSED.length];

  // Streaming text effect for transcript while in 'recording'
  const [streamed, setStreamed] = useState('');
  useEffect(() => {
    if (state !== 'recording') return;
    setStreamed('');
    const full = example.sentence;
    let i = 0;
    const id = setInterval(() => {
      i += 1;
      setStreamed(full.slice(0, i));
      if (i >= full.length) clearInterval(id);
    }, 32);
    return () => clearInterval(id);
  }, [state, transcriptIndex]);

  // Autoplay state machine for canvas previews
  useEffect(() => {
    if (!autoplay) return;
    let timeouts = [];
    const seq = [
      ['recording', 0],
      ['parsing',   3200],
      ['parsed',    3800],
      ['saving',    7400],
      ['done',      8200],
      ['recording', 9200], // loop
    ];
    seq.forEach(([s, t]) => timeouts.push(setTimeout(() => {
      setState(s);
      if (s === 'recording') {
        if (setTranscriptIndex) setTranscriptIndex((i) => (i + 1) % SAMPLE_TRANSCRIPT_PARSED.length);
      }
    }, t)));
    return () => timeouts.forEach(clearTimeout);
  }, [autoplay]);

  // Appear animation
  const [mounted, setMounted] = useState(false);
  useEffect(() => { const id = requestAnimationFrame(() => setMounted(true)); return () => cancelAnimationFrame(id); }, []);

  // Computed visibility
  const showWave = state === 'recording' || state === 'parsing';
  const showTranscript = state !== 'idle' && state !== 'error';
  const showParsedCard = state === 'parsed' || state === 'saving' || state === 'done';
  const showActions = state === 'parsed' || state === 'saving';

  return (
    <div style={{
      width, fontFamily: font, color: c.textPri,
      borderRadius: 18,
      background: g.bg,
      backdropFilter: `blur(${g.blur}px) saturate(180%)`,
      WebkitBackdropFilter: `blur(${g.blur}px) saturate(180%)`,
      border: `0.5px solid ${c.borderHi}`,
      boxShadow: '0 24px 60px rgba(0,0,0,0.55), 0 0 0 0.5px rgba(255,255,255,0.04), inset 0 1px 0 rgba(255,255,255,0.06)',
      padding: '14px 14px 12px',
      transform: mounted ? 'scale(1)' : 'scale(0.96)',
      opacity: mounted ? 1 : 0,
      transition: 'transform 160ms cubic-bezier(.2,.7,.3,1), opacity 120ms ease-out',
    }}>
      {/* hint row */}
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        fontSize: 11.5, color: c.textMut, letterSpacing: '0.01em',
      }}>
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
          {state === 'recording' && (
            <>
              <span style={{
                width: 6, height: 6, borderRadius: '50%', background: c.high,
                boxShadow: `0 0 0 0 ${c.high}`,
                animation: 'voci-pulse 1.2s ease-out infinite',
              }} />
              <span>Listening…</span>
            </>
          )}
          {state === 'parsing' && <span style={{ color: a.solid }}>Parsing with AI…</span>}
          {state === 'parsed' && <span>Looks right? Hit return.</span>}
          {state === 'saving' && <span style={{ color: a.solid }}>Saving…</span>}
          {state === 'done' && <span style={{ color: c.done }}>Saved · 3 today</span>}
          {state === 'error' && <span style={{ color: c.destruct }}>Didn't catch that.</span>}
        </span>
        <span style={{ display: 'inline-flex', gap: 8, alignItems: 'center', color: c.textMut }}>
          <Kbd>Esc</Kbd>
          <span style={{ opacity: 0.6 }}>cancel</span>
        </span>
      </div>

      {/* waveform */}
      <div style={{ marginTop: 10, marginBottom: 6 }}>
        {showWave ? (
          <Waveform active={animatedWave && state === 'recording'} color={a.solid} glow={a.glow} bars={32} height={42} />
        ) : (
          <div style={{ height: 42, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
            {state === 'done' ? (
              <div style={{
                width: 32, height: 32, borderRadius: '50%',
                background: c.done, display: 'flex', alignItems: 'center', justifyContent: 'center',
                boxShadow: `0 0 24px rgba(91,209,122,0.5)`,
              }}>
                <VocIcon name="check" size={18} color="#0e2a16" strokeWidth={2.4} />
              </div>
            ) : state === 'error' ? (
              <div style={{ color: c.destruct, fontSize: 13 }}>Try again</div>
            ) : null}
          </div>
        )}
      </div>

      {/* transcript */}
      {showTranscript && (
        <div style={{
          minHeight: 42,
          padding: '8px 4px 4px',
          fontSize: 14.5,
          lineHeight: 1.4,
          color: c.textPri,
          letterSpacing: '-0.005em',
        }}>
          <span style={{ color: state === 'recording' ? c.textPri : c.textSec }}>
            {state === 'recording' ? streamed : example.sentence}
          </span>
          {state === 'recording' && (
            <span style={{
              display: 'inline-block', width: 2, height: 16, marginLeft: 2,
              verticalAlign: '-3px', background: a.solid,
              animation: 'voci-caret 0.9s steps(2, start) infinite',
            }} />
          )}
        </div>
      )}

      {/* parsed card */}
      {showParsedCard && (
        <div style={{
          marginTop: 6,
          padding: '12px 12px',
          background: c.card,
          border: `0.5px solid ${c.border}`,
          borderRadius: 12,
          display: 'flex', flexDirection: 'column', gap: 8,
          animation: 'voci-rise .35s cubic-bezier(.2,.7,.3,1) both',
        }}>
          <ParseRow label="Task" theme={theme}>
            <span style={{ fontSize: 13.5, fontWeight: 500, color: c.textPri, letterSpacing: '-0.005em' }}>
              {example.parsed.title}
            </span>
          </ParseRow>
          <ParseRow label="When" theme={theme}>
            <TimeBadge when={example.parsed.when} theme={theme} />
          </ParseRow>
          <ParseRow label="Priority" theme={theme}>
            <PriorityBadge priority={example.parsed.priority} theme={theme} />
          </ParseRow>
          <ParseRow label="Context" theme={theme}>
            <span style={{
              display: 'inline-flex', alignItems: 'center', gap: 6,
              fontSize: 12.5, color: c.textSec,
            }}>
              <span style={{ width: 5, height: 5, borderRadius: '50%', background: c.textMut }} />
              {example.parsed.context} · {example.parsed.duration}
            </span>
          </ParseRow>
        </div>
      )}

      {/* actions */}
      {showActions && (
        <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
          <button onClick={onCancel} style={{
            flex: '0 0 auto', padding: '0 14px', height: 34,
            borderRadius: 9,
            background: 'rgba(255,255,255,0.06)',
            border: `0.5px solid ${c.border}`,
            color: c.textPri, fontSize: 13, fontWeight: 500,
            fontFamily: font, cursor: 'default',
          }}>Cancel</button>
          <button onClick={onSave} style={{
            flex: 1, height: 34, borderRadius: 9,
            background: state === 'saving' ? a.surface : a.solid,
            color: state === 'saving' ? a.solid : '#fff',
            border: `0.5px solid ${state === 'saving' ? a.surface : 'rgba(255,255,255,0.18)'}`,
            fontSize: 13, fontWeight: 500, fontFamily: font, cursor: 'default',
            boxShadow: state === 'saving' ? 'none' : `0 6px 18px ${a.glow}, inset 0 0.5px 0 rgba(255,255,255,0.25)`,
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
            letterSpacing: '-0.005em',
            transition: 'background .15s, box-shadow .15s',
          }}>
            {state === 'saving' ? (
              <Spinner color={a.solid} />
            ) : (
              <>
                <span>Save task</span>
                <span style={{ opacity: 0.85, fontSize: 12 }}>↵</span>
              </>
            )}
          </button>
        </div>
      )}

      {/* error retry */}
      {state === 'error' && (
        <div style={{ marginTop: 10, display: 'flex', gap: 8 }}>
          <button onClick={onCancel} style={{
            flex: 1, height: 34, borderRadius: 9,
            background: 'rgba(255,255,255,0.06)',
            border: `0.5px solid ${c.border}`,
            color: c.textPri, fontSize: 13, fontWeight: 500, fontFamily: font, cursor: 'default',
          }}>Dismiss</button>
          <button onClick={() => setState('recording')} style={{
            flex: 1, height: 34, borderRadius: 9,
            background: a.solid, color: '#fff',
            border: `0.5px solid rgba(255,255,255,0.18)`,
            fontSize: 13, fontWeight: 500, fontFamily: font, cursor: 'default',
          }}>Try again</button>
        </div>
      )}

      <style>{`
        @keyframes voci-pulse {
          0%   { box-shadow: 0 0 0 0 ${c.high}80; }
          70%  { box-shadow: 0 0 0 6px ${c.high}00; }
          100% { box-shadow: 0 0 0 0 ${c.high}00; }
        }
        @keyframes voci-caret { 0%, 50% { opacity: 1 } 50.01%, 100% { opacity: 0 } }
        @keyframes voci-rise {
          from { opacity: 0; transform: translateY(6px); }
          to   { opacity: 1; transform: translateY(0); }
        }
      `}</style>
    </div>
  );
}

function ParseRow({ label, children, theme }) {
  const { c } = theme;
  return (
    <div style={{
      display: 'grid',
      gridTemplateColumns: '64px 1fr',
      alignItems: 'center',
      gap: 10,
    }}>
      <span style={{
        fontSize: 10.5, fontWeight: 500, textTransform: 'uppercase', letterSpacing: '0.07em',
        color: c.textMut,
      }}>{label}</span>
      <span style={{ display: 'flex', alignItems: 'center', minWidth: 0 }}>
        {children}
      </span>
    </div>
  );
}

function Kbd({ children, theme }) {
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      minWidth: 16, height: 16, padding: '0 4px', borderRadius: 4,
      background: 'rgba(255,255,255,0.08)',
      border: '0.5px solid rgba(255,255,255,0.10)',
      color: 'rgba(255,255,255,0.65)',
      fontFamily: VOCI_MONO, fontSize: 10, fontWeight: 500,
    }}>{children}</span>
  );
}

function Spinner({ color = '#fff', size = 14 }) {
  return (
    <span style={{
      width: size, height: size, display: 'inline-block',
      borderRadius: '50%',
      border: `1.6px solid ${color}33`,
      borderTopColor: color,
      animation: 'voci-spin 0.7s linear infinite',
    }}>
      <style>{`@keyframes voci-spin { to { transform: rotate(360deg); } }`}</style>
    </span>
  );
}

Object.assign(window, { VociPopover, Waveform, PriorityBadge, TimeBadge, Kbd, Spinner, ParseRow });
