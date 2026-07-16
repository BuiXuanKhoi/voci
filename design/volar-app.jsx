// volar-app.jsx — entry, wires DesignCanvas + all artboards + Tweaks panel

const { useState: useStateA, useEffect: useEffectA } = React;

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "accent": "indigo",
  "density": "comfy",
  "glass": "standard",
  "animatedWave": true,
  "transcriptIndex": 0,
  "emptyState": false,
  "ambient": "rain",
  "ambientImage": "",
  "voiceFeedback": true,
  "motion": 70
}/*EDITMODE-END*/;

function App() {
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);
  const theme = resolveTheme(t);

  return (
    <>
      <DesignCanvas>
        {/* ─── HERO: Mac prototype ──────────────────────────────────────── */}
        <DCSection id="mac-proto" title="Volar for Mac" subtitle="Interactive prototype · hold ⌃⌥Space to capture by voice · ambient focus background + sound (🔊 in title bar) · waveform button reads your day aloud">
          <DCArtboard id="mac-today" label="Today view · click anywhere to interact" width={920} height={580}>
            <VolarMacApp theme={theme} initialEmpty={t.emptyState} animatedWave={t.animatedWave}
              ambient={t.ambient} ambientImage={t.ambientImage} voiceFeedback={t.voiceFeedback} motionIntensity={t.motion / 100} />
          </DCArtboard>
          <DCArtboard id="mac-empty" label="Empty state · all clear" width={920} height={580}>
            <VolarMacApp theme={theme} initialEmpty animatedWave={t.animatedWave} enableHotkey={false}
              ambient={t.ambient} ambientImage={t.ambientImage} voiceFeedback={t.voiceFeedback} motionIntensity={t.motion / 100} />
          </DCArtboard>
        </DCSection>

        {/* ─── Quick capture popover states ──────────────────────────────── */}
        <DCSection id="popover-states" title="Quick capture popover" subtitle="Anatomy of the 5 popover states — the screen users see 10–20× a day">
          <DCArtboard id="pop-rec" label="1 · Recording" width={400} height={300}>
            <PopoverFrame theme={theme}>
              <VolarPopover theme={theme} state="recording" transcriptIndex={t.transcriptIndex} animatedWave={t.animatedWave} />
            </PopoverFrame>
          </DCArtboard>
          <DCArtboard id="pop-parsed" label="2 · Parsed" width={400} height={440}>
            <PopoverFrame theme={theme}>
              <VolarPopover theme={theme} state="parsed" transcriptIndex={t.transcriptIndex} animatedWave={t.animatedWave} />
            </PopoverFrame>
          </DCArtboard>
          <DCArtboard id="pop-saving" label="3 · Saving" width={400} height={440}>
            <PopoverFrame theme={theme}>
              <VolarPopover theme={theme} state="saving" transcriptIndex={t.transcriptIndex} animatedWave={t.animatedWave} />
            </PopoverFrame>
          </DCArtboard>
          <DCArtboard id="pop-done" label="4 · Saved" width={400} height={340}>
            <PopoverFrame theme={theme}>
              <VolarPopover theme={theme} state="done" transcriptIndex={t.transcriptIndex} animatedWave={t.animatedWave} />
            </PopoverFrame>
          </DCArtboard>
          <DCArtboard id="pop-error" label="5 · Error" width={400} height={260}>
            <PopoverFrame theme={theme}>
              <VolarPopover theme={theme} state="error" transcriptIndex={t.transcriptIndex} animatedWave={t.animatedWave} />
            </PopoverFrame>
          </DCArtboard>
        </DCSection>

        {/* ─── Morning Frog Prompt ───────────────────────────────────────── */}
        <DCSection id="morning-frog" title="Morning Frog Prompt" subtitle="Daily modal at first launch after 6 AM. One question, quietly asked.">
          <DCArtboard id="frog" label="Modal · over dimmed app" width={760} height={620}>
            <VolarMorningFrog theme={theme} />
          </DCArtboard>
        </DCSection>

        {/* ─── Task Breakdown ────────────────────────────────────────────── */}
        <DCSection id="task-breakdown" title="Task Breakdown" subtitle="Long-press the hotkey (≥1.5s). AI splits the spoken task into ordered sub-tasks.">
          <DCArtboard id="breakdown" label="Breakdown popover" width={500} height={560}>
            <PopoverFrame theme={theme}>
              <VolarTaskBreakdown theme={theme} />
            </PopoverFrame>
          </DCArtboard>
        </DCSection>

        {/* ─── System surfaces ────────────────────────────────────────────── */}
        <DCSection id="system" title="System surfaces" subtitle="Menu bar across three states, plus a macOS-style reminder.">
          <DCArtboard id="menubar" label="Menu bar · idle, listening, focus-lock" width={620} height={300}>
            <VolarMenuBar theme={theme} state="all" />
          </DCArtboard>
          <DCArtboard id="notif" label="Reminder notification" width={420} height={200}>
            <NotificationFrame theme={theme}>
              <VolarNotification theme={theme} />
            </NotificationFrame>
          </DCArtboard>
        </DCSection>

        {/* ─── Onboarding ────────────────────────────────────────────────── */}
        <DCSection id="onboarding" title="Onboarding" subtitle="Three full-window steps. One action per screen.">
          <DCArtboard id="onb-1" label="1 · Welcome" width={720} height={480}>
            <VolarOnboardingStep theme={theme} step={1} />
          </DCArtboard>
          <DCArtboard id="onb-2" label="2 · Microphone" width={720} height={480}>
            <VolarOnboardingStep theme={theme} step={2} />
          </DCArtboard>
          <DCArtboard id="onb-3" label="3 · Try it" width={720} height={480}>
            <VolarOnboardingStep theme={theme} step={3} />
          </DCArtboard>
        </DCSection>

        {/* ─── Settings ───────────────────────────────────────────────────── */}
        <DCSection id="settings" title="Settings" subtitle="Native macOS pattern — tabs across the top, plain rows below.">
          <DCArtboard id="set-gen" label="General" width={620} height={640}>
            <VolarSettings theme={theme} initialTab="general" />
          </DCArtboard>
          <DCArtboard id="set-hot" label="Hotkeys" width={620} height={520}>
            <VolarSettings theme={theme} initialTab="hotkeys" />
          </DCArtboard>
        </DCSection>

        {/* ─── Out of scope: iOS variant ──────────────────────────────────── */}
        <DCSection id="out-of-scope" title="Parked · iOS companion" subtitle="v1.0 explicitly excludes iOS. Keeping the work here in case scope opens up later.">
          <DCArtboard id="mob-today" label="iPhone · Today" width={390} height={844}>
            <VolarMobileApp theme={theme} animatedWave={t.animatedWave} />
          </DCArtboard>
          <DCArtboard id="mob-empty" label="iPhone · Empty" width={390} height={844}>
            <VolarMobileApp theme={theme} initialEmpty animatedWave={t.animatedWave} />
          </DCArtboard>
        </DCSection>
      </DesignCanvas>

      {/* Tweaks panel */}
      <TweaksPanel>
        <TweakSection label="Brand" />
        <TweakColor label="Accent" value={theme.a.solid}
          options={Object.values(VOLAR_ACCENTS).map(v => v.solid)}
          onChange={(hex) => {
            const key = Object.entries(VOLAR_ACCENTS).find(([_, v]) => v.solid === hex)?.[0] || 'indigo';
            setTweak('accent', key);
          }} />

        <TweakSection label="Surface" />
        <TweakRadio label="Density" value={t.density}
          options={['cozy', 'comfy', 'roomy']}
          onChange={(v) => setTweak('density', v)} />
        <TweakRadio label="Glass blur" value={t.glass}
          options={['subtle', 'standard', 'heavy']}
          onChange={(v) => setTweak('glass', v)} />

        <TweakSection label="Focus & ambience" />
        <TweakSelect label="Background" value={t.ambient}
          options={AMBIENT_MODES.map(m => ({ value: m.value, label: m.label }))}
          onChange={(v) => setTweak('ambient', v)} />
        {t.ambient === 'custom' && (
          <TweakText label="Image URL" value={t.ambientImage}
            onChange={(v) => setTweak('ambientImage', v)} />
        )}
        <TweakToggle label="Voice feedback" value={t.voiceFeedback}
          onChange={(v) => setTweak('voiceFeedback', v)} />
        <TweakSlider label="Motion intensity" value={t.motion} min={0} max={100} step={5}
          onChange={(v) => setTweak('motion', v)} />

        <TweakSection label="Voice flow" />
        <TweakSelect label="Sample transcript" value={String(t.transcriptIndex)}
          options={SAMPLE_TRANSCRIPT_PARSED.map((s, i) => ({
            value: String(i),
            label: s.sentence.length > 38 ? s.sentence.slice(0, 36) + '…' : s.sentence,
          }))}
          onChange={(v) => setTweak('transcriptIndex', Number(v))} />
        <TweakToggle label="Animate waveform" value={t.animatedWave}
          onChange={(v) => setTweak('animatedWave', v)} />

        <TweakSection label="States" />
        <TweakToggle label="Show empty state" value={t.emptyState}
          onChange={(v) => setTweak('emptyState', v)} />
      </TweaksPanel>
    </>
  );
}

// Soft "macOS desktop" frame to show popovers in context
function PopoverFrame({ children, theme }) {
  const { c } = theme;
  return (
    <div style={{
      width: '100%', height: '100%',
      background: 'linear-gradient(150deg, #2a1b3b 0%, #1f2a4a 50%, #0e1828 100%)',
      borderRadius: 12,
      padding: 20,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      overflow: 'hidden',
    }}>
      {children}
    </div>
  );
}

function NotificationFrame({ children, theme }) {
  return (
    <div style={{
      width: '100%', height: '100%',
      background: 'linear-gradient(160deg, #1a2a3b 0%, #2a1b3b 100%)',
      borderRadius: 12,
      padding: 20,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
    }}>
      {children}
    </div>
  );
}

const root = ReactDOM.createRoot(document.getElementById('root'));
root.render(<App />);
