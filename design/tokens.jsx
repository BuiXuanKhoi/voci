// tokens.jsx — shared design tokens, icons, sample data for Volar

const VOLAR_FONT = '-apple-system, BlinkMacSystemFont, "SF Pro Text", "SF Pro", "Helvetica Neue", system-ui, sans-serif';
const VOLAR_MONO = 'ui-monospace, SFMono-Regular, "SF Mono", Menlo, monospace';

// Base palette (per the brief)
const VOLAR_BASE = {
  bg:        '#1C1C1E',
  surface:   '#2C2C2E',
  surfaceHi: '#3A3A3C',
  card:      'rgba(255,255,255,0.05)',
  cardHover: 'rgba(255,255,255,0.08)',
  border:    'rgba(255,255,255,0.08)',
  borderHi:  'rgba(255,255,255,0.14)',
  textPri:   'rgba(255,255,255,0.88)',
  textSec:   'rgba(255,255,255,0.45)',
  textMut:   'rgba(255,255,255,0.25)',
  high:      '#FF6B6B',
  med:       '#FFB347',
  low:       'rgba(255,255,255,0.30)',
  destruct:  '#FF453A',
  done:      '#5BD17A',
};

// Accent swatches (curated, all sit at similar L/C in oklch space)
const VOLAR_ACCENTS = {
  indigo:  { solid: '#6B6BFF', hover: '#8B8BFF', surface: 'rgba(107,107,255,0.15)', glow: 'rgba(107,107,255,0.45)' },
  teal:    { solid: '#3DD5C7', hover: '#6FE3D8', surface: 'rgba(61,213,199,0.15)',  glow: 'rgba(61,213,199,0.45)' },
  amber:   { solid: '#FFB547', hover: '#FFC76B', surface: 'rgba(255,181,71,0.15)',  glow: 'rgba(255,181,71,0.45)' },
  magenta: { solid: '#FF6BD0', hover: '#FF8BD9', surface: 'rgba(255,107,208,0.15)', glow: 'rgba(255,107,208,0.45)' },
};

// Density presets
const VOLAR_DENSITY = {
  cozy:   { rowPadY: 7,  rowGap: 3, sectionGap: 18 },
  comfy:  { rowPadY: 10, rowGap: 4, sectionGap: 22 },
  roomy:  { rowPadY: 14, rowGap: 6, sectionGap: 30 },
};

// Glass intensity presets
const VOLAR_GLASS = {
  subtle:   { blur: 14, bg: 'rgba(28,28,30,0.92)' },
  standard: { blur: 24, bg: 'rgba(28,28,30,0.78)' },
  heavy:    { blur: 36, bg: 'rgba(28,28,30,0.55)' },
};

// Lightweight icon set (16/14/12 px)
function VolarIcon({ name, size = 14, color = 'currentColor', strokeWidth = 1.6 }) {
  const s = size;
  const sw = strokeWidth;
  const stroke = { stroke: color, strokeWidth: sw, fill: 'none', strokeLinecap: 'round', strokeLinejoin: 'round' };
  const paths = {
    mic: <g {...stroke}><rect x="9" y="3" width="6" height="11" rx="3"/><path d="M6 11a6 6 0 0 0 12 0"/><path d="M12 17v4M9 21h6"/></g>,
    focus: <g {...stroke}><circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="4"/><path d="M12 3v3M12 18v3M3 12h3M18 12h3"/></g>,
    inbox: <g {...stroke}><path d="M3 13l3-8h12l3 8M3 13v6a1 1 0 0 0 1 1h16a1 1 0 0 0 1-1v-6M3 13h5l1 2h6l1-2h5"/></g>,
    upcoming: <g {...stroke}><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/></g>,
    today: <g {...stroke}><rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/><circle cx="12" cy="15" r="1.4" fill={color} stroke="none"/></g>,
    plus: <g {...stroke}><path d="M12 5v14M5 12h14"/></g>,
    search: <g {...stroke}><circle cx="11" cy="11" r="6"/><path d="m20 20-4-4"/></g>,
    chevron: <g {...stroke}><path d="m9 6 6 6-6 6"/></g>,
    chevronDown: <g {...stroke}><path d="m6 9 6 6 6-6"/></g>,
    settings: <g {...stroke}><circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 0 0-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 0 0-2-1.2L14 3h-4l-.6 2.6a7 7 0 0 0-2 1.2l-2.3-.9-2 3.4 2 1.5A7 7 0 0 0 5 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-.9a7 7 0 0 0 2 1.2L10 21h4l.6-2.6a7 7 0 0 0 2-1.2l2.3.9 2-3.4-2-1.5c.1-.4.1-.8.1-1.2z"/></g>,
    check: <g {...stroke}><path d="m5 12 5 5L20 7"/></g>,
    clock: <g {...stroke}><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></g>,
    bell: <g {...stroke}><path d="M6 8a6 6 0 0 1 12 0c0 7 3 8 3 8H3s3-1 3-8"/><path d="M10 21a2 2 0 0 0 4 0"/></g>,
    sparkle: <g {...stroke}><path d="M12 3v4M12 17v4M3 12h4M17 12h4M5.6 5.6l2.8 2.8M15.6 15.6l2.8 2.8M5.6 18.4l2.8-2.8M15.6 8.4l2.8-2.8"/></g>,
    flag: <g {...stroke}><path d="M5 21V4M5 4h12l-2 4 2 4H5"/></g>,
    bolt: <g fill={color} stroke="none"><path d="M13 2 4 14h6l-1 8 9-12h-6l1-8z"/></g>,
    cmd: <g {...stroke}><path d="M9 9V6.5A1.5 1.5 0 1 0 7.5 8H17a1.5 1.5 0 1 1-1.5 1.5V9M9 15v2.5A1.5 1.5 0 1 1 7.5 16H17a1.5 1.5 0 1 0-1.5-1.5V15M9 9h6v6H9z"/></g>,
    project: <g {...stroke}><path d="M3 7h7l2 2h9v10a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1z"/></g>,
    waveform: <g {...stroke}><path d="M3 12h2M7 8v8M11 5v14M15 9v6M19 11v2M21 12h0"/></g>,
    home: <g {...stroke}><path d="M3 11 12 3l9 8v9a1 1 0 0 1-1 1h-5v-7H9v7H4a1 1 0 0 1-1-1z"/></g>,
    back: <g {...stroke}><path d="m15 6-6 6 6 6"/></g>,
    x: <g {...stroke}><path d="M6 6l12 12M18 6L6 18"/></g>,
    eject: <g {...stroke}><path d="m6 14 6-8 6 8H6zM5 19h14"/></g>,
    pause: <g {...stroke}><path d="M9 5v14M15 5v14"/></g>,
    play: <g fill={color} stroke="none"><path d="M8 5.5v13a0.6 0.6 0 0 0 .92.5l10-6.5a0.6 0.6 0 0 0 0-1l-10-6.5A0.6 0.6 0 0 0 8 5.5z"/></g>,
    stop: <g fill={color} stroke="none"><rect x="6.5" y="6.5" width="11" height="11" rx="2"/></g>,
    volume: <g {...stroke}><path d="M4 9.5v5h3.5L12 18.5v-13L7.5 9.5H4z"/><path d="M15.5 9a4.2 4.2 0 0 1 0 6M18 6.6a7.6 7.6 0 0 1 0 10.8"/></g>,
    volumeOff: <g {...stroke}><path d="M4 9.5v5h3.5L12 18.5v-13L7.5 9.5H4z"/><path d="M16 9.5l5 5M21 9.5l-5 5"/></g>,
  };
  return (
    <svg width={s} height={s} viewBox="0 0 24 24" style={{ display: 'block', flexShrink: 0 }}>{paths[name]}</svg>
  );
}

// Sample tasks — indie hacker day
const SAMPLE_TASKS = [
  { id: 't1', title: 'Ship the auth fix to staging', priority: 'high', time: '11:30 AM', timeBadge: '11:30', dur: '45 min', done: false, when: 'now', frog: true },
  { id: 't2', title: 'Customer call — Acme onboarding feedback', priority: 'high', time: '2:00 PM', timeBadge: '2:00 PM', dur: '30 min', done: false, when: 'now' },
  { id: 't3', title: 'Write landing page hero copy', priority: 'med', time: '4:00 PM', timeBadge: '4:00 PM', dur: '1 hr', done: false, when: 'later' },
  { id: 't4', title: 'Reply to investor email — Mira @ Lux Ventures', priority: 'med', time: '5:00 PM', timeBadge: '5:00 PM', dur: '20 min', done: false, when: 'later' },
  { id: 't5', title: 'Push v0.4.2 build to TestFlight', priority: 'high', time: '7:30 PM', timeBadge: '7:30 PM', dur: '15 min', done: false, when: 'later' },
  { id: 't6', title: 'Set up Xcode project for v2', priority: 'low', time: '9:30 AM', timeBadge: null, dur: null, done: true, when: 'later' },
  { id: 't7', title: 'Post launch teaser on X', priority: 'low', time: '8:50 AM', timeBadge: null, dur: null, done: true, when: 'later' },
];

const SAMPLE_PROJECTS = []; // intentionally empty — v1.0 has no projects/hierarchy

const SAMPLE_TRANSCRIPT_PARSED = [
  {
    sentence: 'Customer call with Acme tomorrow at 2pm about onboarding feedback, high priority',
    parsed: {
      title: 'Customer call — Acme onboarding feedback',
      when: 'Tomorrow · 2:00 PM',
      priority: 'high',
      duration: '30 min',
      context: 'Created in Cursor',
    },
  },
  {
    sentence: 'Remind me to push the TestFlight build at 7:30 tonight',
    parsed: {
      title: 'Push TestFlight build',
      when: 'Today · 7:30 PM',
      priority: 'high',
      duration: '15 min',
      context: 'Created in Xcode',
    },
  },
  {
    sentence: 'Reply to Mira from Lux Ventures by end of day, medium priority',
    parsed: {
      title: 'Reply to Mira — Lux Ventures',
      when: 'Today · 6:00 PM',
      priority: 'med',
      duration: '20 min',
      context: 'Created in Mail',
    },
  },
];

// Resolved theme = palette + accent variant
function resolveTheme(t) {
  const accent = VOLAR_ACCENTS[t.accent] || VOLAR_ACCENTS.indigo;
  const density = VOLAR_DENSITY[t.density] || VOLAR_DENSITY.comfy;
  const glass = VOLAR_GLASS[t.glass] || VOLAR_GLASS.standard;
  return { c: VOLAR_BASE, a: accent, d: density, g: glass, font: VOLAR_FONT, mono: VOLAR_MONO };
}

Object.assign(window, {
  VolarIcon, VOLAR_BASE, VOLAR_ACCENTS, VOLAR_DENSITY, VOLAR_GLASS,
  SAMPLE_TASKS, SAMPLE_PROJECTS, SAMPLE_TRANSCRIPT_PARSED,
  resolveTheme, VOLAR_FONT, VOLAR_MONO,
});
