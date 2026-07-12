// voci-extras.jsx — onboarding, settings, notification, menu bar icon

const { useState: useStateX, useEffect: useEffectX } = React;

// ─── Menu bar icon (Mac) ─────────────────────────────────────────────────────
function VociMenuBar({ theme, state = 'all' /* idle | active | focuslock | all */ }) {
  const { c, a } = theme;
  // Render a fake "macOS menu bar slice" with the Voci icon in different states
  const Slice = ({ mode }) => {
    const active = mode === 'active';
    const focus = mode === 'focuslock';
    return (
      <div style={{
        display: 'inline-flex', alignItems: 'center', gap: 14,
        padding: '0 14px', height: 28,
        background: 'rgba(28,28,30,0.65)',
        backdropFilter: 'blur(20px) saturate(180%)',
        WebkitBackdropFilter: 'blur(20px) saturate(180%)',
        borderRadius: 8,
        border: `0.5px solid ${c.border}`,
      }}>
        {/* other system icons (fakes) */}
        <span style={{ display: 'inline-flex', gap: 12, alignItems: 'center', opacity: 0.55 }}>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="1.6"><path d="M5 12a7 7 0 0 1 14 0" /><path d="M3 12h2M19 12h2M12 5V3" /><circle cx="12" cy="12" r="2"/></svg>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="1.6"><rect x="3" y="6" width="14" height="12" rx="2"/><path d="m17 10 4-2v8l-4-2z"/></svg>
          <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="1.6"><path d="M12 3a9 9 0 1 0 9 9"/><path d="M12 3a9 9 0 0 1 9 9h-9z"/></svg>
        </span>
        <span style={{ width: 0.5, height: 14, background: 'rgba(255,255,255,0.15)' }} />

        {/* Voci icon group */}
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8 }}>
          <div style={{ position: 'relative', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', width: 18, height: 18 }}>
            {active && (
              <span style={{
                position: 'absolute', inset: -4, borderRadius: '50%',
                background: a.glow, opacity: 0.5, filter: 'blur(6px)',
                animation: 'voci-mic-pulse 1.6s ease-in-out infinite',
              }} />
            )}
            <VocIcon name="mic" size={14} color={active ? a.solid : 'rgba(255,255,255,0.7)'} strokeWidth={active ? 2 : 1.6} />
            {/* Focus Lock dot overlay */}
            {focus && (
              <span style={{
                position: 'absolute', right: 0, bottom: 0,
                width: 7, height: 7, borderRadius: '50%',
                background: a.solid,
                border: `0.5px solid rgba(0,0,0,0.5)`,
                boxShadow: `0 0 6px ${a.glow}`,
              }} />
            )}
          </div>
          {/* Contextual badge text */}
          {active && (
            <span style={{
              fontSize: 11, fontFamily: VOCI_MONO, fontWeight: 500,
              color: a.solid, letterSpacing: '0.02em',
            }}>REC</span>
          )}
          {focus && (
            <span style={{
              fontSize: 11, fontWeight: 500,
              color: a.solid, letterSpacing: '-0.005em',
              display: 'inline-flex', alignItems: 'center', gap: 5,
            }}>
              <span>Ship the auth fix</span>
              <span style={{ color: c.textMut }}>·</span>
              <span style={{ fontFamily: VOCI_MONO, color: a.solid }}>42:18</span>
            </span>
          )}
        </div>

        <span style={{ width: 0.5, height: 14, background: 'rgba(255,255,255,0.15)' }} />

        <span style={{ fontSize: 12, color: 'rgba(255,255,255,0.7)', fontWeight: 500 }}>
          Wed May 21 · 11:24 AM
        </span>
      </div>
    );
  };

  const labelStyle = { fontSize: 11, marginBottom: 6, letterSpacing: '0.05em', textTransform: 'uppercase' };

  return (
    <div style={{
      width: '100%', height: '100%',
      // soft "wallpaper" gradient
      background: 'linear-gradient(135deg, #2a1b3b 0%, #1f2a4a 40%, #0e1828 100%)',
      padding: '14px 18px',
      display: 'flex', flexDirection: 'column', gap: 14,
      fontFamily: VOCI_FONT, color: c.textPri,
      borderRadius: 12,
      justifyContent: 'center',
    }}>
      {state === 'all' ? (
        <>
          <div>
            <div style={{ ...labelStyle, color: 'rgba(255,255,255,0.55)' }}>Idle</div>
            <Slice mode="idle" />
          </div>
          <div>
            <div style={{ ...labelStyle, color: a.solid }}>Listening</div>
            <Slice mode="active" />
          </div>
          <div>
            <div style={{ ...labelStyle, color: a.solid }}>Focus Lock active</div>
            <Slice mode="focuslock" />
          </div>
        </>
      ) : (
        <Slice mode={state} />
      )}

      <style>{`
        @keyframes voci-mic-pulse {
          0%, 100% { transform: scale(1); opacity: 0.5; }
          50% { transform: scale(1.4); opacity: 0.2; }
        }
      `}</style>
    </div>
  );
}

// ─── Onboarding ──────────────────────────────────────────────────────────────
function VociOnboardingStep({ theme, step = 1 /* 1 | 2 | 3 */, width = 720, height = 480 }) {
  const { c, a, font } = theme;

  const titleStyle = {
    fontSize: 32, fontWeight: 500, letterSpacing: '-0.025em', color: c.textPri,
    lineHeight: 1.15, marginBottom: 14, textWrap: 'pretty',
  };
  const subStyle = {
    fontSize: 15, color: c.textSec, lineHeight: 1.5, maxWidth: 420, marginBottom: 30,
    textWrap: 'pretty',
  };

  return (
    <div style={{
      width, height,
      borderRadius: 14, overflow: 'hidden',
      background: c.bg,
      fontFamily: font, color: c.textPri,
      display: 'flex', flexDirection: 'column',
      position: 'relative',
      boxShadow: '0 30px 80px rgba(0,0,0,0.55), 0 0 0 0.5px rgba(255,255,255,0.06)',
    }}>
      {/* Faux titlebar */}
      <div style={{
        height: 38, paddingLeft: 14,
        display: 'flex', alignItems: 'center',
        borderBottom: `0.5px solid ${c.border}`,
        background: c.surface,
      }}>
        <TrafficLights />
      </div>

      {/* Step indicator */}
      <div style={{
        position: 'absolute', top: 52, right: 24,
        display: 'flex', gap: 6, alignItems: 'center',
      }}>
        {[1,2,3].map(i => (
          <span key={i} style={{
            width: i === step ? 18 : 6, height: 6, borderRadius: 3,
            background: i === step ? a.solid : 'rgba(255,255,255,0.15)',
            transition: 'all .2s',
          }} />
        ))}
      </div>

      <div style={{
        flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 40,
      }}>
        <div style={{
          width: '100%', maxWidth: 520,
          display: 'flex', flexDirection: 'column', alignItems: 'flex-start',
        }}>
          {step === 1 && (
            <>
              {/* logo mark */}
              <div style={{
                width: 84, height: 84, borderRadius: 22, marginBottom: 28,
                background: `linear-gradient(140deg, ${a.solid}, ${a.hover})`,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                boxShadow: `0 12px 40px ${a.glow}, inset 0 1px 0 rgba(255,255,255,0.25)`,
                border: `0.5px solid rgba(255,255,255,0.18)`,
              }}>
                <VocIcon name="mic" size={42} color="#fff" strokeWidth={1.8} />
              </div>
              <div style={titleStyle}>
                Hold <KeyBadge theme={theme} accent>⌃</KeyBadge> <KeyBadge theme={theme} accent>⌥</KeyBadge> <KeyBadge theme={theme} accent>Space</KeyBadge>.<br/>
                Speak. Done.
              </div>
              <div style={subStyle}>
                Voci is a voice-first task manager. No typing, no menus — just hold the hotkey from anywhere on your Mac and say what you need to do.
              </div>
              <button style={{
                height: 44, padding: '0 22px', borderRadius: 11,
                background: a.solid, color: '#fff',
                border: `0.5px solid rgba(255,255,255,0.18)`,
                fontSize: 14, fontWeight: 500, fontFamily: font,
                boxShadow: `0 10px 30px ${a.glow}, inset 0 0.5px 0 rgba(255,255,255,0.3)`,
                letterSpacing: '-0.005em',
              }}>Get started →</button>
            </>
          )}

          {step === 2 && (
            <>
              <div style={{
                width: 84, height: 84, borderRadius: 22, marginBottom: 28,
                background: a.surface,
                display: 'flex', alignItems: 'center', justifyContent: 'center',
                border: `0.5px solid ${a.solid}55`,
                boxShadow: `0 0 40px ${a.glow}40`,
                position: 'relative',
              }}>
                <VocIcon name="mic" size={42} color={a.solid} strokeWidth={1.8} />
                {/* concentric rings */}
                {[1,2,3].map(i => (
                  <span key={i} style={{
                    position: 'absolute', inset: 0, borderRadius: 22,
                    border: `1px solid ${a.solid}`,
                    opacity: 0.15 / i, transform: `scale(${1 + i * 0.18})`,
                  }} />
                ))}
              </div>
              <div style={titleStyle}>Voci needs your microphone.</div>
              <div style={subStyle}>
                Audio is processed on-device using Apple's Speech framework. Nothing is uploaded. Nothing is stored. The waveform stays on your Mac.
              </div>
              <div style={{ display: 'flex', gap: 10 }}>
                <button style={{
                  height: 44, padding: '0 22px', borderRadius: 11,
                  background: a.solid, color: '#fff',
                  border: `0.5px solid rgba(255,255,255,0.18)`,
                  fontSize: 14, fontWeight: 500, fontFamily: font,
                  boxShadow: `0 10px 30px ${a.glow}, inset 0 0.5px 0 rgba(255,255,255,0.3)`,
                }}>Allow microphone</button>
                <button style={{
                  height: 44, padding: '0 18px', borderRadius: 11,
                  background: 'transparent', color: c.textSec,
                  border: `0.5px solid ${c.border}`,
                  fontSize: 14, fontWeight: 500, fontFamily: font,
                }}>Not now</button>
              </div>
              <div style={{ marginTop: 22, display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: c.textMut }}>
                <span style={{ width: 6, height: 6, borderRadius: '50%', background: c.done }} />
                On-device · No network calls
              </div>
            </>
          )}

          {step === 3 && (
            <>
              <div style={{
                marginBottom: 32, padding: '14px 18px',
                borderRadius: 14,
                background: a.surface,
                border: `0.5px solid ${a.solid}44`,
                display: 'inline-flex', alignItems: 'center', gap: 8,
                animation: 'voci-kbd-pulse 1.6s ease-in-out infinite',
              }}>
                <KeyBadge theme={theme} accent>⌃</KeyBadge>
                <KeyBadge theme={theme} accent>⌥</KeyBadge>
                <KeyBadge theme={theme} accent>Space</KeyBadge>
              </div>
              <div style={titleStyle}>Try it now.</div>
              <div style={subStyle}>
                Hold the hotkey and say your first task. We'll parse the time, priority, and project for you.
              </div>
              <div style={{
                padding: '12px 16px', borderRadius: 12,
                background: 'rgba(255,255,255,0.04)',
                border: `0.5px solid ${c.border}`,
                fontSize: 14, color: c.textPri, letterSpacing: '-0.005em',
                marginBottom: 22, maxWidth: 460,
              }}>
                <div style={{ fontSize: 11, color: c.textMut, marginBottom: 4, letterSpacing: '0.06em', textTransform: 'uppercase' }}>
                  Try saying
                </div>
                <span style={{ color: c.textPri }}>"Call John tomorrow at 3pm, high priority"</span>
              </div>
              <button style={{
                height: 36, padding: '0 14px',
                background: 'transparent', color: c.textSec,
                border: 'none', fontSize: 13, fontWeight: 500, fontFamily: font,
              }}>Skip for now</button>

              <style>{`
                @keyframes voci-kbd-pulse {
                  0%, 100% { box-shadow: 0 0 0 0 ${a.glow}; }
                  50% { box-shadow: 0 0 0 14px transparent; }
                }
              `}</style>
            </>
          )}
        </div>
      </div>

      {/* footer step counter */}
      <div style={{
        padding: '14px 24px', display: 'flex', justifyContent: 'space-between', alignItems: 'center',
        borderTop: `0.5px solid ${c.border}`, fontSize: 12, color: c.textMut,
      }}>
        <span>Step {step} of 3</span>
        <span style={{ color: c.textSec }}>voci.app</span>
      </div>
    </div>
  );
}

// ─── Settings window ─────────────────────────────────────────────────────────
function VociSettings({ theme, width = 620, height = 480, initialTab = 'general' }) {
  const { c, a, font } = theme;
  const [tab, setTab] = useStateX(initialTab);
  const [launch, setLaunch] = useStateX(true);
  const [calendar, setCalendar] = useStateX(false);
  const [reminder, setReminder] = useStateX('15min');
  const [duration, setDuration] = useStateX('30min');

  const tabs = [
    { id: 'general', icon: 'settings', label: 'General' },
    { id: 'hotkeys', icon: 'cmd',      label: 'Hotkeys' },
    { id: 'notifs',  icon: 'bell',     label: 'Notifications' },
    { id: 'appear',  icon: 'sparkle',  label: 'Appearance' },
    { id: 'about',   icon: 'project',  label: 'About' },
  ];

  return (
    <div style={{
      width, height,
      borderRadius: 12, overflow: 'hidden',
      background: c.bg,
      fontFamily: font, color: c.textPri,
      display: 'flex', flexDirection: 'column',
      boxShadow: '0 30px 80px rgba(0,0,0,0.55), 0 0 0 0.5px rgba(255,255,255,0.06)',
    }}>
      {/* Title bar with tabs */}
      <div style={{
        background: c.surface, paddingTop: 0,
        borderBottom: `0.5px solid ${c.border}`,
      }}>
        <div style={{ height: 38, display: 'flex', alignItems: 'center', paddingLeft: 14, position: 'relative' }}>
          <TrafficLights />
          <div style={{
            position: 'absolute', left: '50%', top: '50%', transform: 'translate(-50%,-50%)',
            fontSize: 13, fontWeight: 500, letterSpacing: '-0.01em', color: c.textPri,
          }}>Settings</div>
        </div>
        <div style={{ display: 'flex', justifyContent: 'center', padding: '4px 14px 10px', gap: 4 }}>
          {tabs.map(t => (
            <button key={t.id} onClick={() => setTab(t.id)} style={{
              display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 4,
              padding: '6px 14px', borderRadius: 8,
              background: tab === t.id ? a.surface : 'transparent',
              border: 'none',
              color: tab === t.id ? a.solid : c.textSec,
              fontSize: 11, fontWeight: 500, fontFamily: font, letterSpacing: '-0.005em',
              cursor: 'default',
              minWidth: 72,
            }}>
              <VocIcon name={t.icon} size={18} color={tab === t.id ? a.solid : c.textSec} strokeWidth={1.6} />
              {t.label}
            </button>
          ))}
        </div>
      </div>

      <div style={{ flex: 1, overflow: 'auto', padding: '22px 32px' }}>
        {tab === 'general' && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <SettingsRow theme={theme} label="Launch at login"
              hint="Voci starts in the background and lives in your menu bar.">
              <Toggle value={launch} onChange={setLaunch} theme={theme} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Default task duration"
              hint="Block this much time when a task has no explicit length.">
              <Segmented theme={theme} value={duration} onChange={setDuration} options={[
                { id: '15min', label: '15' }, { id: '30min', label: '30' }, { id: '60min', label: '60 min' },
              ]} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Default reminder before deadline"
              hint="When to nudge you before a task is due.">
              <Segmented theme={theme} value={reminder} onChange={setReminder} options={[
                { id: '5min', label: '5' }, { id: '15min', label: '15' },
                { id: '30min', label: '30 min' }, { id: 'none', label: 'None' },
              ]} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Hyperfocus interrupt after"
              hint="Voci checks in if you've been deep on one task this long.">
              <Segmented theme={theme} value="90min" onChange={() => {}} options={[
                { id: '60min', label: '60' }, { id: '90min', label: '90' }, { id: '120min', label: '120 min' },
              ]} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Show morning frog prompt"
              hint="A daily question at first launch: what's the ONE task that matters most?">
              <Toggle value={true} onChange={() => {}} theme={theme} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Capture foreground app context"
              hint="Tags new tasks with the app you were in when you captured them.">
              <Toggle value={true} onChange={() => {}} theme={theme} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Calendar integration"
              hint="Mirror tasks with scheduled times into your Mac Calendar.">
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <Toggle value={calendar} onChange={setCalendar} theme={theme} />
                <button style={{
                  height: 26, padding: '0 12px', borderRadius: 7,
                  background: 'rgba(255,255,255,0.06)', color: c.textPri,
                  border: `0.5px solid ${c.border}`, fontSize: 12, fontFamily: font, fontWeight: 500,
                }}>Open in Calendar</button>
              </div>
            </SettingsRow>
          </div>
        )}

        {tab === 'hotkeys' && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
            <SettingsRow theme={theme} label="Quick capture"
              hint="Hold this combo from anywhere to start recording.">
              <KeyRecorder theme={theme} keys={['⌃', '⌥', 'Space']} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Task breakdown (long press)"
              hint="Hold the same hotkey ≥1.5s to have AI split the task into steps.">
              <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8,
                fontSize: 11, color: c.textSec,
                padding: '4px 10px', borderRadius: 8,
                background: 'rgba(0,0,0,0.25)',
                border: `0.5px solid ${c.border}`,
              }}>
                <span>Long-press</span>
                <KeyBadge theme={theme}>⌃</KeyBadge>
                <KeyBadge theme={theme}>⌥</KeyBadge>
                <KeyBadge theme={theme}>Space</KeyBadge>
              </div>
            </SettingsRow>
            <SettingsRow theme={theme} label="Show Voci window"
              hint="Bring the main window to the front.">
              <KeyRecorder theme={theme} keys={['⌃', '⌥', 'V']} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Toggle Focus Lock"
              hint="Lock the current task as your only focus — Voci will gently interrupt if you drift.">
              <KeyRecorder theme={theme} keys={['⌃', '⌥', 'F']} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Complete current task"
              hint="When Focus Lock is active, mark the current task done without opening the window.">
              <KeyRecorder theme={theme} keys={['⌃', '⌥', '↵']} />
            </SettingsRow>
          </div>
        )}

        {tab === 'notifs' && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            <SettingsRow theme={theme} label="Show reminders" hint="Send a macOS notification before each task.">
              <Toggle value={true} onChange={() => {}} theme={theme} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Sound" hint="Subtle chime when a task is captured.">
              <Toggle value={true} onChange={() => {}} theme={theme} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Focus mode aware" hint="Stay silent while macOS Focus is on.">
              <Toggle value={false} onChange={() => {}} theme={theme} />
            </SettingsRow>
          </div>
        )}

        {tab === 'appear' && (
          <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
            <SettingsRow theme={theme} label="Theme" hint="Voci is dark-only — the way Mac power users live.">
              <Segmented theme={theme} value="dark" onChange={() => {}} options={[
                { id: 'dark', label: 'Dark' }, { id: 'system', label: 'Match system', disabled: true },
              ]} />
            </SettingsRow>
            <SettingsRow theme={theme} label="Accent color" hint="Used for active states and the capture button.">
              <div style={{ display: 'flex', gap: 10 }}>
                {Object.entries(VOCI_ACCENTS).map(([k, v]) => (
                  <span key={k} style={{
                    width: 22, height: 22, borderRadius: '50%',
                    background: v.solid,
                    border: `0.5px solid ${k === 'indigo' ? '#fff' : 'rgba(255,255,255,0.2)'}`,
                    boxShadow: k === 'indigo' ? `0 0 0 2px ${c.bg}, 0 0 0 3.5px ${v.solid}` : 'none',
                  }} />
                ))}
              </div>
            </SettingsRow>
            <SettingsRow theme={theme} label="Density" hint="How tight the rows pack.">
              <Segmented theme={theme} value="comfy" onChange={() => {}} options={[
                { id: 'cozy', label: 'Cozy' }, { id: 'comfy', label: 'Comfy' }, { id: 'roomy', label: 'Roomy' },
              ]} />
            </SettingsRow>
          </div>
        )}

        {tab === 'about' && (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14, padding: 16 }}>
            <div style={{
              width: 64, height: 64, borderRadius: 16,
              background: `linear-gradient(140deg, ${a.solid}, ${a.hover})`,
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              boxShadow: `0 8px 30px ${a.glow}`,
            }}>
              <VocIcon name="mic" size={32} color="#fff" strokeWidth={1.8} />
            </div>
            <div style={{ fontSize: 22, fontWeight: 500, letterSpacing: '-0.02em' }}>Voci 1.0.2</div>
            <div style={{ fontSize: 13, color: c.textSec }}>Voice-first task manager for Mac. Built in Cambridge.</div>
            <div style={{ display: 'flex', gap: 8, marginTop: 4 }}>
              <span style={{
                padding: '4px 10px', borderRadius: 14,
                background: a.surface, color: a.solid, fontSize: 11, fontWeight: 500,
              }}>What's new</span>
              <span style={{
                padding: '4px 10px', borderRadius: 14,
                background: 'rgba(255,255,255,0.06)', color: c.textSec, fontSize: 11, fontWeight: 500,
              }}>Acknowledgements</span>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

function SettingsRow({ label, hint, children, theme }) {
  const { c } = theme;
  return (
    <div style={{
      display: 'grid', gridTemplateColumns: '1fr auto', gap: 16, alignItems: 'center',
      padding: '14px 18px',
      background: c.card,
      border: `0.5px solid ${c.border}`,
      borderRadius: 11,
    }}>
      <div style={{ minWidth: 0 }}>
        <div style={{ fontSize: 13.5, fontWeight: 500, color: c.textPri, letterSpacing: '-0.005em' }}>{label}</div>
        {hint && <div style={{ fontSize: 12, color: c.textSec, marginTop: 3, lineHeight: 1.45 }}>{hint}</div>}
      </div>
      <div>{children}</div>
    </div>
  );
}

function Toggle({ value, onChange, theme }) {
  const { c, a } = theme;
  return (
    <div onClick={() => onChange(!value)} style={{
      width: 38, height: 22, borderRadius: 12,
      background: value ? a.solid : 'rgba(255,255,255,0.12)',
      position: 'relative', cursor: 'default',
      transition: 'background .15s',
      boxShadow: value ? `0 0 12px ${a.glow}40` : 'none',
    }}>
      <div style={{
        position: 'absolute', top: 2, left: value ? 18 : 2,
        width: 18, height: 18, borderRadius: '50%', background: '#fff',
        boxShadow: '0 1px 3px rgba(0,0,0,0.4)',
        transition: 'left .18s',
      }} />
    </div>
  );
}

function Segmented({ value, onChange, options, theme }) {
  const { c, a } = theme;
  return (
    <div style={{
      display: 'inline-flex',
      background: 'rgba(0,0,0,0.25)',
      borderRadius: 8, padding: 2,
      border: `0.5px solid ${c.border}`,
    }}>
      {options.map(o => (
        <button key={o.id} onClick={() => !o.disabled && onChange(o.id)} style={{
          padding: '4px 12px', height: 24, borderRadius: 6,
          background: value === o.id ? a.surface : 'transparent',
          color: o.disabled ? c.textMut : (value === o.id ? a.solid : c.textSec),
          border: 'none', fontSize: 11.5, fontWeight: 500, fontFamily: VOCI_FONT,
          cursor: 'default', opacity: o.disabled ? 0.5 : 1,
        }}>{o.label}</button>
      ))}
    </div>
  );
}

function KeyRecorder({ theme, keys = ['⌃', '⌥', 'Space'] }) {
  const { c, a } = theme;
  return (
    <div style={{
      display: 'inline-flex', alignItems: 'center', gap: 6,
      padding: '4px 10px', height: 28, borderRadius: 8,
      background: 'rgba(0,0,0,0.25)',
      border: `0.5px solid ${c.border}`,
    }}>
      {keys.map((k, i) => <KeyBadge key={i} theme={theme}>{k}</KeyBadge>)}
      <span style={{
        marginLeft: 6, fontSize: 11, color: a.solid, fontWeight: 500,
      }}>Change</span>
    </div>
  );
}

// ─── Notification (macOS-style) ──────────────────────────────────────────────
function VociNotification({ theme, width = 380, height = 150 }) {
  const { c, a, font } = theme;
  return (
    <div style={{
      width, height,
      borderRadius: 14,
      background: 'rgba(40,40,42,0.85)',
      backdropFilter: 'blur(28px) saturate(180%)',
      WebkitBackdropFilter: 'blur(28px) saturate(180%)',
      border: `0.5px solid rgba(255,255,255,0.12)`,
      boxShadow: '0 24px 60px rgba(0,0,0,0.55), inset 0 1px 0 rgba(255,255,255,0.06)',
      fontFamily: font, color: c.textPri,
      padding: '12px 14px',
      display: 'flex', flexDirection: 'column', gap: 8,
    }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <div style={{
          width: 38, height: 38, borderRadius: 9,
          background: `linear-gradient(140deg, ${a.solid}, ${a.hover})`,
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          boxShadow: `inset 0 1px 0 rgba(255,255,255,0.25)`,
        }}>
          <VocIcon name="mic" size={20} color="#fff" strokeWidth={1.8} />
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 6 }}>
            <span style={{ fontSize: 13, fontWeight: 500, color: c.textPri }}>Voci</span>
            <span style={{ fontSize: 11, color: c.textSec }}>· now</span>
          </div>
          <div style={{ fontSize: 13, fontWeight: 500, color: c.textPri, marginTop: 2, letterSpacing: '-0.005em' }}>
            Coming up: Customer call — Acme onboarding
          </div>
          <div style={{ fontSize: 12, color: c.textSec, marginTop: 1 }}>In 15 minutes · 2:00 PM</div>
        </div>
      </div>
      <div style={{ display: 'flex', gap: 6, marginTop: 2 }}>
        {[
          { l: 'Done', solid: false },
          { l: 'Snooze 10 min', solid: false },
          { l: 'Reschedule', solid: true },
        ].map(b => (
          <button key={b.l} style={{
            flex: 1, height: 28, borderRadius: 8,
            background: b.solid ? a.surface : 'rgba(255,255,255,0.08)',
            color: b.solid ? a.solid : c.textPri,
            border: `0.5px solid ${b.solid ? a.solid + '44' : 'rgba(255,255,255,0.06)'}`,
            fontSize: 11.5, fontWeight: 500, fontFamily: font, letterSpacing: '-0.005em',
          }}>{b.l}</button>
        ))}
      </div>
    </div>
  );
}

// ─── Standalone empty state (for canvas) ─────────────────────────────────────
function VociEmptyArtboard({ theme, width = 460, height = 380 }) {
  const { c, font } = theme;
  return (
    <div style={{
      width, height,
      background: c.bg,
      borderRadius: 12,
      border: `0.5px solid ${c.border}`,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      fontFamily: font,
      boxShadow: '0 30px 80px rgba(0,0,0,0.45)',
    }}>
      <EmptyToday theme={theme} />
    </div>
  );
}

// ─── Morning Frog Prompt ─────────────────────────────────────────────────────
function VociMorningFrog({ theme, width = 720, height = 580 }) {
  const { c, a, font } = theme;
  const candidates = [
    { id: 'c1', title: 'Customer call — Acme onboarding feedback', flag: 'urgent' },
    { id: 'c2', title: 'Write landing page hero copy', flag: null },
    { id: 'c3', title: 'Push v0.4.2 to TestFlight', flag: null },
    { id: 'c4', title: 'Reply to Mira — Lux Ventures', flag: null },
  ];
  const [picked, setPicked] = useStateX(null);

  return (
    <div style={{
      width, height,
      borderRadius: 14, overflow: 'hidden',
      background: c.bg,
      fontFamily: font, color: c.textPri,
      display: 'flex', flexDirection: 'column',
      position: 'relative',
      boxShadow: '0 30px 80px rgba(0,0,0,0.55), 0 0 0 0.5px rgba(255,255,255,0.06)',
    }}>
      {/* Faux titlebar (dimmed) */}
      <div style={{
        height: 38, paddingLeft: 14,
        display: 'flex', alignItems: 'center',
        borderBottom: `0.5px solid ${c.border}`,
        background: c.surface,
        opacity: 0.6,
      }}>
        <TrafficLights active={false} />
      </div>

      {/* Dimmed window contents behind modal */}
      <div style={{
        flex: 1, position: 'relative',
        background: `linear-gradient(180deg, ${c.bg}, ${c.surface})`,
        display: 'flex', alignItems: 'center', justifyContent: 'center',
        padding: '40px 60px',
      }}>
        {/* faux task list silhouette in background */}
        <div style={{
          position: 'absolute', inset: 0, padding: '32px 80px',
          display: 'flex', flexDirection: 'column', gap: 8,
          opacity: 0.18, filter: 'blur(0.5px)',
        }}>
          {[0,1,2,3].map(i => (
            <div key={i} style={{
              height: 44, borderRadius: 9,
              background: 'rgba(255,255,255,0.05)',
              border: `0.5px solid ${c.border}`,
            }} />
          ))}
        </div>

        {/* Modal */}
        <div style={{
          position: 'relative',
          width: '100%', maxWidth: 460,
          padding: '36px 32px 24px',
          background: 'rgba(28,28,30,0.94)',
          backdropFilter: 'blur(28px) saturate(180%)',
          WebkitBackdropFilter: 'blur(28px) saturate(180%)',
          border: `0.5px solid ${c.borderHi}`,
          borderRadius: 16,
          boxShadow: '0 30px 80px rgba(0,0,0,0.55), inset 0 1px 0 rgba(255,255,255,0.05)',
          display: 'flex', flexDirection: 'column', gap: 16, textAlign: 'center',
        }}>
          <div style={{
            fontSize: 22, fontWeight: 500, color: c.textPri, letterSpacing: '-0.015em',
          }}>Good morning.</div>
          <div style={{
            fontSize: 16, color: c.textPri, lineHeight: 1.5, letterSpacing: '-0.005em',
            textWrap: 'pretty', maxWidth: 360, margin: '0 auto',
          }}>
            What's the one task that, if you finished it today, would make today a win?
          </div>

          {/* Voice CTA */}
          <button style={{
            margin: '8px auto 0',
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 10,
            height: 48, padding: '0 22px',
            background: a.surface,
            border: `0.5px solid ${a.solid}44`,
            borderRadius: 14,
            color: a.solid,
            fontSize: 14, fontWeight: 500, fontFamily: font, letterSpacing: '-0.005em',
            boxShadow: `0 0 0 0 ${a.glow}`,
            animation: 'voci-frog-pulse 2.4s ease-in-out infinite',
          }}>
            <VocIcon name="mic" size={16} color={a.solid} strokeWidth={1.8} />
            Hold <KeyBadge theme={theme} accent>Space</KeyBadge> to answer
          </button>

          {/* divider */}
          <div style={{
            display: 'flex', alignItems: 'center', gap: 10, color: c.textMut,
            fontSize: 11, marginTop: 4,
          }}>
            <span style={{ flex: 1, height: 0.5, background: c.border }} />
            <span>or</span>
            <span style={{ flex: 1, height: 0.5, background: c.border }} />
          </div>

          {/* candidates */}
          <div style={{
            display: 'flex', flexDirection: 'column', gap: 4, marginTop: 2,
            textAlign: 'left',
          }}>
            <div style={{
              fontSize: 11, fontWeight: 500, color: c.textMut,
              letterSpacing: '0.07em', textTransform: 'uppercase',
              padding: '0 8px 6px',
            }}>Pick from your list</div>
            {candidates.map(c2 => (
              <div key={c2.id} onClick={() => setPicked(c2.id)} style={{
                display: 'flex', alignItems: 'center', gap: 10,
                padding: '10px 12px',
                borderRadius: 9,
                background: picked === c2.id ? a.surface : 'transparent',
                border: `0.5px solid ${picked === c2.id ? a.solid + '44' : 'transparent'}`,
                cursor: 'default',
                transition: 'background .12s',
              }}>
                <span style={{
                  width: 14, height: 14, borderRadius: '50%',
                  border: `1.5px solid ${picked === c2.id ? a.solid : 'rgba(255,255,255,0.28)'}`,
                  background: picked === c2.id ? a.solid : 'transparent',
                  display: 'flex', alignItems: 'center', justifyContent: 'center',
                  flexShrink: 0,
                }}>
                  {picked === c2.id && <VocIcon name="check" size={9} color="#fff" strokeWidth={2.6} />}
                </span>
                <span style={{
                  flex: 1, fontSize: 13, color: c.textPri, letterSpacing: '-0.005em',
                }}>{c2.title}</span>
                {c2.flag === 'urgent' && (
                  <span style={{
                    display: 'inline-flex', alignItems: 'center', gap: 5,
                    padding: '2px 7px', borderRadius: 14,
                    background: 'rgba(255,107,107,0.12)',
                    color: c.high, fontSize: 10.5, fontWeight: 500, letterSpacing: '-0.005em',
                  }}>
                    <span style={{ width: 5, height: 5, borderRadius: '50%', background: c.high }} />
                    urgent
                  </span>
                )}
              </div>
            ))}
          </div>

          <button style={{
            margin: '8px auto 0',
            height: 32, padding: '0 14px',
            background: 'transparent', color: c.textMut,
            border: 'none', fontSize: 12, fontWeight: 500, fontFamily: font,
            cursor: 'default',
          }}>Skip today</button>

          <style>{`
            @keyframes voci-frog-pulse {
              0%, 100% { box-shadow: 0 0 0 0 ${a.glow}; }
              50% { box-shadow: 0 0 0 8px transparent; }
            }
          `}</style>
        </div>
      </div>
    </div>
  );
}

// ─── Task Breakdown Screen ──────────────────────────────────────────────────
function VociTaskBreakdown({ theme, width = 480, height = 540 }) {
  const { c, a, font } = theme;
  const steps = [
    { n: 1, label: 'Open Framer',            dur: '10 min' },
    { n: 2, label: 'Draft headline + subhead', dur: '5 min'  },
    { n: 3, label: 'Drop in demo screenshot', dur: '10 min' },
    { n: 4, label: 'Test email signup form',  dur: '10 min' },
    { n: 5, label: 'Publish + share link',    dur: '5 min'  },
  ];
  const total = '40 min';

  return (
    <div style={{
      width, height,
      borderRadius: 16,
      background: 'rgba(28,28,30,0.94)',
      backdropFilter: 'blur(28px) saturate(180%)',
      WebkitBackdropFilter: 'blur(28px) saturate(180%)',
      border: `0.5px solid ${c.borderHi}`,
      boxShadow: '0 30px 80px rgba(0,0,0,0.55), inset 0 1px 0 rgba(255,255,255,0.05)',
      fontFamily: font, color: c.textPri,
      padding: '16px 16px 14px',
      display: 'flex', flexDirection: 'column', gap: 12,
      overflow: 'hidden',
    }}>
      {/* header */}
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 }}>
        <div style={{ minWidth: 0 }}>
          <div style={{
            fontSize: 11, fontWeight: 500, color: c.textMut,
            letterSpacing: '0.07em', textTransform: 'uppercase',
          }}>Breaking down</div>
          <div style={{
            fontSize: 16, fontWeight: 500, color: c.textPri, letterSpacing: '-0.005em',
            marginTop: 4, lineHeight: 1.35,
          }}>"Launch landing page"</div>
        </div>
        <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6,
          fontSize: 11, color: a.solid, fontWeight: 500,
          padding: '3px 9px', borderRadius: 14,
          background: a.surface, border: `0.5px solid ${a.solid}33`,
        }}>
          <VocIcon name="sparkle" size={11} color={a.solid} strokeWidth={1.8} />
          AI
        </div>
      </div>

      {/* steps card */}
      <div style={{
        background: c.card,
        border: `0.5px solid ${c.border}`,
        borderRadius: 12,
        padding: 6,
        display: 'flex', flexDirection: 'column', gap: 2,
      }}>
        {steps.map((s, i) => (
          <div key={s.n} style={{
            display: 'flex', alignItems: 'center', gap: 12,
            padding: '10px 10px',
            borderRadius: 9,
            background: 'transparent',
          }}>
            {/* drag handle */}
            <span style={{
              flex: '0 0 auto', width: 12, height: 16,
              display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 2,
              opacity: 0.35,
            }}>
              <span style={{ width: 12, height: 1, background: c.textSec }} />
              <span style={{ width: 12, height: 1, background: c.textSec }} />
              <span style={{ width: 12, height: 1, background: c.textSec }} />
            </span>
            {/* number */}
            <span style={{
              flex: '0 0 auto',
              width: 22, height: 22, borderRadius: '50%',
              background: a.surface, color: a.solid,
              border: `0.5px solid ${a.solid}33`,
              display: 'flex', alignItems: 'center', justifyContent: 'center',
              fontSize: 11, fontWeight: 500, fontVariantNumeric: 'tabular-nums',
            }}>{s.n}</span>
            <span style={{
              flex: 1, fontSize: 13, color: c.textPri, letterSpacing: '-0.005em',
              whiteSpace: 'nowrap', overflow: 'hidden', textOverflow: 'ellipsis',
            }}>{s.label}</span>
            <span style={{
              fontSize: 11, color: c.textSec, fontVariantNumeric: 'tabular-nums',
              padding: '2px 8px', borderRadius: 14,
              background: 'rgba(255,255,255,0.04)',
              border: `0.5px solid ${c.border}`,
            }}>{s.dur}</span>
          </div>
        ))}
      </div>

      {/* summary */}
      <div style={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between',
        padding: '0 6px', fontSize: 12, color: c.textSec, letterSpacing: '-0.005em',
      }}>
        <span>Total: <span style={{ color: c.textPri, fontWeight: 500 }}>{total}</span> · {steps.length} sub-tasks</span>
        <span style={{ color: c.textMut }}>Drag to reorder · click to edit</span>
      </div>

      <div style={{ flex: 1 }} />

      {/* actions */}
      <div style={{ display: 'flex', gap: 8 }}>
        <button style={{
          flex: '0 0 auto', height: 34, padding: '0 14px', borderRadius: 9,
          background: 'rgba(255,255,255,0.06)',
          border: `0.5px solid ${c.border}`,
          color: c.textPri, fontSize: 13, fontWeight: 500, fontFamily: font,
        }}>Edit</button>
        <button style={{
          flex: '0 0 auto', height: 34, padding: '0 14px', borderRadius: 9,
          background: 'rgba(255,255,255,0.06)',
          border: `0.5px solid ${c.border}`,
          color: c.textPri, fontSize: 13, fontWeight: 500, fontFamily: font,
        }}>Cancel</button>
        <button style={{
          flex: 1, height: 34, borderRadius: 9,
          background: a.solid, color: '#fff',
          border: `0.5px solid rgba(255,255,255,0.18)`,
          fontSize: 13, fontWeight: 500, fontFamily: font,
          boxShadow: `0 6px 18px ${a.glow}, inset 0 0.5px 0 rgba(255,255,255,0.25)`,
          display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 8,
          letterSpacing: '-0.005em',
        }}>
          Save all as tasks
          <span style={{ opacity: 0.85, fontSize: 12 }}>↵</span>
        </button>
      </div>
    </div>
  );
}

Object.assign(window, {
  VociMenuBar, VociOnboardingStep, VociSettings, VociNotification, VociEmptyArtboard,
  VociMorningFrog, VociTaskBreakdown,
  SettingsRow, Toggle, Segmented, KeyRecorder,
});
