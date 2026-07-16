// volar-focus.jsx — fullscreen one-task Focus mode with task navigation

const { useState: useStateF, useEffect: useEffectF } = React;

function VolarFocusOverlay({
  theme,
  openTasks,
  idx, setIdx,
  secondsLeft, totalSecs,
  paused, onTogglePause,
  onStop,
  onCompleteTask,
}) {
  const { c, a, font } = theme;
  const task = openTasks[Math.min(idx, openTasks.length - 1)];
  const timerColor = secondsLeft <= 60 ? c.high : secondsLeft <= 300 ? c.med : a.solid;
  const frac = Math.max(0, Math.min(1, secondsLeft / totalSecs));
  const fmt = (s) => `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;

  // ← → to navigate between tasks
  useEffectF(() => {
    const onKey = (e) => {
      if (e.key === 'ArrowLeft') { e.preventDefault(); setIdx(i => Math.max(0, i - 1)); }
      else if (e.key === 'ArrowRight') { e.preventDefault(); setIdx(i => Math.min(openTasks.length - 1, i + 1)); }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, [openTasks.length, setIdx]);

  if (!task) return null;
  const priorityColor = task.priority === 'high' ? c.high : task.priority === 'med' ? c.med : c.low;

  return (
    <div style={{
      position: 'absolute', inset: 0, zIndex: 20,
      // heavy dark glass: ambient motion behind is muted to a faint shimmer
      background: 'rgba(9,10,15,0.78)',
      backdropFilter: 'blur(28px)',
      WebkitBackdropFilter: 'blur(28px)',
      display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
      gap: 0, fontFamily: font, color: c.textPri,
      animation: 'volar-fade .18s ease-out',
    }}>
      {/* Top-right: pause / stop */}
      <div style={{ position: 'absolute', top: 14, right: 14, display: 'flex', gap: 6 }}>
        <FocusRoundBtn theme={theme} icon={paused ? 'play' : 'pause'} onClick={onTogglePause} title={paused ? 'Resume' : 'Pause'} />
        <FocusRoundBtn theme={theme} icon="x" onClick={onStop} title="End session" />
      </div>

      {/* Timer */}
      <div style={{
        fontSize: 11, fontWeight: 500, letterSpacing: '0.18em', textTransform: 'uppercase',
        color: c.textMut, marginBottom: 10,
      }}>{paused ? 'Paused' : 'Focus'}</div>
      <div style={{
        fontFamily: VOLAR_MONO, fontSize: 76, fontWeight: 600, lineHeight: 1,
        color: timerColor, fontVariantNumeric: 'tabular-nums', letterSpacing: '-0.01em',
        opacity: paused ? 0.45 : 1,
        transition: 'color 1s linear, opacity .2s',
        textShadow: `0 0 40px ${timerColor}44`,
      }}>{fmt(secondsLeft)}</div>

      {/* Progress hairline */}
      <div style={{ width: 240, height: 2, borderRadius: 1, background: 'rgba(255,255,255,0.10)', marginTop: 20, overflow: 'hidden' }}>
        <div style={{
          width: `${frac * 100}%`, height: '100%', borderRadius: 1,
          background: timerColor, transition: 'width 1s linear, background 1s linear',
        }} />
      </div>

      {/* The one task */}
      <div style={{
        marginTop: 40, maxWidth: 480, padding: '0 40px',
        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 10, textAlign: 'center',
      }}>
        <div style={{ fontSize: 23, fontWeight: 500, letterSpacing: '-0.015em', lineHeight: 1.3 }}>
          {task.title}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: c.textSec }}>
          <span style={{ width: 5, height: 5, borderRadius: '50%', background: priorityColor }} />
          <span>{task.priority === 'high' ? 'High' : task.priority === 'med' ? 'Medium' : 'Low'}</span>
          {task.dur && <><span style={{ opacity: 0.4 }}>·</span><span>{task.dur}</span></>}
          {task.timeBadge && <><span style={{ opacity: 0.4 }}>·</span><span>{task.timeBadge}</span></>}
        </div>
      </div>

      {/* Mark done */}
      <button onClick={() => onCompleteTask(task.id)} style={{
        marginTop: 26,
        display: 'flex', alignItems: 'center', gap: 8,
        padding: '9px 20px', borderRadius: 20,
        background: a.solid, border: 'none', color: '#fff',
        fontSize: 13, fontWeight: 500, fontFamily: font, letterSpacing: '-0.005em',
        cursor: 'pointer',
        boxShadow: `0 4px 24px ${a.glow}40`,
      }}>
        <VolarIcon name="check" size={13} color="#fff" strokeWidth={2.4} />
        <span>Mark done</span>
      </button>

      {/* Task navigation */}
      <div style={{
        position: 'absolute', bottom: 22, left: 0, right: 0,
        display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 7,
      }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
          <FocusRoundBtn theme={theme} icon="back" title="Previous task (←)"
            disabled={idx <= 0}
            onClick={() => setIdx(i => Math.max(0, i - 1))} />
          <span style={{
            fontSize: 12, color: c.textSec, fontVariantNumeric: 'tabular-nums',
            minWidth: 52, textAlign: 'center',
          }}>{Math.min(idx, openTasks.length - 1) + 1} of {openTasks.length}</span>
          <FocusRoundBtn theme={theme} icon="chevron" title="Next task (→)"
            disabled={idx >= openTasks.length - 1}
            onClick={() => setIdx(i => Math.min(openTasks.length - 1, i + 1))} />
        </div>
        <div style={{ fontSize: 11, color: c.textMut }}>
          {openTasks.length} task{openTasks.length === 1 ? '' : 's'} left today
        </div>
      </div>
    </div>
  );
}

function FocusRoundBtn({ theme, icon, onClick, title, disabled = false }) {
  const { c } = theme;
  const [hover, setHover] = useStateF(false);
  return (
    <button
      onMouseEnter={() => setHover(true)}
      onMouseLeave={() => setHover(false)}
      onClick={disabled ? undefined : onClick}
      title={title}
      style={{
        width: 30, height: 30, borderRadius: 15,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        background: hover && !disabled ? 'rgba(255,255,255,0.12)' : 'rgba(255,255,255,0.06)',
        border: '0.5px solid rgba(255,255,255,0.10)',
        color: c.textSec,
        cursor: disabled ? 'default' : 'pointer',
        opacity: disabled ? 0.3 : 1,
        transition: 'background .12s',
      }}
    >
      <VolarIcon name={icon} size={12} color="rgba(255,255,255,0.7)" strokeWidth={1.8} />
    </button>
  );
}

Object.assign(window, { VolarFocusOverlay });
