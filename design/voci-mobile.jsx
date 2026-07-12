// voci-mobile.jsx — iOS companion: same product, mobile form
// Status bar, big task list, hold-to-talk button at bottom, full-screen voice modal

const { useState: useStateMo, useEffect: useEffectMo, useRef: useRefMo } = React;

function StatusBar({ time = '9:41', dark = true }) {
  const fg = dark ? '#fff' : '#000';
  return (
    <div style={{
      height: 54, padding: '0 24px',
      display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between',
      paddingBottom: 10, color: fg,
      fontFamily: VOCI_FONT, fontSize: 16, fontWeight: 500,
      letterSpacing: '-0.005em',
      position: 'relative', zIndex: 5,
    }}>
      <span>{time}</span>
      {/* Dynamic Island */}
      <div style={{
        position: 'absolute', left: '50%', top: 10, transform: 'translateX(-50%)',
        width: 120, height: 36, borderRadius: 24, background: '#000',
      }} />
      <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6 }}>
        {/* Signal */}
        <svg width="17" height="11" viewBox="0 0 17 11" fill={fg}>
          <rect x="0" y="7" width="3" height="4" rx="0.5"/>
          <rect x="4.5" y="5" width="3" height="6" rx="0.5"/>
          <rect x="9" y="2.5" width="3" height="8.5" rx="0.5"/>
          <rect x="13.5" y="0" width="3" height="11" rx="0.5"/>
        </svg>
        {/* Battery */}
        <svg width="25" height="12" viewBox="0 0 25 12">
          <rect x="0.5" y="0.5" width="22" height="11" rx="3" stroke={fg} strokeOpacity="0.45" fill="none"/>
          <rect x="2" y="2" width="19" height="8" rx="1.5" fill={fg}/>
          <rect x="23.5" y="4" width="1.5" height="4" rx="0.5" fill={fg} fillOpacity="0.45"/>
        </svg>
      </span>
    </div>
  );
}

function MobileTaskCard({ task, theme, big = false, onToggle }) {
  const { c, a, d, font } = theme;
  const priorityColor = task.priority === 'high' ? c.high : task.priority === 'med' ? c.med : c.low;
  return (
    <div style={{
      padding: big ? '16px 16px' : '13px 14px',
      borderRadius: big ? 18 : 14,
      background: big ? a.surface : c.card,
      border: `0.5px solid ${big ? a.solid + '40' : c.border}`,
      display: 'flex', alignItems: 'flex-start', gap: 12,
    }}>
      <div onClick={onToggle} style={{
        flex: '0 0 auto', marginTop: big ? 2 : 1,
        width: big ? 22 : 20, height: big ? 22 : 20, borderRadius: '50%',
        border: `1.5px solid ${task.done ? a.solid : 'rgba(255,255,255,0.32)'}`,
        background: task.done ? a.solid : 'transparent',
        display: 'flex', alignItems: 'center', justifyContent: 'center',
      }}>
        {task.done && <VocIcon name="check" size={13} color="#fff" strokeWidth={2.6} />}
      </div>
      <div style={{ flex: 1, minWidth: 0 }}>
        {big && (
          <div style={{
            fontSize: 11, fontWeight: 500, letterSpacing: '0.07em', textTransform: 'uppercase',
            color: a.solid, marginBottom: 4,
          }}>Up next</div>
        )}
        <div style={{
          fontSize: big ? 17 : 15, fontWeight: big ? 600 : 500,
          color: task.done ? c.textMut : c.textPri,
          letterSpacing: '-0.01em', lineHeight: 1.3,
          textDecoration: task.done ? 'line-through' : 'none',
        }}>{task.title}</div>
        <div style={{ marginTop: 6, display: 'flex', alignItems: 'center', gap: 8, fontSize: 12.5, color: c.textSec, flexWrap: 'wrap' }}>
          <span style={{
            display: 'inline-flex', alignItems: 'center', gap: 5,
            padding: '3px 8px', borderRadius: 14,
            background: big ? 'rgba(255,255,255,0.10)' : a.surface,
            color: big ? '#fff' : a.solid,
            fontSize: 11.5, fontWeight: 500, fontVariantNumeric: 'tabular-nums',
          }}>
            {task.timeBadge || task.time}
          </span>
          <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5 }}>
            <span style={{ width: 5, height: 5, borderRadius: '50%', background: priorityColor }} />
            <span>{task.priority === 'high' ? 'High' : task.priority === 'med' ? 'Medium' : 'Low'}</span>
          </span>
          {task.dur && <span>· {task.dur}</span>}
        </div>
      </div>
    </div>
  );
}

function MobileTabBar({ active, onChange, theme }) {
  const { c, a } = theme;
  const tabs = [
    { id: 'today', label: 'Today', icon: 'today' },
    { id: 'upcoming', label: 'Upcoming', icon: 'upcoming' },
    { id: 'projects', label: 'Projects', icon: 'project' },
    { id: 'settings', label: 'Settings', icon: 'settings' },
  ];
  return (
    <div style={{
      position: 'absolute', left: 0, right: 0, bottom: 0,
      paddingBottom: 24, paddingTop: 8, paddingLeft: 12, paddingRight: 12,
      display: 'flex', justifyContent: 'space-around',
      background: 'rgba(28,28,30,0.85)',
      backdropFilter: 'blur(24px) saturate(180%)',
      WebkitBackdropFilter: 'blur(24px) saturate(180%)',
      borderTop: `0.5px solid ${c.border}`,
    }}>
      {tabs.map(t => (
        <div key={t.id} onClick={() => onChange(t.id)} style={{
          flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4,
          padding: '6px 4px',
          color: active === t.id ? a.solid : c.textSec,
        }}>
          <VocIcon name={t.icon} size={22} color={active === t.id ? a.solid : c.textSec} strokeWidth={active === t.id ? 2 : 1.6} />
          <span style={{ fontSize: 10.5, fontWeight: 500, letterSpacing: '-0.005em' }}>{t.label}</span>
        </div>
      ))}
    </div>
  );
}

// Voice modal (full screen) — bottom-sheet style
function MobileVoiceSheet({ theme, onClose, animatedWave = true, transcriptIndex = 0 }) {
  const { c, a, g, font } = theme;
  const [state, setState] = useStateMo('recording');
  const [streamed, setStreamed] = useStateMo('');
  const example = SAMPLE_TRANSCRIPT_PARSED[transcriptIndex % SAMPLE_TRANSCRIPT_PARSED.length];

  useEffectMo(() => {
    if (state !== 'recording') return;
    setStreamed('');
    let i = 0;
    const id = setInterval(() => {
      i++; setStreamed(example.sentence.slice(0, i));
      if (i >= example.sentence.length) clearInterval(id);
    }, 32);
    return () => clearInterval(id);
  }, [state]);

  useEffectMo(() => {
    if (state !== 'recording') return;
    const t1 = setTimeout(() => setState('parsing'), 3000);
    const t2 = setTimeout(() => setState('parsed'), 3600);
    return () => { clearTimeout(t1); clearTimeout(t2); };
  }, [state]);

  const save = () => {
    setState('saving');
    setTimeout(() => setState('done'), 700);
    setTimeout(() => onClose && onClose(), 1500);
  };

  return (
    <div style={{
      position: 'absolute', inset: 0,
      background: 'rgba(0,0,0,0.55)',
      backdropFilter: 'blur(12px)',
      WebkitBackdropFilter: 'blur(12px)',
      display: 'flex', flexDirection: 'column', justifyContent: 'flex-end',
      zIndex: 50,
      animation: 'voci-fade-in .18s ease-out',
    }} onClick={onClose}>
      <div onClick={(e) => e.stopPropagation()} style={{
        background: g.bg,
        backdropFilter: `blur(${g.blur}px) saturate(180%)`,
        WebkitBackdropFilter: `blur(${g.blur}px) saturate(180%)`,
        borderTopLeftRadius: 28, borderTopRightRadius: 28,
        borderTop: `0.5px solid ${c.borderHi}`,
        borderLeft: `0.5px solid ${c.borderHi}`,
        borderRight: `0.5px solid ${c.borderHi}`,
        padding: '14px 20px 36px',
        boxShadow: '0 -24px 60px rgba(0,0,0,0.4)',
        animation: 'voci-slide-up .28s cubic-bezier(.2,.7,.3,1)',
      }}>
        {/* grabber */}
        <div style={{
          width: 38, height: 5, borderRadius: 3,
          background: 'rgba(255,255,255,0.2)',
          margin: '0 auto 14px',
        }} />

        {/* status row */}
        <div style={{ textAlign: 'center', marginBottom: 18 }}>
          <div style={{
            display: 'inline-flex', alignItems: 'center', gap: 8,
            padding: '6px 14px', borderRadius: 20,
            background: state === 'recording' ? 'rgba(255,107,107,0.12)' : a.surface,
            color: state === 'recording' ? c.high : a.solid,
            fontSize: 12, fontWeight: 500, letterSpacing: '-0.005em',
          }}>
            {state === 'recording' && (
              <span style={{
                width: 7, height: 7, borderRadius: '50%', background: c.high,
                animation: 'voci-pulse-m 1.2s ease-out infinite',
              }} />
            )}
            <span>
              {state === 'recording' && 'Listening…'}
              {state === 'parsing'   && 'Parsing with AI…'}
              {state === 'parsed'    && 'Confirm or edit'}
              {state === 'saving'    && 'Saving…'}
              {state === 'done'      && 'Saved'}
            </span>
          </div>
        </div>

        {/* waveform big */}
        {(state === 'recording' || state === 'parsing') && (
          <Waveform active={animatedWave && state === 'recording'} color={a.solid} glow={a.glow} bars={28} height={64} />
        )}
        {state === 'done' && (
          <div style={{ display: 'flex', justifyContent: 'center', padding: '8px 0 18px' }}>
            <div style={{
              width: 56, height: 56, borderRadius: '50%',
              background: c.done, display: 'flex', alignItems: 'center', justifyContent: 'center',
              boxShadow: `0 0 40px rgba(91,209,122,0.5)`,
            }}>
              <VocIcon name="check" size={28} color="#0e2a16" strokeWidth={2.6} />
            </div>
          </div>
        )}

        {/* transcript */}
        <div style={{
          minHeight: 56,
          margin: '14px 4px',
          fontSize: 18, lineHeight: 1.4,
          color: state === 'recording' ? c.textPri : c.textSec,
          letterSpacing: '-0.01em',
          fontWeight: 400,
          textAlign: 'center',
        }}>
          {state === 'recording' ? (
            <>
              {streamed}
              <span style={{
                display: 'inline-block', width: 2, height: 18, marginLeft: 2,
                verticalAlign: '-3px', background: a.solid,
                animation: 'voci-caret 0.9s steps(2, start) infinite',
              }} />
            </>
          ) : example.sentence}
        </div>

        {/* parsed card */}
        {(state === 'parsed' || state === 'saving' || state === 'done') && (
          <div style={{
            margin: '8px 0 16px',
            padding: 16, borderRadius: 16,
            background: c.card,
            border: `0.5px solid ${c.border}`,
            display: 'flex', flexDirection: 'column', gap: 10,
            animation: 'voci-rise .35s cubic-bezier(.2,.7,.3,1) both',
          }}>
            <div style={{ fontSize: 16, fontWeight: 500, color: c.textPri, letterSpacing: '-0.01em', lineHeight: 1.35 }}>
              {example.parsed.title}
            </div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginTop: 2 }}>
              <TimeBadge when={example.parsed.when} theme={theme} />
              <PriorityBadge priority={example.parsed.priority} theme={theme} />
              <span style={{
                display: 'inline-flex', alignItems: 'center', gap: 6, height: 22, padding: '0 9px',
                borderRadius: 20, background: 'rgba(255,255,255,0.06)',
                fontSize: 11.5, color: c.textSec,
              }}>
                <span style={{ width: 6, height: 6, borderRadius: '50%', background: a.solid }} />
                {example.parsed.project}
              </span>
            </div>
          </div>
        )}

        {/* actions */}
        {(state === 'parsed' || state === 'saving') && (
          <div style={{ display: 'flex', gap: 10 }}>
            <button onClick={onClose} style={{
              flex: '0 0 auto', height: 52, padding: '0 22px', borderRadius: 14,
              background: 'rgba(255,255,255,0.06)',
              border: `0.5px solid ${c.border}`,
              color: c.textPri, fontSize: 15, fontWeight: 500, fontFamily: VOCI_FONT,
            }}>Cancel</button>
            <button onClick={save} style={{
              flex: 1, height: 52, borderRadius: 14,
              background: state === 'saving' ? a.surface : a.solid,
              color: state === 'saving' ? a.solid : '#fff',
              border: `0.5px solid rgba(255,255,255,0.18)`,
              fontSize: 16, fontWeight: 500, fontFamily: VOCI_FONT,
              boxShadow: state === 'saving' ? 'none' : `0 8px 24px ${a.glow}, inset 0 0.5px 0 rgba(255,255,255,0.25)`,
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
            }}>
              {state === 'saving' ? <Spinner color={a.solid} size={18} /> : 'Save task'}
            </button>
          </div>
        )}
      </div>

      <style>{`
        @keyframes voci-fade-in { from { opacity: 0 } to { opacity: 1 } }
        @keyframes voci-slide-up { from { transform: translateY(100%) } to { transform: translateY(0) } }
        @keyframes voci-pulse-m {
          0%   { box-shadow: 0 0 0 0 ${c.high}80; }
          70%  { box-shadow: 0 0 0 6px ${c.high}00; }
          100% { box-shadow: 0 0 0 0 ${c.high}00; }
        }
      `}</style>
    </div>
  );
}

// Mic FAB
function MicButton({ theme, onPress, big = true }) {
  const { a } = theme;
  const [pressed, setPressed] = useStateMo(false);
  return (
    <div style={{
      position: 'absolute', left: '50%', bottom: 96, transform: 'translateX(-50%)',
      zIndex: 30,
    }}>
      {/* halo */}
      <div style={{
        position: 'absolute', inset: -10, borderRadius: '50%',
        background: `radial-gradient(circle, ${a.glow}, transparent 70%)`,
        opacity: pressed ? 1 : 0.55,
        transition: 'opacity .2s',
        pointerEvents: 'none',
      }} />
      <button
        onMouseDown={() => setPressed(true)}
        onMouseUp={() => setPressed(false)}
        onMouseLeave={() => setPressed(false)}
        onClick={onPress}
        style={{
          position: 'relative',
          width: 72, height: 72, borderRadius: '50%',
          background: a.solid,
          border: `0.5px solid rgba(255,255,255,0.25)`,
          color: '#fff',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          boxShadow: `0 16px 40px ${a.glow}, inset 0 1px 0 rgba(255,255,255,0.3)`,
          transform: pressed ? 'scale(0.94)' : 'scale(1)',
          transition: 'transform .12s ease-out',
        }}
      >
        <VocIcon name="mic" size={30} color="#fff" strokeWidth={1.8} />
      </button>
    </div>
  );
}

// ── Main mobile app ─────────────────────────────────────────────────────────
function VociMobileApp({ theme, width = 390, height = 844, initialEmpty = false, animatedWave = true }) {
  const { c, a, font } = theme;
  const [tab, setTab] = useStateMo('today');
  const [tasks, setTasks] = useStateMo(SAMPLE_TASKS);
  const [sheet, setSheet] = useStateMo(false);
  const [transcriptIdx, setTranscriptIdx] = useStateMo(0);

  const toggle = (id) => setTasks(ts => ts.map(t => t.id === id ? { ...t, done: !t.done } : t));
  const nowTasks = tasks.filter(t => !t.done && t.when === 'now');
  const laterTasks = tasks.filter(t => !t.done && t.when === 'later');
  const doneTasks = tasks.filter(t => t.done);

  const openSheet = () => {
    setTranscriptIdx(i => (i + 1) % SAMPLE_TRANSCRIPT_PARSED.length);
    setSheet(true);
  };

  return (
    <div style={{
      width, height,
      position: 'relative',
      borderRadius: 48,
      overflow: 'hidden',
      background: c.bg,
      fontFamily: font,
      color: c.textPri,
      boxShadow: '0 30px 80px rgba(0,0,0,0.55), 0 0 0 0.5px rgba(255,255,255,0.06)',
    }}>
      <StatusBar />

      {/* Content (scroll area) */}
      <div style={{ height: `calc(100% - 54px)`, overflow: 'auto', paddingBottom: 200 }}>
        {/* Header */}
        <div style={{ padding: '4px 22px 6px' }}>
          <div style={{
            fontSize: 13, fontWeight: 500, letterSpacing: '0.05em', textTransform: 'uppercase',
            color: a.solid, marginBottom: 2,
          }}>Wed, May 21</div>
          <div style={{
            fontSize: 34, fontWeight: 500, letterSpacing: '-0.025em', color: c.textPri,
          }}>Good morning, Alex.</div>
          <div style={{
            marginTop: 4, fontSize: 14.5, color: c.textSec, letterSpacing: '-0.005em',
          }}>{nowTasks.length + laterTasks.length} tasks today · {doneTasks.length} already done</div>
        </div>

        {initialEmpty ? (
          <div style={{ padding: 36, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14, marginTop: 60 }}>
            <div style={{
              width: 80, height: 80, borderRadius: 22,
              background: a.surface,
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              border: `0.5px solid ${a.solid}33`,
            }}>
              <VocIcon name="mic" size={36} color={a.solid} strokeWidth={1.6} />
            </div>
            <div style={{ fontSize: 22, fontWeight: 500 }}>All clear.</div>
            <div style={{ fontSize: 14, color: c.textSec, textAlign: 'center', maxWidth: 240 }}>
              Tap the mic and speak your next task.
            </div>
          </div>
        ) : (
          <>
            {/* Now (hero card) */}
            {nowTasks.length > 0 && (
              <div style={{ padding: '14px 18px 6px' }}>
                <MobileTaskCard task={nowTasks[0]} theme={theme} big onToggle={() => toggle(nowTasks[0].id)} />
              </div>
            )}

            {/* Later */}
            <div style={{ padding: '20px 22px 4px', display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{
                fontSize: 11, fontWeight: 500, letterSpacing: '0.08em', textTransform: 'uppercase',
                color: c.textMut,
              }}>Later today</span>
              <span style={{ flex: 1, height: 0.5, background: c.border }} />
              <span style={{ fontSize: 11, color: c.textMut }}>{nowTasks.slice(1).length + laterTasks.length}</span>
            </div>
            <div style={{ padding: '4px 18px 6px', display: 'flex', flexDirection: 'column', gap: 8 }}>
              {[...nowTasks.slice(1), ...laterTasks].map(t => (
                <MobileTaskCard key={t.id} task={t} theme={theme} onToggle={() => toggle(t.id)} />
              ))}
            </div>

            {/* Done */}
            {doneTasks.length > 0 && (
              <>
                <div style={{ padding: '18px 22px 4px', display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{
                    fontSize: 11, fontWeight: 500, letterSpacing: '0.08em', textTransform: 'uppercase',
                    color: c.textMut,
                  }}>Completed</span>
                  <span style={{ flex: 1, height: 0.5, background: c.border }} />
                  <span style={{ fontSize: 11, color: c.textMut }}>{doneTasks.length}</span>
                </div>
                <div style={{ padding: '4px 18px 6px', display: 'flex', flexDirection: 'column', gap: 8 }}>
                  {doneTasks.map(t => (
                    <MobileTaskCard key={t.id} task={t} theme={theme} onToggle={() => toggle(t.id)} />
                  ))}
                </div>
              </>
            )}

            {/* Hotkey hint card */}
            <div style={{
              margin: '20px 18px 0',
              padding: '14px 16px', borderRadius: 14,
              border: `0.5px dashed ${a.solid}55`,
              fontSize: 13, color: c.textSec,
              display: 'flex', alignItems: 'center', gap: 10,
            }}>
              <VocIcon name="mic" size={16} color={a.solid} strokeWidth={1.8} />
              <span>Long-press the mic or say <span style={{ color: a.solid, fontWeight: 500 }}>"Hey Voci"</span> from anywhere.</span>
            </div>
          </>
        )}
      </div>

      {/* mic FAB */}
      <MicButton theme={theme} onPress={openSheet} />

      {/* tab bar */}
      <MobileTabBar active={tab} onChange={setTab} theme={theme} />

      {/* voice sheet */}
      {sheet && (
        <MobileVoiceSheet theme={theme} onClose={() => setSheet(false)}
          animatedWave={animatedWave} transcriptIndex={transcriptIdx} />
      )}

      {/* Home indicator */}
      <div style={{
        position: 'absolute', left: '50%', bottom: 8, transform: 'translateX(-50%)',
        width: 134, height: 5, borderRadius: 3, background: '#fff', opacity: 0.85,
        zIndex: 40,
      }} />
    </div>
  );
}

Object.assign(window, { VociMobileApp, StatusBar, MobileTaskCard, MobileVoiceSheet, MicButton, MobileTabBar });
