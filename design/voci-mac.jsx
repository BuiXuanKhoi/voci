// voci-mac.jsx — Mac desktop app: Today view with interactive hotkey + popover overlay

const { useState: useStateM, useEffect: useEffectM, useRef: useRefM, useMemo: useMemoM, useCallback: useCallbackM } = React;

// ─── Task row ────────────────────────────────────────────────────────────────
function TaskRow({ task, theme, isActive, onToggle, onSelect, hoverable = true }) {
  const { c, a, d, font } = theme;
  const [hover, setHover] = useStateM(false);
  const priorityColor = task.priority === 'high' ? c.high : task.priority === 'med' ? c.med : c.low;

  return (
    <div
      onMouseEnter={() => hoverable && setHover(true)}
      onMouseLeave={() => setHover(false)}
      onClick={onSelect}
      style={{
        position: 'relative',
        display: 'flex', alignItems: 'flex-start', gap: 10,
        padding: `${d.rowPadY}px 12px`,
        borderRadius: 9,
        background: isActive
          ? a.surface
          : hover ? c.cardHover : c.card,
        border: `0.5px solid ${isActive ? a.solid + '40' : c.border}`,
        cursor: 'default',
        transition: 'background .12s ease, border-color .12s ease',
        boxShadow: isActive ? `inset 0 0 0 0.5px ${a.solid}30` : 'none',
      }}
    >
      {/* Checkbox */}
      <div
        onClick={(e) => { e.stopPropagation(); onToggle && onToggle(); }}
        style={{
          flex: '0 0 auto',
          width: 17, height: 17, borderRadius: '50%',
          marginTop: 1,
          border: `1.5px solid ${task.done ? a.solid : 'rgba(255,255,255,0.28)'}`,
          background: task.done ? a.solid : 'transparent',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          cursor: 'pointer',
          transition: 'all .18s ease',
        }}
      >
        {task.done && <VocIcon name="check" size={11} color="#fff" strokeWidth={2.6} />}
      </div>

      {/* Body */}
      <div style={{ flex: 1, minWidth: 0, display: 'flex', flexDirection: 'column', gap: 4 }}>
        <div style={{
          fontSize: 13, fontWeight: task.done ? 400 : 500, letterSpacing: '-0.005em',
          color: task.done ? c.textMut : c.textPri,
          textDecoration: task.done ? 'line-through' : 'none',
          textDecorationColor: 'rgba(255,255,255,0.25)',
          whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
          display: 'flex', alignItems: 'center', gap: 7,
        }}>
          {task.frog && !task.done && (
            <span title="Frog of the day" style={{
              width: 5, height: 5, borderRadius: '50%', background: c.high,
              flexShrink: 0,
              boxShadow: `0 0 6px ${c.high}80`,
            }} />
          )}
          <span style={{
            overflow: 'hidden', textOverflow: 'ellipsis',
          }}>{task.title}</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 11, color: c.textSec }}>
          <span style={{
            width: 5, height: 5, borderRadius: '50%', background: priorityColor, flexShrink: 0,
          }} />
          <span>
            {task.done ? 'Done' : task.priority === 'high' ? 'High' : task.priority === 'med' ? 'Medium' : 'Low'}
          </span>
          {task.dur && !task.done && <><span style={{ opacity: 0.4 }}>·</span><span>{task.dur}</span></>}
          {task.frog && !task.done && (
            <>
              <span style={{ opacity: 0.4 }}>·</span>
              <span style={{ color: c.high, fontWeight: 500, letterSpacing: '0.02em' }}>Frog</span>
            </>
          )}
        </div>
      </div>

      {/* Right: time badge */}
      {task.timeBadge && !task.done && (
        <div style={{
          flex: '0 0 auto',
          padding: '4px 10px', borderRadius: 20,
          background: isActive ? a.solid : a.surface,
          color: isActive ? '#fff' : a.solid,
          fontSize: 11.5, fontWeight: 500, fontVariantNumeric: 'tabular-nums',
          letterSpacing: '-0.005em',
          alignSelf: 'center',
        }}>{task.timeBadge}</div>
      )}
      {task.done && (
        <div style={{
          flex: '0 0 auto', alignSelf: 'center',
          fontSize: 11, color: c.textMut, fontVariantNumeric: 'tabular-nums',
        }}>{task.time}</div>
      )}
    </div>
  );
}

// ─── Sidebar item ────────────────────────────────────────────────────────────
function SidebarItem({ icon, label, count, active, color, onClick, theme }) {
  const { c, a } = theme;
  const [hover, setHover] = useStateM(false);
  return (
    <div
      onClick={onClick}
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      style={{
        display: 'flex', alignItems: 'center', gap: 9,
        padding: '6px 10px',
        borderRadius: 7,
        background: active ? a.surface : hover ? 'rgba(255,255,255,0.04)' : 'transparent',
        color: active ? a.solid : c.textPri,
        cursor: 'default',
        transition: 'background .1s',
      }}
    >
      {icon && (
        <span style={{ display: 'inline-flex', color: active ? a.solid : c.textSec }}>
          <VocIcon name={icon} size={14} />
        </span>
      )}
      {color && (
        <span style={{ width: 8, height: 8, borderRadius: '50%', background: color, marginLeft: 1 }} />
      )}
      <span style={{
        flex: 1,
        fontSize: 13, fontWeight: active ? 500 : 400, letterSpacing: '-0.005em',
        whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
      }}>{label}</span>
      {count != null && (
        <span style={{
          fontSize: 11, color: active ? a.solid : c.textMut, fontVariantNumeric: 'tabular-nums',
          padding: '1px 6px', borderRadius: 6,
          background: active ? 'transparent' : 'transparent',
        }}>{count}</span>
      )}
    </div>
  );
}

function SectionLabel({ children, theme, style = {} }) {
  const { c } = theme;
  return (
    <div style={{
      fontSize: 10.5, fontWeight: 500, letterSpacing: '0.07em',
      textTransform: 'uppercase', color: c.textMut,
      padding: '14px 12px 6px',
      ...style,
    }}>{children}</div>
  );
}

// ─── Window chrome ───────────────────────────────────────────────────────────
function TrafficLights({ active = true }) {
  const dot = (color) => (
    <div style={{
      width: 12, height: 12, borderRadius: '50%',
      background: active ? color : 'rgba(255,255,255,0.18)',
      border: '0.5px solid rgba(0,0,0,0.25)',
      boxShadow: 'inset 0 0.5px 0 rgba(255,255,255,0.18)',
    }} />
  );
  return (
    <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
      {dot('#FF5F57')}{dot('#FEBC2E')}{dot('#28C840')}
    </div>
  );
}

// ─── Empty state ─────────────────────────────────────────────────────────────
function EmptyToday({ theme }) {
  const { c, a, font } = theme;
  return (
    <div style={{
      flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
      gap: 14, padding: 40, color: c.textPri,
    }}>
      <div style={{
        width: 64, height: 64, borderRadius: 18,
        background: a.surface,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        border: `0.5px solid ${a.solid}33`,
        boxShadow: `0 0 30px ${a.glow}30`,
      }}>
        <VocIcon name="mic" size={28} color={a.solid} strokeWidth={1.6} />
      </div>
      <div style={{
        fontSize: 22, fontWeight: 500, letterSpacing: '-0.015em', color: c.textPri,
      }}>All clear.</div>
      <div style={{ fontSize: 13.5, color: c.textSec, textAlign: 'center', maxWidth: 300, lineHeight: 1.5 }}>
        Hold <KeyBadge theme={theme}>⌃</KeyBadge> <KeyBadge theme={theme}>⌥</KeyBadge> <KeyBadge theme={theme}>Space</KeyBadge> when you need to remember something.
      </div>
    </div>
  );
}

function KeyBadge({ children, theme, accent = false }) {
  const { c, a } = theme;
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', justifyContent: 'center',
      minWidth: 18, height: 18, padding: '0 5px', borderRadius: 5,
      background: accent ? a.surface : 'rgba(255,255,255,0.08)',
      border: `0.5px solid ${accent ? a.solid + '55' : 'rgba(255,255,255,0.10)'}`,
      color: accent ? a.solid : c.textSec,
      fontFamily: VOCI_MONO, fontSize: 10.5, fontWeight: 500,
      verticalAlign: 'middle',
      lineHeight: 1,
    }}>{children}</span>
  );
}

// ─── Main Mac App ────────────────────────────────────────────────────────────
function VociMacApp({
  theme,
  width = 920,
  height = 580,
  initialEmpty = false,
  initialView = 'today',
  animatedWave = true,
  enableHotkey = true,
  ambient = 'none',        // 'none' | 'rain' | 'snow' | 'embers' | 'custom'
  ambientImage = '',
  voiceFeedback = false,
  motionIntensity = 0.7,   // 0..1 — particle density/opacity
}) {
  const { c, a, d, font } = theme;
  const [view, setView] = useStateM(initialView);
  const [tasks, setTasks] = useStateM(SAMPLE_TASKS);
  const [activeTaskId, setActiveTaskId] = useStateM(null);
  const [popoverState, setPopoverState] = useStateM(null); // null | 'recording' | 'parsing' | 'parsed' | 'saving' | 'done' | 'error'
  const [transcriptIdx, setTranscriptIdx] = useStateM(0);
  const [holdHint, setHoldHint] = useStateM(false);
  const rootRef = useRefM(null);

  // Ambient sound + focus session
  const sound = useAmbientSound();
  const soundMode = (ambient === 'none' || ambient === 'custom') ? 'rain' : ambient;
  const [focusOn, setFocusOn] = useStateM(false);
  const [focusPaused, setFocusPaused] = useStateM(false);
  const [focusLeft, setFocusLeft] = useStateM(25 * 60);
  const [focusIdx, setFocusIdx] = useStateM(0);
  const glassOn = ambient !== 'none';

  const empty = initialEmpty;
  const nowTasks = tasks.filter(t => !t.done && t.when === 'now');
  const laterTasks = tasks.filter(t => !t.done && t.when === 'later');
  const doneTasks = tasks.filter(t => t.done);

  const toggleTask = (id) => setTasks(ts => ts.map(t => t.id === id ? { ...t, done: !t.done, when: t.done ? t.when : 'later' } : t));

  const frogTask = tasks.find(t => t.frog && !t.done);
  const openTasks = [...nowTasks, ...laterTasks];

  // If everything gets completed mid-session, end gracefully
  useEffectM(() => {
    if (focusOn && openTasks.length === 0) {
      setFocusOn(false);
      if (voiceFeedback) vociSpeak('All clear. Nothing left today.');
    }
  }, [focusOn, openTasks.length, voiceFeedback]);

  // Focus countdown
  useEffectM(() => {
    if (!focusOn || focusPaused) return;
    const iv = setInterval(() => setFocusLeft(s => {
      if (s <= 1) {
        clearInterval(iv);
        setFocusOn(false);
        if (voiceFeedback) vociSpeak('Focus session complete. Nice work.');
        return 25 * 60;
      }
      return s - 1;
    }), 1000);
    return () => clearInterval(iv);
  }, [focusOn, focusPaused, voiceFeedback]);

  const startFocus = () => {
    setFocusLeft(25 * 60);
    setFocusPaused(false);
    const fi = openTasks.findIndex(t => t.frog);
    setFocusIdx(fi >= 0 ? fi : 0);
    setFocusOn(true);
    if (voiceFeedback) vociSpeak('Focus session started. ' + (frogTask ? frogTask.title : 'Twenty five minutes.'));
  };
  const endFocus = () => { setFocusOn(false); setFocusLeft(25 * 60); vociStopSpeak(); };

  const completeFocusTask = (id) => {
    const remaining = openTasks.length - 1;
    toggleTask(id);
    setFocusIdx(i => Math.max(0, Math.min(i, remaining - 1)));
    if (voiceFeedback) {
      vociSpeak(remaining > 0 ? `Done. ${remaining} left today.` : 'Done. All clear.');
    }
  };

  const readDay = () => {
    const open = [...nowTasks, ...laterTasks];
    if (open.length === 0) { vociSpeak('All clear. Nothing scheduled.'); return; }
    const list = open.slice(0, 3).map(t => t.title).join('. ');
    vociSpeak(`You have ${open.length} open task${open.length === 1 ? '' : 's'}. Up next: ${list}.`);
  };

  const fmtClock = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;

  // Hotkey simulation: Ctrl+Alt+Space inside the window (or globally if focused)
  useEffectM(() => {
    if (!enableHotkey) return;
    const onKey = (e) => {
      // ctrl+alt+space → open popover. Esc → close.
      const isHotkey = (e.ctrlKey || e.metaKey) && e.altKey && e.code === 'Space';
      if (isHotkey) {
        e.preventDefault();
        startVoiceFlow();
      } else if (e.key === 'Escape' && popoverState) {
        setPopoverState(null);
      } else if (e.key === 'Enter' && popoverState === 'parsed') {
        e.preventDefault();
        saveFromPopover();
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [enableHotkey, popoverState, transcriptIdx]);

  const startVoiceFlow = useCallbackM(() => {
    setTranscriptIdx(i => (i + 1) % SAMPLE_TRANSCRIPT_PARSED.length);
    setPopoverState('recording');
  }, []);

  // auto progression once recording starts
  useEffectM(() => {
    if (popoverState !== 'recording') return;
    const t1 = setTimeout(() => setPopoverState('parsing'), 2800);
    const t2 = setTimeout(() => setPopoverState('parsed'), 3400);
    return () => { clearTimeout(t1); clearTimeout(t2); };
  }, [popoverState, transcriptIdx]);

  const saveFromPopover = () => {
    if (voiceFeedback) {
      const ex = SAMPLE_TRANSCRIPT_PARSED[transcriptIdx % SAMPLE_TRANSCRIPT_PARSED.length].parsed;
      vociSpeak(`Added. ${ex.title}. ${ex.when.replace('·', ',')}.`);
    }
    setPopoverState('saving');
    setTimeout(() => setPopoverState('done'), 700);
    setTimeout(() => {
      // commit a new task
      const ex = SAMPLE_TRANSCRIPT_PARSED[transcriptIdx % SAMPLE_TRANSCRIPT_PARSED.length].parsed;
      const newTask = {
        id: 'gen-' + Date.now(),
        title: ex.title,
        priority: ex.priority,
        time: ex.when.replace(/^.*·\s*/, ''),
        timeBadge: ex.when.replace(/^.*·\s*/, ''),
        dur: ex.duration,
        project: ex.project,
        done: false,
        when: 'now',
      };
      setTasks(ts => [newTask, ...ts]);
      setPopoverState(null);
    }, 1500);
  };

  return (
    <div ref={rootRef} tabIndex={0} style={{
      width, height,
      position: 'relative',
      borderRadius: 12,
      overflow: 'hidden',
      background: glassOn ? '#0b0d14' : c.bg,
      fontFamily: font,
      color: c.textPri,
      boxShadow: '0 30px 80px rgba(0,0,0,0.55), 0 0 0 0.5px rgba(255,255,255,0.06)',
      outline: 'none',
    }}>
      {glassOn && <AmbientBackground mode={ambient} imageUrl={ambientImage} animated={animatedWave} intensity={motionIntensity} />}
      {/* Title bar */}
      <div style={{
        height: 38, paddingLeft: 14, paddingRight: 14,
        display: 'flex', alignItems: 'center', gap: 12,
        background: glassOn ? 'rgba(22,24,32,0.55)' : c.surface,
        backdropFilter: glassOn ? 'blur(22px)' : 'none',
        WebkitBackdropFilter: glassOn ? 'blur(22px)' : 'none',
        borderBottom: `0.5px solid ${c.border}`,
        position: 'relative', zIndex: 1,
      }}>
        <TrafficLights />
        <div style={{ flex: 1 }} />
        <div style={{
          position: 'absolute', left: '50%', top: '50%', transform: 'translate(-50%,-50%)',
          fontSize: 13, fontWeight: 500, letterSpacing: '-0.01em', color: c.textPri,
        }}>Voci</div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
          <ToolButton icon={sound.playing ? 'volume' : 'volumeOff'} theme={theme}
            title="Ambient sound" activeTint={sound.playing}
            onClick={() => sound.toggle(soundMode)} />
          <ToolButton icon="waveform" theme={theme} title="Read my day aloud" onClick={readDay} />
          <ToolButton icon="search" theme={theme} />
          <ToolButton icon="plus" theme={theme} accent onClick={startVoiceFlow} />
        </div>
      </div>

      {/* Body: sidebar + main */}
      <div style={{ display: 'flex', height: `calc(100% - 38px)`, position: 'relative', zIndex: 1 }}>
        {/* Sidebar */}
        <div style={{
          width: 160, flexShrink: 0,
          background: glassOn ? 'rgba(20,22,30,0.45)' : c.surface,
          backdropFilter: glassOn ? 'blur(24px)' : 'none',
          WebkitBackdropFilter: glassOn ? 'blur(24px)' : 'none',
          borderRight: `0.5px solid ${c.border}`,
          display: 'flex', flexDirection: 'column',
          paddingBottom: 12,
        }}>
          {/* Voice quick capture button */}
          <div style={{ padding: '12px 10px 4px' }}>
            <button
              onMouseDown={() => setHoldHint(true)}
              onMouseUp={() => setHoldHint(false)}
              onMouseLeave={() => setHoldHint(false)}
              onClick={startVoiceFlow}
              style={{
                width: '100%', height: 32,
                display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 7,
                borderRadius: 9,
                background: a.surface,
                border: `0.5px solid ${a.solid}44`,
                color: a.solid,
                fontSize: 12, fontWeight: 500, fontFamily: font, letterSpacing: '-0.005em',
                whiteSpace: 'nowrap',
                cursor: 'default',
                boxShadow: holdHint ? `inset 0 0 0 0.5px ${a.solid}` : 'none',
                transition: 'all .12s',
              }}
            >
              <VocIcon name="mic" size={13} color={a.solid} strokeWidth={1.8} />
              <span>Hold to speak</span>
            </button>
            <div style={{
              marginTop: 7,
              display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 4,
              fontSize: 10.5, color: c.textMut,
            }}>
              <KeyBadge theme={theme}>⌃</KeyBadge>
              <KeyBadge theme={theme}>⌥</KeyBadge>
              <KeyBadge theme={theme}>Space</KeyBadge>
            </div>
          </div>

          <SectionLabel theme={theme}>Focus</SectionLabel>
          <div style={{ padding: '0 8px', display: 'flex', flexDirection: 'column', gap: 1 }}>
            <SidebarItem theme={theme} icon="today" label="Today" count={nowTasks.length + laterTasks.length} active={view === 'today'} onClick={() => setView('today')} />
            <SidebarItem theme={theme} icon="upcoming" label="Upcoming" count={12} active={view === 'upcoming'} onClick={() => setView('upcoming')} />
            <SidebarItem theme={theme} icon="inbox" label="Inbox" count={3} active={view === 'inbox'} onClick={() => setView('inbox')} />
          </div>

          <div style={{ flex: 1 }} />

          <div style={{
            margin: '0 10px',
            padding: 10,
            borderRadius: 9,
            background: 'rgba(255,255,255,0.03)',
            border: `0.5px solid ${c.border}`,
            fontSize: 11, color: c.textSec, lineHeight: 1.45,
          }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 4, color: c.textPri, fontWeight: 500 }}>
              <span style={{ width: 5, height: 5, borderRadius: '50%', background: a.solid }} />
              <span>On-device</span>
            </div>
            Audio is parsed locally. Nothing leaves your Mac.
          </div>
        </div>

        {/* Main */}
        <div style={{
          flex: 1, minWidth: 0,
          display: 'flex', flexDirection: 'column',
          background: glassOn ? 'rgba(16,17,24,0.30)' : c.bg,
          backdropFilter: glassOn ? 'blur(18px)' : 'none',
          WebkitBackdropFilter: glassOn ? 'blur(18px)' : 'none',
        }}>
          {/* Greeting header */}
          <div style={{
            padding: '20px 28px 8px',
            display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between',
          }}>
            <div>
              <div style={{
                fontSize: 26, fontWeight: 500, letterSpacing: '-0.02em',
                color: c.textPri,
              }}>Today</div>
              <div style={{
                marginTop: 2,
                fontSize: 12.5, color: c.textSec, letterSpacing: '-0.005em',
                whiteSpace: 'nowrap',
              }}>Wed, May 21 · {nowTasks.length + laterTasks.length} open · {doneTasks.length} done</div>
            </div>
            {focusOn ? (
              <div style={{
                display: 'flex', alignItems: 'center', gap: 10,
                fontSize: 11.5, color: c.textSec,
                padding: '5px 6px 5px 12px', borderRadius: 16,
                background: a.surface,
                border: `0.5px solid ${a.solid}44`,
                boxShadow: `0 0 22px ${a.glow}25`,
              }}>
                <span style={{
                  width: 5, height: 5, borderRadius: '50%', background: a.solid,
                  boxShadow: `0 0 6px ${a.glow}`,
                  animation: focusPaused ? 'none' : 'voci-pulse 1.6s ease-in-out infinite',
                }} />
                <span style={{ color: c.textPri, fontWeight: 500, maxWidth: 180, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {frogTask ? frogTask.title : 'Focus'}
                </span>
                <span style={{
                  fontFamily: VOCI_MONO, fontSize: 13, fontWeight: 600, color: a.solid,
                  fontVariantNumeric: 'tabular-nums', letterSpacing: '0.02em',
                }}>{fmtClock(focusLeft)}</span>
                <span onClick={() => setFocusPaused(p => !p)} style={{
                  display: 'inline-flex', width: 22, height: 22, borderRadius: 11,
                  alignItems: 'center', justifyContent: 'center',
                  background: 'rgba(255,255,255,0.08)', cursor: 'pointer',
                }}>
                  <VocIcon name={focusPaused ? 'play' : 'pause'} size={10} color={c.textPri} strokeWidth={2} />
                </span>
                <span onClick={endFocus} style={{
                  display: 'inline-flex', width: 22, height: 22, borderRadius: 11,
                  alignItems: 'center', justifyContent: 'center',
                  background: 'rgba(255,255,255,0.08)', cursor: 'pointer',
                }}>
                  <VocIcon name="stop" size={9} color={c.textSec} />
                </span>
              </div>
            ) : (
              <div style={{
                display: 'flex', alignItems: 'center', gap: 8,
                fontSize: 11.5, color: c.textSec,
                padding: '5px 6px 5px 10px', borderRadius: 16,
                background: 'rgba(255,107,107,0.10)',
                border: `0.5px solid rgba(255,107,107,0.20)`,
              }}>
                <span style={{
                  width: 5, height: 5, borderRadius: '50%', background: c.high,
                  boxShadow: `0 0 6px ${c.high}80`,
                }} />
                <span><span style={{ color: c.textPri, fontWeight: 500 }}>Frog</span> · {frogTask ? frogTask.title : 'Ship the auth fix'}</span>
                <span onClick={startFocus} title="Start a 25-minute focus session" style={{
                  display: 'inline-flex', alignItems: 'center', gap: 5,
                  padding: '3px 9px', borderRadius: 12,
                  background: a.solid, color: '#fff',
                  fontSize: 11, fontWeight: 500, cursor: 'pointer',
                }}>
                  <VocIcon name="play" size={8} color="#fff" />
                  <span>Focus</span>
                </span>
              </div>
            )}
          </div>

          {/* Scrollable list */}
          <div style={{ flex: 1, overflow: 'auto', padding: '8px 22px 18px' }}>
            {empty ? <EmptyToday theme={theme} /> : (
              <>
                {/* NOW */}
                {nowTasks.length > 0 && (
                  <>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '10px 6px 8px' }}>
                      <span style={{
                        fontSize: 10.5, fontWeight: 500, letterSpacing: '0.07em',
                        textTransform: 'uppercase', color: a.solid,
                      }}>Now</span>
                      <span style={{ flex: 1, height: 0.5, background: c.border }} />
                      <span style={{ fontSize: 10.5, color: c.textMut }}>{nowTasks.length} task{nowTasks.length === 1 ? '' : 's'}</span>
                    </div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: d.rowGap }}>
                      {nowTasks.map((t, i) => (
                        <TaskRow key={t.id} task={t} theme={theme}
                          isActive={i === 0}
                          onToggle={() => toggleTask(t.id)}
                          onSelect={() => setActiveTaskId(t.id)} />
                      ))}
                    </div>
                  </>
                )}

                {/* LATER TODAY */}
                {laterTasks.length > 0 && (
                  <>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: `${d.sectionGap}px 6px 8px` }}>
                      <span style={{
                        fontSize: 10.5, fontWeight: 500, letterSpacing: '0.07em',
                        textTransform: 'uppercase', color: c.textMut,
                      }}>Later today</span>
                      <span style={{ flex: 1, height: 0.5, background: c.border }} />
                      <span style={{ fontSize: 10.5, color: c.textMut }}>{laterTasks.length}</span>
                    </div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: d.rowGap }}>
                      {laterTasks.map((t) => (
                        <TaskRow key={t.id} task={t} theme={theme}
                          onToggle={() => toggleTask(t.id)}
                          onSelect={() => setActiveTaskId(t.id)} />
                      ))}
                    </div>
                  </>
                )}

                {/* DONE */}
                {doneTasks.length > 0 && (
                  <>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: `${d.sectionGap}px 6px 8px` }}>
                      <span style={{
                        fontSize: 10.5, fontWeight: 500, letterSpacing: '0.07em',
                        textTransform: 'uppercase', color: c.textMut,
                      }}>Completed</span>
                      <span style={{ flex: 1, height: 0.5, background: c.border }} />
                      <span style={{ fontSize: 10.5, color: c.textMut }}>{doneTasks.length}</span>
                    </div>
                    <div style={{ display: 'flex', flexDirection: 'column', gap: d.rowGap }}>
                      {doneTasks.map((t) => (
                        <TaskRow key={t.id} task={t} theme={theme}
                          onToggle={() => toggleTask(t.id)} />
                      ))}
                    </div>
                  </>
                )}

                {/* Hotkey hint */}
                <div style={{
                  marginTop: 22, padding: '12px 14px',
                  borderRadius: 10,
                  border: `0.5px dashed ${a.solid}55`,
                  background: 'transparent',
                  display: 'flex', alignItems: 'center', gap: 10,
                  fontSize: 12, color: c.textSec,
                }}>
                  <VocIcon name="mic" size={13} color={a.solid} strokeWidth={1.8} />
                  <span>Hold</span>
                  <KeyBadge theme={theme} accent>⌃</KeyBadge>
                  <KeyBadge theme={theme} accent>⌥</KeyBadge>
                  <KeyBadge theme={theme} accent>Space</KeyBadge>
                  <span>and speak to add a task by voice.</span>
                </div>
              </>
            )}
          </div>
        </div>
      </div>

      {/* Popover overlay */}
      {popoverState && (
        <div style={{
          position: 'absolute', inset: 0,
          background: 'rgba(0,0,0,0.32)',
          backdropFilter: 'blur(2px)',
          WebkitBackdropFilter: 'blur(2px)',
          display: 'flex', alignItems: 'flex-start', justifyContent: 'center',
          paddingTop: 60,
          zIndex: 10,
          animation: 'voci-fade .12s ease-out',
        }} onClick={() => setPopoverState(null)}>
          <div onClick={(e) => e.stopPropagation()}>
            <VociPopover
              theme={theme}
              state={popoverState}
              setState={setPopoverState}
              transcriptIndex={transcriptIdx}
              setTranscriptIndex={setTranscriptIdx}
              animatedWave={animatedWave}
              onCancel={() => setPopoverState(null)}
              onSave={saveFromPopover}
              width={380}
            />
          </div>
        </div>
      )}

      {/* Fullscreen one-task Focus mode */}
      {focusOn && openTasks.length > 0 && (
        <VociFocusOverlay
          theme={theme}
          openTasks={openTasks}
          idx={focusIdx} setIdx={setFocusIdx}
          secondsLeft={focusLeft} totalSecs={25 * 60}
          paused={focusPaused}
          onTogglePause={() => setFocusPaused(p => !p)}
          onStop={endFocus}
          onCompleteTask={completeFocusTask}
        />
      )}

      <style>{`
        @keyframes voci-fade { from { opacity: 0 } to { opacity: 1 } }
        @keyframes voci-pulse { 0%,100% { opacity: 1 } 50% { opacity: 0.35 } }
      `}</style>
    </div>
  );
}

function ToolButton({ icon, accent = false, activeTint = false, onClick, title, theme }) {
  const { c, a } = theme;
  const [hover, setHover] = useStateM(false);
  const fg = accent ? '#fff' : activeTint ? a.solid : c.textSec;
  return (
    <button
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      onClick={onClick}
      title={title}
      style={{
        width: 28, height: 28, borderRadius: 7,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: accent ? (hover ? a.hover : a.solid) : activeTint ? a.surface : (hover ? 'rgba(255,255,255,0.08)' : 'transparent'),
        color: fg,
        border: 'none',
        cursor: 'default',
        transition: 'background .12s',
      }}
    >
      <VocIcon name={icon} size={14} color={fg} strokeWidth={1.8} />
    </button>
  );
}

Object.assign(window, { VociMacApp, TaskRow, SidebarItem, SectionLabel, KeyBadge, TrafficLights, EmptyToday, ToolButton });
