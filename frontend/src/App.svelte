<script>
  import { onMount, onDestroy, tick } from 'svelte';
  import Calendar from '@event-calendar/core';
  import DayGrid from '@event-calendar/day-grid';
  import TimeGrid from '@event-calendar/time-grid';
  import Interaction from '@event-calendar/interaction';
  import '@event-calendar/core/index.css';

  const TOKEN_KEY = 'ukko_auth_token';
  const THEME_KEY = 'ukko_theme';
  const NOTIF_SETTINGS_KEY = 'ukko_notification_settings';
  const NOTIFIED_EVENTS_KEY = 'ukko_notified_events';
  const EVENTS_CACHE_KEY = 'ukko_events_cache_v1';
  const CONTACTS_CACHE_KEY = 'ukko_contacts_cache_v1';
  const HORIZON_DAYS = 90;

  const REMINDER_OPTIONS = [
    { label: 'At time of event', minutes: 0 },
    { label: '5 minutes before', minutes: 5 },
    { label: '10 minutes before', minutes: 10 },
    { label: '15 minutes before', minutes: 15 },
    { label: '30 minutes before', minutes: 30 },
    { label: '1 hour before', minutes: 60 }
  ];

  const SUBSCRIPTION_COLORS = [
    { name: 'Purple', value: '#9333ea' },
    { name: 'Pink', value: '#db2777' },
    { name: 'Emerald', value: '#059669' },
    { name: 'Amber', value: '#d97706' },
    { name: 'Rose', value: '#e11d48' },
    { name: 'Cyan', value: '#0891b2' }
  ];

  // Theme state
  let darkMode = false;

  // Auth state
  let token = typeof localStorage !== 'undefined' ? localStorage.getItem(TOKEN_KEY) || '' : '';
  let authenticated = Boolean(token);
  let passcode = '';
  let authLoading = false;
  let authError = '';

  // Calendar state
  let calendarEl;
  let calendar = null;
  let events = [];
  let loadingEvents = false;
  let bannerError = '';
  let bannerSuccess = '';
  let currentRange = { start: null, end: null };
  let loadedHorizon = { startMs: 0, endMs: 0 };
  let initialSyncDone = false;
  let eventsFetchSeq = 0;
  let eventsAbortController = null;

  // .ics file import state
  let icsFileInput;
  let importingIcs = false;

  // Subscribed calendars state
  let subscriptions = [];
  let showSubscriptionsModal = false;
  let subSaving = false;
  let subError = '';
  let subForm = {
    name: '',
    url: '',
    color: '#9333ea'
  };

  // Published .ics feed state (shareable URL for primary calendar)
  let feedToken = '';
  let feedCopied = false;
  let rotatingToken = false;

  $: publishedFeedUrl =
    feedToken && typeof window !== 'undefined'
      ? `${window.location.origin}/api/feed/${feedToken}/ukko.ics`
      : '';

  // App version state
  let appVersion = '0.1.9';

  // Animating ASCII art state for THUNDERCAL
  const ASCII_THUNDER_BASE = [
    '▀▀█▀▀ █   █ █   █ █▄  █ ████▄ █████ ████▄ ',
    '  █   █████ █   █ █ ▀▄█ █   █ ████  ████▀ ',
    '  ▀   ▀   ▀ ▀▀▀▀▀ ▀   ▀ ▀▀▀▀  ▀▀▀▀▀ ▀  ▀▀ '
  ];
  const ASCII_CAL_BASE = [
    '▄████ ▄███▄ █    ',
    '█     █████ █    ',
    '▀████ ▀   ▀ ▀▀▀▀▀'
  ];
  const ASCII_THUNDER_STR = ASCII_THUNDER_BASE.join('\n');
  const ASCII_CAL_STR = ASCII_CAL_BASE.join('\n');
  const ASCII_SPARK_CHARS = ['/', '\\', '*', '#', '+', '~'];
  const ASCII_TOTAL_COLS = ASCII_THUNDER_BASE[0].length + ASCII_CAL_BASE[0].length;
  const ASCII_PAUSE_TICKS = 35;

  let asciiTick = 0;
  let asciiTimerId = null;
  let asciiThunderText = ASCII_THUNDER_STR;
  let asciiCalText = ASCII_CAL_STR;

  function transformAsciiLines(baseLines, colOffset, waveCol, tickNum) {
    return baseLines
      .map((line, rowIdx) => {
        let out = '';
        for (let i = 0; i < line.length; i++) {
          const ch = line[i];
          if (ch === ' ') {
            out += ' ';
            continue;
          }
          const globalCol = colOffset + i;
          const dist = waveCol - globalCol;
          if (dist === 0) {
            out += ASCII_SPARK_CHARS[(globalCol + rowIdx + tickNum) % ASCII_SPARK_CHARS.length];
          } else if (dist === 1 || dist === -1) {
            out += '▓';
          } else if (dist === 2) {
            out += '▒';
          } else if (dist === 3) {
            out += '░';
          } else {
            out += ch;
          }
        }
        return out;
      })
      .join('\n');
  }

  function scheduleAsciiTick(delayMs) {
    if (asciiTimerId) {
      clearTimeout(asciiTimerId);
    }
    if (typeof document !== 'undefined' && document.hidden) {
      asciiTimerId = null;
      return;
    }
    asciiTimerId = setTimeout(runAsciiFrame, delayMs);
  }

  function runAsciiFrame() {
    asciiTimerId = null;
    if (typeof document !== 'undefined' && document.hidden) return;

    const cycleLen = ASCII_TOTAL_COLS + ASCII_PAUSE_TICKS;
    const phase = asciiTick % cycleLen;

    if (phase <= ASCII_TOTAL_COLS + 4) {
      const waveCol = phase - 2;
      asciiThunderText = transformAsciiLines(ASCII_THUNDER_BASE, 0, waveCol, asciiTick);
      asciiCalText = transformAsciiLines(
        ASCII_CAL_BASE,
        ASCII_THUNDER_BASE[0].length,
        waveCol,
        asciiTick
      );
      asciiTick += 1;
      scheduleAsciiTick(55);
    } else {
      asciiThunderText = ASCII_THUNDER_STR;
      asciiCalText = ASCII_CAL_STR;
      const remainingPauseTicks = cycleLen - phase;
      asciiTick += remainingPauseTicks;
      scheduleAsciiTick(remainingPauseTicks * 55);
    }
  }

  function triggerAsciiSurge() {
    asciiTick = 0;
    runAsciiFrame();
  }

  function startAsciiAnimation() {
    stopAsciiAnimation();
    runAsciiFrame();
  }

  function stopAsciiAnimation() {
    if (asciiTimerId) {
      clearTimeout(asciiTimerId);
      asciiTimerId = null;
    }
  }

  function handleVisibilityChange() {
    if (typeof document === 'undefined') return;
    if (document.hidden) {
      stopAsciiAnimation();
    } else if (!asciiTimerId) {
      scheduleAsciiTick(120);
    }
  }

  // CardDAV contacts & attendee autocomplete state
  let contacts = [];
  let attendeeQuery = '';
  let attendeeDropdownOpen = false;
  let attendeeHighlightIndex = 0;

  // MapQuest location autocomplete state
  let locationSuggestions = [];
  let locationDropdownOpen = false;
  let locationHighlightIndex = 0;
  let locationLoading = false;
  let locationDebounceTimer = null;
  let locationAbortController = null;
  const locationCache = new Map();

  // Create / Edit Event modal state
  const RRULE_PRESETS = [
    { value: '', label: 'Does not repeat' },
    { value: 'FREQ=DAILY', label: 'Daily' },
    { value: 'FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR', label: 'Every weekday (Mon–Fri)' },
    { value: 'FREQ=WEEKLY', label: 'Weekly' },
    { value: 'FREQ=WEEKLY;INTERVAL=2', label: 'Every 2 weeks' },
    { value: 'FREQ=MONTHLY', label: 'Monthly' },
    { value: 'FREQ=YEARLY', label: 'Yearly' }
  ];

  let showEventModal = false;
  let editingUid = null;
  let editingIsRecurring = false;
  let editingRecurrenceId = '';
  let editingOriginalRrule = '';
  let repeatEndType = 'never'; // 'never' | 'until' | 'count'
  let repeatUntilDate = '';
  let repeatCount = 10;
  let savingEvent = false;
  let formError = '';
  let eventForm = {
    title: '',
    start: '',
    end: '',
    all_day: false,
    rrule: '',
    location: '',
    location_url: '',
    description: '',
    create_zoom: false,
    attendees: []
  };

  // Recurring event edit / delete scope confirmation popup state
  let showRecurringScopeModal = false;
  let recurringEditScope = 'single'; // 'single' | 'following'
  let pendingRecurringChange = null;
  let applyingRecurringChange = false;
  let recurringScopeError = '';

  let showRecurringDeleteModal = false;
  let recurringDeleteScope = 'single'; // 'single' | 'following' | 'all'
  let deletingRecurringScope = false;
  let recurringDeleteError = '';

  $: allKnownContacts = (() => {
    const map = new Map();
    for (const c of contacts) {
      if (c?.email) {
        map.set(c.email.toLowerCase(), {
          name: c.name || '',
          email: c.email
        });
      }
    }
    for (const ev of events) {
      const org = ev?.extendedProps?.organizer;
      if (org?.email) {
        const key = org.email.toLowerCase();
        if (!map.has(key) || (!map.get(key).name && org.name)) {
          map.set(key, { name: org.name || '', email: org.email });
        }
      }
      const atts = ev?.extendedProps?.attendees || [];
      for (const a of atts) {
        if (a?.email) {
          const key = a.email.toLowerCase();
          if (!map.has(key) || (!map.get(key).name && a.name)) {
            map.set(key, { name: a.name || '', email: a.email });
          }
        }
      }
    }
    return Array.from(map.values()).sort((a, b) =>
      (a.name || a.email).localeCompare(b.name || b.email)
    );
  })();

  $: filteredContactSuggestions = (() => {
    const q = attendeeQuery.trim().toLowerCase();
    const selectedEmails = new Set(
      (eventForm.attendees || []).map((a) => (a.email || '').toLowerCase())
    );
    const available = allKnownContacts.filter(
      (c) => !selectedEmails.has(c.email.toLowerCase())
    );
    if (!q) {
      return available.slice(0, 6);
    }
    return available
      .filter(
        (c) =>
          (c.name && c.name.toLowerCase().includes(q)) ||
          c.email.toLowerCase().includes(q)
      )
      .slice(0, 6);
  })();
  // Event Details / Delete modal state
  let selectedEvent = null;
  let deletingEvent = false;
  let deleteError = '';

  // Browser Desktop Notifications state
  let notificationsSupported = false;
  let notificationPermission = 'default';
  let showNotificationsModal = false;
  let notifStatusMsg = '';
  let notificationSettings = {
    enabled: false,
    leadMinutes: 10,
    notifyAtStart: true,
    includeSubscribed: true
  };
  let reminderIntervalId = null;
  let backgroundSyncIntervalId = null;

  const localHourFormatter = new Intl.DateTimeFormat('en-US', {
    hour: 'numeric'
  });
  const localHourMinFormatter = new Intl.DateTimeFormat('en-US', {
    hour: 'numeric',
    minute: '2-digit'
  });
  const estHourFormatter = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York',
    hour: 'numeric'
  });
  const estHourMinFormatter = new Intl.DateTimeFormat('en-US', {
    timeZone: 'America/New_York',
    hour: 'numeric',
    minute: '2-digit'
  });

  function getTzAbbreviation(timeZone) {
    try {
      const opts = timeZone ? { timeZone, timeZoneName: 'short' } : { timeZoneName: 'short' };
      const parts = new Intl.DateTimeFormat('en-US', opts).formatToParts(new Date());
      return parts.find((p) => p.type === 'timeZoneName')?.value || (timeZone ? 'EST' : 'PST');
    } catch {
      return timeZone ? 'EST' : 'PST';
    }
  }

  const localTzLabel = getTzAbbreviation();
  const estTzLabel = 'EST';

  // EST on the left, PST (current timezone) first on the right next to the grid
  function formatDualSlotLabel(date) {
    const hasMinutes = date.getMinutes() !== 0;
    const localLabel = hasMinutes
      ? localHourMinFormatter.format(date)
      : localHourFormatter.format(date);
    const estLabel = hasMinutes
      ? estHourMinFormatter.format(date)
      : estHourFormatter.format(date);

    return {
      html: `<span class="tz-dual-slot"><span class="tz-col tz-est">${estLabel}</span><span class="tz-col tz-local">${localLabel}</span></span>`
    };
  }

  function createDualSidebarHeader() {
    return {
      html: `<span class="tz-header-only tz-dual-slot tz-dual-header"><span class="tz-col tz-est">${estTzLabel}</span><span class="tz-col tz-local">${localTzLabel}</span></span><span class="tz-allday-only">all-day</span>`
    };
  }

  function initTheme() {
    if (typeof window === 'undefined') return;
    const saved = localStorage.getItem(THEME_KEY);
    if (saved === 'dark' || saved === 'light') {
      darkMode = saved === 'dark';
    } else if (window.matchMedia) {
      darkMode = window.matchMedia('(prefers-color-scheme: dark)').matches;
    }
    applyTheme();
  }

  function applyTheme() {
    if (typeof document !== 'undefined') {
      document.documentElement.classList.toggle('dark', darkMode);
    }
  }

  function toggleTheme() {
    darkMode = !darkMode;
    if (typeof localStorage !== 'undefined') {
      localStorage.setItem(THEME_KEY, darkMode ? 'dark' : 'light');
    }
    applyTheme();
  }

  function formatApiError(data, fallback, status) {
    if (data && typeof data === 'object' && !Array.isArray(data)) {
      if (data.error && data.details) {
        return `${data.error}: ${data.details}`;
      }
      if (data.error) {
        return data.error;
      }
      if (data.errors?.detail) {
        return `${fallback} (${data.errors.detail})`;
      }
    }
    return status ? `${fallback} (HTTP ${status})` : fallback;
  }

  function authHeaders(extra = {}) {
    const headers = { ...extra };
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
    }
    return headers;
  }

  function toLocalInputValue(date) {
    if (!date) return '';
    if (typeof date === 'string' && date.length === 10) {
      return `${date}T09:00`;
    }
    const d = date instanceof Date ? date : new Date(date);
    if (Number.isNaN(d.getTime())) return '';
    const pad = (n) => String(n).padStart(2, '0');
    const yyyy = d.getFullYear();
    const mm = pad(d.getMonth() + 1);
    const dd = pad(d.getDate());
    const hh = pad(d.getHours());
    const min = pad(d.getMinutes());
    return `${yyyy}-${mm}-${dd}T${hh}:${min}`;
  }

  function localInputToIso(value, isAllDay = false) {
    if (!value) return null;
    if (isAllDay) {
      return String(value).slice(0, 10);
    }
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return value;
    return d.toISOString();
  }

  function isEventAllDay(ev) {
    if (ev.allDay === true) return true;
    const s = typeof ev.start === 'string' ? ev.start.trim() : '';
    return s.length === 10;
  }

  function parseTimedDate(val) {
    if (val instanceof Date) return val;
    if (typeof val === 'string' && val.endsWith('Z')) {
      const d = new Date(val);
      if (!Number.isNaN(d.getTime())) return d;
    }
    return val;
  }

  function formatDateTime(value, allDay = false) {
    if (!value) return '';
    if (allDay) {
      const dateStr =
        value instanceof Date ? value.toISOString().slice(0, 10) : String(value).slice(0, 10);
      const [y, m, d] = dateStr.split('-').map(Number);
      if (y && m && d) {
        return (
          new Date(y, m - 1, d).toLocaleDateString('en-US', {
            weekday: 'short',
            month: 'short',
            day: 'numeric',
            year: 'numeric'
          }) + ' (All day)'
        );
      }
      return `${dateStr} (All day)`;
    }
    const d = value instanceof Date ? value : new Date(value);
    if (Number.isNaN(d.getTime())) return String(value);
    const localStr = d.toLocaleString('en-US', {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      year: 'numeric',
      hour: 'numeric',
      minute: '2-digit',
      timeZoneName: 'short'
    });
    const estStr = d.toLocaleTimeString('en-US', {
      timeZone: 'America/New_York',
      hour: 'numeric',
      minute: '2-digit'
    });
    return `${localStr} (${estStr} EST)`;
  }

  function isUrl(str) {
    if (!str || typeof str !== 'string') return false;
    return /^https?:\/\/\S+/i.test(str.trim());
  }

  async function handleLogin(e) {
    e.preventDefault();
    authError = '';
    authLoading = true;

    try {
      const res = await fetch('/api/auth', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ passcode })
      });

      const data = await res.json().catch(() => ({}));

      if (!res.ok) {
        authError = formatApiError(data, 'Invalid passcode', res.status);
        return;
      }

      token = data.token || '';
      if (token) {
        localStorage.setItem(TOKEN_KEY, token);
      }
      authenticated = true;
      passcode = '';
      hydrateCachedEvents();
      hydrateCachedContacts();
      await tick();
      initCalendar();
      fetchSubscriptions();
      fetchContacts();
      startNotificationTimers();
    } catch (err) {
      authError = 'Could not reach server. Please try again.';
    } finally {
      authLoading = false;
    }
  }

  function handleLogout() {
    if (eventsAbortController) {
      eventsAbortController.abort();
      eventsAbortController = null;
    }
    token = '';
    authenticated = false;
    events = [];
    contacts = [];
    loadedHorizon = { startMs: 0, endMs: 0 };
    initialSyncDone = false;
    if (typeof localStorage !== 'undefined') {
      localStorage.removeItem(TOKEN_KEY);
      localStorage.removeItem(EVENTS_CACHE_KEY);
      localStorage.removeItem(CONTACTS_CACHE_KEY);
    }
    stopNotificationTimers();
    destroyCalendar();
  }

  function mapApiEvents(data) {
    if (!Array.isArray(data)) return [];
    return data.map((ev) => {
      const allDay = isEventAllDay(ev);
      const rawStart = ev.start;
      const rawEnd = ev.end || ev.start;
      const bgColor = ev.backgroundColor || ev.color || ev.extendedProps?.color;
      const readOnly = Boolean(ev.readOnly || ev.extendedProps?.readOnly);
      const isRecurring = Boolean(ev.isRecurring || ev.extendedProps?.isRecurring);
      const rrule = ev.rrule ?? ev.extendedProps?.rrule ?? '';
      const recurrenceId = ev.recurrenceId ?? ev.extendedProps?.recurrenceId ?? '';
      const calendarName = ev.calendarName || ev.extendedProps?.calendarName || 'Thundercal';

      const mapped = {
        id: ev.id || ev.uid,
        title: ev.title || '(No Title)',
        allDay,
        editable: !readOnly,
        startEditable: !readOnly,
        durationEditable: !readOnly,
        start: allDay ? String(rawStart).slice(0, 10) : parseTimedDate(rawStart),
        end: allDay ? String(rawEnd).slice(0, 10) : parseTimedDate(rawEnd),
        extendedProps: {
          uid: ev.uid || ev.id,
          allDay,
          description: ev.description ?? ev.extendedProps?.description ?? '',
          location: ev.location ?? ev.extendedProps?.location ?? '',
          locationUrl: ev.locationUrl ?? ev.extendedProps?.locationUrl ?? '',
          organizer: ev.organizer ?? ev.extendedProps?.organizer ?? null,
          attendees: Array.isArray(ev.attendees)
            ? ev.attendees
            : Array.isArray(ev.extendedProps?.attendees)
              ? ev.extendedProps.attendees
              : [],
          isRecurring,
          rrule,
          recurrenceId,
          readOnly,
          calendarName,
          color: bgColor || '#2563eb'
        }
      };

      if (bgColor) {
        mapped.backgroundColor = bgColor;
        mapped.color = bgColor;
      }

      return mapped;
    });
  }

  function hydrateCachedEvents() {
    if (typeof localStorage === 'undefined') return;
    try {
      const raw = localStorage.getItem(EVENTS_CACHE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw);
      if (parsed && Array.isArray(parsed.items) && parsed.items.length > 0) {
        events = mapApiEvents(parsed.items);
      }
    } catch {
      // ignore invalid cache
    }
  }

  function persistCachedEvents(rawItems) {
    if (typeof localStorage === 'undefined' || !Array.isArray(rawItems)) return;
    try {
      localStorage.setItem(EVENTS_CACHE_KEY, JSON.stringify({ ts: Date.now(), items: rawItems }));
    } catch {
      // ignore storage quota errors
    }
  }

  function hydrateCachedContacts() {
    if (typeof localStorage === 'undefined') return;
    try {
      const raw = localStorage.getItem(CONTACTS_CACHE_KEY);
      if (!raw) return;
      const parsed = JSON.parse(raw);
      if (Array.isArray(parsed)) {
        contacts = parsed;
      }
    } catch {
      // ignore invalid cache
    }
  }

  async function fetchEvents(rangeStart, rangeEnd, opts = {}) {
    if (!authenticated) return;
    const { force = false, serverRefresh = false } = opts;

    const rawStart = rangeStart || currentRange.start;
    const rawEnd = rangeEnd || currentRange.end;
    const reqStartMs = rawStart ? new Date(rawStart).getTime() : NaN;
    const reqEndMs = rawEnd ? new Date(rawEnd).getTime() : NaN;

    // Instant client-side navigation when requested window is already inside our ±90-day horizon
    if (
      !force &&
      !serverRefresh &&
      initialSyncDone &&
      !Number.isNaN(reqStartMs) &&
      !Number.isNaN(reqEndMs) &&
      loadedHorizon.startMs > 0 &&
      loadedHorizon.endMs > 0 &&
      reqStartMs >= loadedHorizon.startMs &&
      reqEndMs <= loadedHorizon.endMs
    ) {
      return;
    }

    const dayMs = 24 * 60 * 60 * 1000;
    const horizonPaddingMs = HORIZON_DAYS * dayMs;
    const fetchStartMs = !Number.isNaN(reqStartMs)
      ? reqStartMs - horizonPaddingMs
      : loadedHorizon.startMs || Date.now() - horizonPaddingMs;
    const fetchEndMs = !Number.isNaN(reqEndMs)
      ? reqEndMs + horizonPaddingMs
      : loadedHorizon.endMs || Date.now() + horizonPaddingMs;

    if (eventsAbortController) {
      eventsAbortController.abort();
    }
    const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
    eventsAbortController = controller;
    const seq = ++eventsFetchSeq;

    loadingEvents = true;
    bannerError = '';

    const params = new URLSearchParams();
    params.set('start', new Date(fetchStartMs).toISOString());
    params.set('end', new Date(fetchEndMs).toISOString());
    if (serverRefresh) {
      params.set('refresh', '1');
    }

    try {
      const url = `/api/events?${params.toString()}`;
      const res = await fetch(url, {
        method: 'GET',
        credentials: 'same-origin',
        headers: authHeaders({ Accept: 'application/json' }),
        signal: controller ? controller.signal : undefined
      });

      if (seq !== eventsFetchSeq) return;

      if (res.status === 401) {
        handleLogout();
        authError = 'Session expired. Please enter your passcode.';
        return;
      }

      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        bannerError = formatApiError(data, 'Failed to load calendar events.', res.status);
        return;
      }

      const rawItems = Array.isArray(data) ? data : [];
      events = mapApiEvents(rawItems);
      loadedHorizon = { startMs: fetchStartMs, endMs: fetchEndMs };
      initialSyncDone = true;
      persistCachedEvents(rawItems);

      if (calendar) {
        calendar.setOption('events', events);
      }
      checkUpcomingNotifications();
    } catch (err) {
      if (err?.name === 'AbortError') return;
      if (seq === eventsFetchSeq) {
        bannerError = 'Network error while fetching calendar events.';
      }
    } finally {
      if (seq === eventsFetchSeq) {
        loadingEvents = false;
        eventsAbortController = null;
      }
    }
  }

  // --- .ics Import ---

  function triggerIcsImport() {
    if (icsFileInput) {
      icsFileInput.value = '';
      icsFileInput.click();
    }
  }

  async function handleIcsFileSelected(e) {
    const files = Array.from(e.target.files || []);
    if (!files.length) return;

    importingIcs = true;
    bannerError = '';
    bannerSuccess = '';

    try {
      const icsList = await Promise.all(files.map((file) => file.text()));
      const res = await fetch('/api/events/import', {
        method: 'POST',
        credentials: 'same-origin',
        headers: authHeaders({
          'Content-Type': 'application/json',
          Accept: 'application/json'
        }),
        body: JSON.stringify({ ics_list: icsList })
      });

      if (res.status === 401) {
        handleLogout();
        authError = 'Session expired. Please enter your passcode.';
        return;
      }

      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        bannerError = formatApiError(data, 'Failed to import .ics file.', res.status);
        return;
      }

      const count = data.imported || 1;
      bannerSuccess = `Successfully imported ${count} event${count === 1 ? '' : 's'} from .ics file.`;
      await fetchEvents(null, null, { force: true });
    } catch (err) {
      bannerError = 'Failed to read or upload .ics file.';
    } finally {
      importingIcs = false;
    }
  }

  // --- Subscribed Calendars (Google Calendar / iCal) ---

  async function fetchSubscriptions() {
    if (!authenticated) return;
    try {
      const res = await fetch('/api/subscriptions', {
        method: 'GET',
        credentials: 'same-origin',
        headers: authHeaders({ Accept: 'application/json' })
      });
      if (res.ok) {
        const data = await res.json().catch(() => []);
        if (Array.isArray(data)) {
          subscriptions = data;
        }
      }
    } catch {
      // ignore background error
    }
  }

  async function fetchFeedToken() {
    if (!authenticated) return;
    try {
      const res = await fetch('/api/feed-token', {
        method: 'GET',
        credentials: 'same-origin',
        headers: authHeaders({ Accept: 'application/json' })
      });
      if (res.ok) {
        const data = await res.json().catch(() => ({}));
        if (data.token) {
          feedToken = data.token;
        }
      }
    } catch {
      // ignore
    }
  }

  async function handleCopyFeedUrl() {
    if (!publishedFeedUrl) return;
    try {
      await navigator.clipboard.writeText(publishedFeedUrl);
      feedCopied = true;
      setTimeout(() => {
        feedCopied = false;
      }, 2000);
    } catch {
      // fallback if clipboard API unavailable
    }
  }

  async function handleRotateFeedToken() {
    if (rotatingToken) return;
    rotatingToken = true;
    try {
      const res = await fetch('/api/feed-token/rotate', {
        method: 'POST',
        credentials: 'same-origin',
        headers: authHeaders({ Accept: 'application/json' })
      });
      if (res.ok) {
        const data = await res.json().catch(() => ({}));
        if (data.token) {
          feedToken = data.token;
          feedCopied = false;
        }
      }
    } catch {
      // ignore
    } finally {
      rotatingToken = false;
    }
  }

  function openSubscriptionsModal() {
    subError = '';
    feedCopied = false;
    subForm = {
      name: '',
      url: '',
      color: SUBSCRIPTION_COLORS[subscriptions.length % SUBSCRIPTION_COLORS.length].value
    };
    showSubscriptionsModal = true;
    fetchSubscriptions();
    fetchFeedToken();
  }

  function closeSubscriptionsModal() {
    if (subSaving) return;
    showSubscriptionsModal = false;
    subError = '';
  }

  async function handleAddSubscription(e) {
    e.preventDefault();
    subError = '';

    if (!subForm.url.trim()) {
      subError = 'Please enter a Google Calendar or iCal (.ics) URL.';
      return;
    }

    subSaving = true;

    try {
      const res = await fetch('/api/subscriptions', {
        method: 'POST',
        credentials: 'same-origin',
        headers: authHeaders({
          'Content-Type': 'application/json',
          Accept: 'application/json'
        }),
        body: JSON.stringify({
          name: subForm.name.trim(),
          url: subForm.url.trim(),
          color: subForm.color
        })
      });

      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        subError = formatApiError(data, 'Failed to subscribe to calendar.', res.status);
        return;
      }

      await fetchSubscriptions();
      await fetchEvents(null, null, { force: true });
      subForm = {
        name: '',
        url: '',
        color: SUBSCRIPTION_COLORS[subscriptions.length % SUBSCRIPTION_COLORS.length].value
      };
    } catch (err) {
      subError = 'Network error while adding calendar subscription.';
    } finally {
      subSaving = false;
    }
  }

  async function handleToggleSubscription(sub) {
    try {
      const res = await fetch(`/api/subscriptions/${encodeURIComponent(sub.id)}`, {
        method: 'PUT',
        credentials: 'same-origin',
        headers: authHeaders({
          'Content-Type': 'application/json',
          Accept: 'application/json'
        }),
        body: JSON.stringify({ enabled: !sub.enabled })
      });
      if (res.ok) {
        await fetchSubscriptions();
        await fetchEvents(null, null, { force: true });
      }
    } catch {
      // ignore
    }
  }

  async function handleChangeSubColor(sub, newColor) {
    try {
      const res = await fetch(`/api/subscriptions/${encodeURIComponent(sub.id)}`, {
        method: 'PUT',
        credentials: 'same-origin',
        headers: authHeaders({
          'Content-Type': 'application/json',
          Accept: 'application/json'
        }),
        body: JSON.stringify({ color: newColor })
      });
      if (res.ok) {
        await fetchSubscriptions();
        await fetchEvents(null, null, { force: true });
      }
    } catch {
      // ignore
    }
  }

  async function handleDeleteSubscription(subId) {
    try {
      const res = await fetch(`/api/subscriptions/${encodeURIComponent(subId)}`, {
        method: 'DELETE',
        credentials: 'same-origin',
        headers: authHeaders({ Accept: 'application/json' })
      });
      if (res.ok) {
        await fetchSubscriptions();
        await fetchEvents(null, null, { force: true });
      }
    } catch {
      // ignore
    }
  }

  async function fetchAppVersion() {
    try {
      const res = await fetch('/api/health', { method: 'GET' });
      if (res.ok) {
        const data = await res.json().catch(() => ({}));
        if (data.version) {
          appVersion = data.version;
        }
      }
    } catch {
      // keep default version
    }
  }

  async function fetchContacts() {
    if (!authenticated) return;
    try {
      const res = await fetch('/api/contacts', {
        method: 'GET',
        credentials: 'same-origin',
        headers: authHeaders({ Accept: 'application/json' })
      });
      if (res.ok) {
        const data = await res.json().catch(() => []);
        if (Array.isArray(data)) {
          contacts = data;
          if (typeof localStorage !== 'undefined') {
            try {
              localStorage.setItem(CONTACTS_CACHE_KEY, JSON.stringify(data));
            } catch {
              // ignore storage quota errors
            }
          }
        }
      }
    } catch {
      // ignore background error
    }
  }

  function parseTypedAttendee(inputStr) {
    const trimmed = (inputStr || '').trim();
    if (!trimmed) return null;

    const angleMatch = trimmed.match(/^(.*)<([^>]+)>$/);
    if (angleMatch) {
      const name = angleMatch[1].trim().replace(/^["']|["']$/g, '');
      const email = angleMatch[2].trim();
      if (email.includes('@')) {
        return { name, email, status: 'NEEDS-ACTION' };
      }
    }

    if (trimmed.includes('@') && !trimmed.includes(' ')) {
      const known = allKnownContacts.find(
        (c) => c.email.toLowerCase() === trimmed.toLowerCase()
      );
      return {
        name: known?.name || '',
        email: trimmed,
        status: 'NEEDS-ACTION'
      };
    }

    return null;
  }

  function addAttendee(contactOrTyped) {
    if (!contactOrTyped || !contactOrTyped.email) return false;
    const emailLower = contactOrTyped.email.trim().toLowerCase();
    if (!emailLower.includes('@')) return false;

    const current = eventForm.attendees || [];
    if (current.some((a) => (a.email || '').toLowerCase() === emailLower)) {
      attendeeQuery = '';
      attendeeDropdownOpen = false;
      return true;
    }

    eventForm = {
      ...eventForm,
      attendees: [
        ...current,
        {
          name: contactOrTyped.name || '',
          email: contactOrTyped.email.trim(),
          status: contactOrTyped.status || 'NEEDS-ACTION'
        }
      ]
    };
    attendeeQuery = '';
    attendeeHighlightIndex = 0;
    attendeeDropdownOpen = false;
    return true;
  }

  function handleAddTypedAttendee() {
    if (!attendeeQuery.trim()) return;
    const parts = attendeeQuery
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);

    let addedAny = false;
    for (const part of parts) {
      const parsed = parseTypedAttendee(part);
      if (parsed) {
        addAttendee(parsed);
        addedAny = true;
      } else if (filteredContactSuggestions.length > 0) {
        const pick =
          filteredContactSuggestions[attendeeHighlightIndex] ||
          filteredContactSuggestions[0];
        if (pick) {
          addAttendee(pick);
          addedAny = true;
        }
      }
    }

    if (!addedAny && attendeeQuery.trim()) {
      formError = 'Please enter a valid email address (e.g. name@example.com) or select a contact.';
    } else {
      formError = '';
    }
  }

  function handleAttendeeKeydown(e) {
    if (e.key === 'ArrowDown') {
      if (filteredContactSuggestions.length > 0) {
        e.preventDefault();
        attendeeDropdownOpen = true;
        attendeeHighlightIndex =
          (attendeeHighlightIndex + 1) % filteredContactSuggestions.length;
      }
    } else if (e.key === 'ArrowUp') {
      if (filteredContactSuggestions.length > 0) {
        e.preventDefault();
        attendeeDropdownOpen = true;
        attendeeHighlightIndex =
          (attendeeHighlightIndex - 1 + filteredContactSuggestions.length) %
          filteredContactSuggestions.length;
      }
    } else if (e.key === 'Enter' || e.key === ',') {
      if (attendeeQuery.trim()) {
        e.preventDefault();
        if (
          attendeeDropdownOpen &&
          filteredContactSuggestions.length > 0 &&
          !attendeeQuery.includes('@')
        ) {
          const pick =
            filteredContactSuggestions[attendeeHighlightIndex] ||
            filteredContactSuggestions[0];
          addAttendee(pick);
        } else {
          handleAddTypedAttendee();
        }
      }
    } else if (e.key === 'Escape') {
      attendeeDropdownOpen = false;
    } else if (
      e.key === 'Backspace' &&
      !attendeeQuery &&
      eventForm.attendees?.length > 0
    ) {
      removeAttendee(eventForm.attendees[eventForm.attendees.length - 1].email);
    }
  }

  function removeAttendee(email) {
    eventForm = {
      ...eventForm,
      attendees: (eventForm.attendees || []).filter(
        (a) => (a.email || '').toLowerCase() !== (email || '').toLowerCase()
      )
    };
  }

  function formatAttendeeStatus(status) {
    const s = (status || 'NEEDS-ACTION').toUpperCase();
    if (s === 'ACCEPTED') return 'Accepted';
    if (s === 'DECLINED') return 'Declined';
    if (s === 'TENTATIVE') return 'Tentative';
    return 'Pending';
  }

  function sanitizeMapQuestUrl(rawUrl) {
    if (!rawUrl || typeof rawUrl !== 'string') return '';
    return rawUrl
      .trim()
      .replace(/\\,/g, ',')
      .replace(/\\;/g, ';')
      .replace(/\\/g, '')
      .replace(/(\d)\/,(-?\d)/g, '$1,$2');
  }

  function buildMapQuestUrl(locationText, explicitUrl = '') {
    const cleanedExplicit = sanitizeMapQuestUrl(explicitUrl);
    if (cleanedExplicit && /^https:\/\/www\.mapquest\.com\//i.test(cleanedExplicit)) {
      return cleanedExplicit;
    }
    const trimmed = (locationText || '').trim();
    if (!trimmed) return '';
    return `https://www.mapquest.com/search/results?query=${encodeURIComponent(trimmed)}`;
  }

  async function fetchLocationSuggestions(query) {
    const q = (query || '').trim();
    if (q.length < 2 || isUrl(q)) {
      if (locationAbortController) {
        locationAbortController.abort();
        locationAbortController = null;
      }
      locationSuggestions = [];
      locationLoading = false;
      return;
    }

    const cacheKey = q.toLowerCase();
    if (locationCache.has(cacheKey)) {
      locationSuggestions = locationCache.get(cacheKey);
      locationHighlightIndex = 0;
      locationLoading = false;
      return;
    }

    if (locationAbortController) {
      locationAbortController.abort();
    }
    const controller = typeof AbortController !== 'undefined' ? new AbortController() : null;
    locationAbortController = controller;

    locationLoading = true;
    try {
      const res = await fetch(`/api/locations/autocomplete?q=${encodeURIComponent(q)}`, {
        method: 'GET',
        credentials: 'same-origin',
        headers: authHeaders({ Accept: 'application/json' }),
        signal: controller ? controller.signal : undefined
      });
      if (res.ok) {
        const data = await res.json().catch(() => []);
        if (Array.isArray(data)) {
          if (locationCache.size > 100) {
            const firstKey = locationCache.keys().next().value;
            locationCache.delete(firstKey);
          }
          locationCache.set(cacheKey, data);
          if (eventForm.location.trim() === q) {
            locationSuggestions = data;
            locationHighlightIndex = 0;
          }
        }
      }
    } catch (err) {
      if (err?.name === 'AbortError') return;
    } finally {
      if (locationAbortController === controller) {
        locationLoading = false;
        locationAbortController = null;
      }
    }
  }

  function handleLocationInput(e) {
    const val = e.target.value;
    eventForm = {
      ...eventForm,
      location: val,
      location_url: ''
    };
    locationDropdownOpen = true;
    locationHighlightIndex = 0;

    if (locationDebounceTimer) {
      clearTimeout(locationDebounceTimer);
    }

    if (!val || val.trim().length < 2 || isUrl(val)) {
      locationSuggestions = [];
      locationLoading = false;
      return;
    }

    locationDebounceTimer = setTimeout(() => {
      fetchLocationSuggestions(val);
    }, 220);
  }

  function selectLocationSuggestion(suggestion) {
    if (!suggestion) return;
    if (locationDebounceTimer) {
      clearTimeout(locationDebounceTimer);
    }
    eventForm = {
      ...eventForm,
      location: suggestion.display || suggestion.name || '',
      location_url: suggestion.url || ''
    };
    locationSuggestions = [];
    locationDropdownOpen = false;
    locationHighlightIndex = 0;
  }

  function handleLocationKeydown(e) {
    if (!locationDropdownOpen || locationSuggestions.length === 0) return;

    if (e.key === 'ArrowDown') {
      e.preventDefault();
      locationHighlightIndex = (locationHighlightIndex + 1) % locationSuggestions.length;
    } else if (e.key === 'ArrowUp') {
      e.preventDefault();
      locationHighlightIndex =
        (locationHighlightIndex - 1 + locationSuggestions.length) % locationSuggestions.length;
    } else if (e.key === 'Enter') {
      const pick = locationSuggestions[locationHighlightIndex];
      if (pick) {
        e.preventDefault();
        selectLocationSuggestion(pick);
      }
    } else if (e.key === 'Escape') {
      locationDropdownOpen = false;
    }
  }

  // --- Create / Edit / Delete Events ---

  function getBrowserTimeZone() {
    try {
      return Intl.DateTimeFormat().resolvedOptions().timeZone || 'America/Los_Angeles';
    } catch {
      return 'America/Los_Angeles';
    }
  }

  function defaultRepeatUntilDate(startInputVal) {
    const base = startInputVal ? new Date(startInputVal) : new Date();
    const d = Number.isNaN(base.getTime()) ? new Date() : new Date(base.getTime());
    d.setMonth(d.getMonth() + 3);
    return toLocalInputValue(d).slice(0, 10);
  }

  function splitRruleForForm(rawRrule) {
    const trimmed = (rawRrule || '').trim().replace(/^RRULE:/i, '').trim();
    if (!trimmed) {
      return { baseRrule: '', endType: 'never', untilDate: '', count: 10 };
    }

    const baseParts = [];
    let endType = 'never';
    let untilDate = '';
    let count = 10;

    for (const part of trimmed.split(';')) {
      const [rawK, rawV] = part.split('=');
      if (!rawK || rawV === undefined) continue;
      const k = rawK.trim().toUpperCase();
      const v = rawV.trim();

      if (k === 'UNTIL') {
        const digits = v.slice(0, 8);
        if (/^\d{8}$/.test(digits)) {
          endType = 'until';
          untilDate = `${digits.slice(0, 4)}-${digits.slice(4, 6)}-${digits.slice(6, 8)}`;
        }
      } else if (k === 'COUNT') {
        const parsedCount = parseInt(v, 10);
        if (parsedCount > 0) {
          endType = 'count';
          count = parsedCount;
        }
      } else {
        baseParts.push(`${k}=${v}`);
      }
    }

    return {
      baseRrule: baseParts.join(';'),
      endType,
      untilDate,
      count
    };
  }

  function composeRruleFromForm(baseRrule, endType, untilDate, countVal, isAllDay) {
    const cleanBase = (baseRrule || '')
      .trim()
      .split(';')
      .filter((p) => {
        const k = (p.split('=')[0] || '').trim().toUpperCase();
        return k && k !== 'UNTIL' && k !== 'COUNT';
      })
      .join(';');

    if (!cleanBase) return '';

    if (endType === 'until' && /^\d{4}-\d{2}-\d{2}$/.test((untilDate || '').trim())) {
      const dStr = untilDate.trim();
      if (isAllDay) {
        return `${cleanBase};UNTIL=${dStr.replace(/-/g, '')}`;
      }
      const [y, m, d] = dStr.split('-').map(Number);
      const localEnd = new Date(y, m - 1, d, 23, 59, 59);
      const utcUntil = localEnd
        .toISOString()
        .replace(/[-:]/g, '')
        .replace(/\.\d{3}Z$/, 'Z');
      return `${cleanBase};UNTIL=${utcUntil}`;
    }

    if (endType === 'count') {
      const n = Math.max(1, Math.floor(Number(countVal) || 1));
      return `${cleanBase};COUNT=${n}`;
    }

    return cleanBase;
  }

  function formatRruleSummary(rruleStr) {
    if (!rruleStr || typeof rruleStr !== 'string') return 'Recurring';
    const trimmed = rruleStr.trim();

    const map = {};
    const baseParts = [];
    for (const part of trimmed.split(';')) {
      const [k, v] = part.split('=');
      if (k && v) {
        const upK = k.trim().toUpperCase();
        const cleanV = v.trim();
        map[upK] = cleanV;
        if (upK !== 'UNTIL' && upK !== 'COUNT') {
          baseParts.push(`${upK}=${cleanV}`);
        }
      }
    }

    const baseJoined = baseParts.join(';');
    const preset = RRULE_PRESETS.find((p) => p.value && p.value === baseJoined);

    const freq = (map.FREQ || '').toUpperCase();
    const interval = parseInt(map.INTERVAL || '1', 10) || 1;
    let label = preset ? preset.label : 'Recurring';

    if (!preset) {
      if (freq === 'DAILY') {
        label = interval > 1 ? `Every ${interval} days` : 'Daily';
      } else if (freq === 'WEEKLY') {
        label = interval > 1 ? `Every ${interval} weeks` : 'Weekly';
        if (map.BYDAY) label += ` (${map.BYDAY})`;
      } else if (freq === 'MONTHLY') {
        label = interval > 1 ? `Every ${interval} months` : 'Monthly';
      } else if (freq === 'YEARLY') {
        label = interval > 1 ? `Every ${interval} years` : 'Yearly';
      }
    }

    if (map.COUNT) {
      const n = parseInt(map.COUNT, 10);
      if (n > 0) label += ` • ${n} time${n === 1 ? '' : 's'}`;
    } else if (map.UNTIL && map.UNTIL.length >= 8) {
      const raw = map.UNTIL.slice(0, 8);
      if (/^\d{8}$/.test(raw)) {
        const y = Number(raw.slice(0, 4));
        const m = Number(raw.slice(4, 6)) - 1;
        const d = Number(raw.slice(6, 8));
        const formatted = new Date(y, m, d).toLocaleDateString('en-US', {
          month: 'short',
          day: 'numeric',
          year: 'numeric'
        });
        label += ` • until ${formatted}`;
      }
    }

    return label;
  }

  function isPresetRrule(rruleStr) {
    return RRULE_PRESETS.some((p) => p.value === (rruleStr || '').trim());
  }

  function handleRepeatEndTypeChange(e) {
    const next = e.target.value;
    repeatEndType = next;
    if (next === 'until' && !repeatUntilDate) {
      repeatUntilDate = defaultRepeatUntilDate(eventForm.start);
    }
  }

  function openCreateModal(startDate, endDate, allDay = false) {
    const now = new Date();
    now.setMinutes(0, 0, 0);
    now.setHours(now.getHours() + 1);

    const start = startDate ? new Date(startDate) : now;
    const end = endDate
      ? new Date(endDate)
      : new Date(start.getTime() + 60 * 60 * 1000);

    editingUid = null;
    editingIsRecurring = false;
    editingRecurrenceId = '';
    editingOriginalRrule = '';
    repeatEndType = 'never';
    repeatUntilDate = defaultRepeatUntilDate(toLocalInputValue(start));
    repeatCount = 10;
    attendeeQuery = '';
    attendeeDropdownOpen = false;
    attendeeHighlightIndex = 0;
    locationSuggestions = [];
    locationDropdownOpen = false;
    locationHighlightIndex = 0;
    eventForm = {
      title: '',
      start: toLocalInputValue(start),
      end: toLocalInputValue(end),
      all_day: Boolean(allDay),
      rrule: '',
      location: '',
      location_url: '',
      description: '',
      create_zoom: false,
      attendees: []
    };
    formError = '';
    showEventModal = true;
    if (contacts.length === 0) {
      fetchContacts();
    }
  }

  function openEditModal(ev) {
    if (!ev || ev.readOnly) return;
    editingUid = ev.uid;
    editingIsRecurring = Boolean(ev.isRecurring);
    editingRecurrenceId =
      ev.recurrenceId ||
      (ev.allDay
        ? toLocalInputValue(ev.start).slice(0, 10)
        : ev.start instanceof Date
          ? ev.start.toISOString()
          : String(ev.start || ''));
    editingOriginalRrule = (ev.rrule || '').trim();
    const parsedRepeat = splitRruleForForm(ev.rrule || '');
    repeatEndType = parsedRepeat.endType;
    repeatUntilDate =
      parsedRepeat.untilDate || defaultRepeatUntilDate(toLocalInputValue(ev.start));
    repeatCount = parsedRepeat.count;
    attendeeQuery = '';
    attendeeDropdownOpen = false;
    attendeeHighlightIndex = 0;
    locationSuggestions = [];
    locationDropdownOpen = false;
    locationHighlightIndex = 0;
    eventForm = {
      title: ev.title || '',
      start: toLocalInputValue(ev.start),
      end: toLocalInputValue(ev.end || ev.start),
      all_day: Boolean(ev.allDay),
      rrule: parsedRepeat.baseRrule,
      location: ev.location || '',
      location_url: sanitizeMapQuestUrl(ev.locationUrl || ''),
      description: ev.description || '',
      create_zoom: false,
      attendees: Array.isArray(ev.attendees) ? [...ev.attendees] : []
    };
    formError = '';
    selectedEvent = null;
    showEventModal = true;
    if (contacts.length === 0) {
      fetchContacts();
    }
  }

  function closeEventModal() {
    if (savingEvent || applyingRecurringChange) return;
    showEventModal = false;
    editingUid = null;
    editingIsRecurring = false;
    editingRecurrenceId = '';
    editingOriginalRrule = '';
    formError = '';
  }

  async function handleSaveEvent(e) {
    e.preventDefault();
    formError = '';

    if (!eventForm.title.trim() || !eventForm.start) {
      formError = 'Title and start time are required.';
      return;
    }

    const isAllDay = Boolean(eventForm.all_day);
    let startVal = localInputToIso(eventForm.start, isAllDay);
    let endVal = localInputToIso(eventForm.end || eventForm.start, isAllDay);

    if (isAllDay && startVal === endVal) {
      const [y, m, d] = startVal.split('-').map(Number);
      const nextDay = new Date(Date.UTC(y, m - 1, d + 1));
      endVal = nextDay.toISOString().slice(0, 10);
    }

    if (attendeeQuery.trim()) {
      const pending = parseTypedAttendee(attendeeQuery.trim());
      if (pending) {
        addAttendee(pending);
      }
    }

    const composedRrule = composeRruleFromForm(
      eventForm.rrule,
      repeatEndType,
      repeatUntilDate,
      repeatCount,
      isAllDay
    );

    const payload = {
      title: eventForm.title.trim(),
      start: startVal,
      end: endVal,
      timezone: getBrowserTimeZone(),
      rrule: composedRrule,
      location: eventForm.location.trim(),
      location_url: eventForm.location_url || '',
      description: eventForm.description.trim(),
      create_zoom: Boolean(eventForm.create_zoom),
      attendees: eventForm.attendees || []
    };

    const isEdit = Boolean(editingUid);

    // If modifying an existing recurring event, ask whether to adjust just this event or all following
    if (isEdit && editingIsRecurring) {
      const rruleChanged = composedRrule !== editingOriginalRrule;
      recurringEditScope = rruleChanged ? 'following' : 'single';
      recurringScopeError = '';
      pendingRecurringChange = {
        source: 'modal',
        uid: editingUid,
        recurrenceId: editingRecurrenceId || startVal,
        payload
      };
      showRecurringScopeModal = true;
      return;
    }

    savingEvent = true;

    try {
      const url = isEdit
        ? `/api/events/${encodeURIComponent(editingUid)}`
        : '/api/events';
      const method = isEdit ? 'PUT' : 'POST';

      const res = await fetch(url, {
        method,
        credentials: 'same-origin',
        headers: authHeaders({
          'Content-Type': 'application/json',
          Accept: 'application/json'
        }),
        body: JSON.stringify(payload)
      });

      if (res.status === 401) {
        showEventModal = false;
        editingUid = null;
        editingIsRecurring = false;
        editingRecurrenceId = '';
        editingOriginalRrule = '';
        handleLogout();
        authError = 'Session expired. Please enter your passcode.';
        return;
      }

      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        formError = formatApiError(
          data,
          isEdit ? 'Failed to update event.' : 'Failed to create event.',
          res.status
        );
        return;
      }

      showEventModal = false;
      editingUid = null;
      editingIsRecurring = false;
      editingRecurrenceId = '';
      editingOriginalRrule = '';
      await fetchEvents(null, null, { force: true });
    } catch (err) {
      formError = 'Network error while saving event.';
    } finally {
      savingEvent = false;
    }
  }

  async function confirmRecurringChange() {
    if (!pendingRecurringChange || applyingRecurringChange) return;
    applyingRecurringChange = true;
    recurringScopeError = '';

    const { source, uid, recurrenceId, payload, revert } = pendingRecurringChange;
    const scopedPayload = {
      ...payload,
      edit_scope: recurringEditScope,
      recurrence_id: recurrenceId
    };

    try {
      const res = await fetch(`/api/events/${encodeURIComponent(uid)}`, {
        method: 'PUT',
        credentials: 'same-origin',
        headers: authHeaders({
          'Content-Type': 'application/json',
          Accept: 'application/json'
        }),
        body: JSON.stringify(scopedPayload)
      });

      if (res.status === 401) {
        if (source === 'drop' && revert) revert();
        showRecurringScopeModal = false;
        pendingRecurringChange = null;
        showEventModal = false;
        editingUid = null;
        editingIsRecurring = false;
        editingRecurrenceId = '';
        handleLogout();
        authError = 'Session expired. Please enter your passcode.';
        return;
      }

      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        recurringScopeError = formatApiError(data, 'Failed to update recurring event.', res.status);
        return;
      }

      showRecurringScopeModal = false;
      pendingRecurringChange = null;
      if (source === 'modal') {
        showEventModal = false;
        editingUid = null;
        editingIsRecurring = false;
        editingRecurrenceId = '';
      }
      await fetchEvents(null, null, { force: true });
    } catch {
      recurringScopeError = 'Network error while updating recurring event.';
    } finally {
      applyingRecurringChange = false;
    }
  }

  function cancelRecurringChange() {
    if (applyingRecurringChange) return;
    if (pendingRecurringChange?.source === 'drop' && pendingRecurringChange.revert) {
      pendingRecurringChange.revert();
    }
    showRecurringScopeModal = false;
    pendingRecurringChange = null;
    recurringScopeError = '';
  }

  async function handleEventDropOrResize(info) {
    const ev = info.event;
    if (!ev || ev.extendedProps?.readOnly) {
      info.revert();
      return;
    }

    const uid = ev.extendedProps?.uid || ev.id;
    if (!uid) {
      info.revert();
      return;
    }

    const isAllDay = Boolean(ev.allDay);
    let startVal;
    let endVal;

    if (isAllDay) {
      startVal = toLocalInputValue(ev.start).slice(0, 10);
      endVal = ev.end ? toLocalInputValue(ev.end).slice(0, 10) : startVal;
      if (startVal === endVal) {
        const [y, m, d] = startVal.split('-').map(Number);
        const nextDay = new Date(Date.UTC(y, m - 1, d + 1));
        endVal = nextDay.toISOString().slice(0, 10);
      }
    } else {
      startVal =
        ev.start instanceof Date ? ev.start.toISOString() : new Date(ev.start).toISOString();
      endVal = ev.end
        ? ev.end instanceof Date
          ? ev.end.toISOString()
          : new Date(ev.end).toISOString()
        : startVal;
    }

    const payload = {
      title: ev.title || '(No Title)',
      start: startVal,
      end: endVal,
      timezone: getBrowserTimeZone(),
      rrule: ev.extendedProps?.rrule || '',
      location: ev.extendedProps?.location || '',
      location_url: sanitizeMapQuestUrl(ev.extendedProps?.locationUrl || ''),
      description: ev.extendedProps?.description || '',
      create_zoom: false,
      attendees: Array.isArray(ev.extendedProps?.attendees) ? ev.extendedProps.attendees : []
    };

    if (ev.extendedProps?.isRecurring) {
      const fallbackOldStart = info.oldEvent?.start
        ? isAllDay
          ? toLocalInputValue(info.oldEvent.start).slice(0, 10)
          : info.oldEvent.start instanceof Date
            ? info.oldEvent.start.toISOString()
            : new Date(info.oldEvent.start).toISOString()
        : '';

      recurringEditScope = 'single';
      recurringScopeError = '';
      pendingRecurringChange = {
        source: 'drop',
        uid,
        recurrenceId: ev.extendedProps?.recurrenceId || fallbackOldStart || startVal,
        payload,
        revert: () => info.revert()
      };
      showRecurringScopeModal = true;
      return;
    }

    bannerError = '';

    try {
      const res = await fetch(`/api/events/${encodeURIComponent(uid)}`, {
        method: 'PUT',
        credentials: 'same-origin',
        headers: authHeaders({
          'Content-Type': 'application/json',
          Accept: 'application/json'
        }),
        body: JSON.stringify(payload)
      });

      if (res.status === 401) {
        info.revert();
        handleLogout();
        authError = 'Session expired. Please enter your passcode.';
        return;
      }

      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        info.revert();
        bannerError = formatApiError(data, 'Failed to update moved event.', res.status);
        return;
      }

      const updatedAttendees = Array.isArray(data.attendees)
        ? data.attendees
        : (payload.attendees || []).map((att) => ({ ...att, status: 'NEEDS-ACTION' }));

      events = events.map((item) => {
        const itemUid = item.extendedProps?.uid || item.id;
        if (itemUid === uid) {
          return {
            ...item,
            allDay: isAllDay,
            start: isAllDay ? startVal : new Date(startVal),
            end: isAllDay ? endVal : new Date(endVal),
            extendedProps: {
              ...item.extendedProps,
              allDay: isAllDay,
              attendees: updatedAttendees
            }
          };
        }
        return item;
      });
      if (calendar) {
        calendar.setOption('events', events);
      }
      checkUpcomingNotifications();
      fetchEvents(null, null, { force: true });
    } catch (err) {
      info.revert();
      bannerError = 'Network error while updating moved event.';
    }
  }

  function openEventDetails(ecEvent) {
    const uid = ecEvent.extendedProps?.uid || ecEvent.id;
    selectedEvent = {
      uid,
      title: ecEvent.title,
      allDay: Boolean(ecEvent.allDay || ecEvent.extendedProps?.allDay),
      start: ecEvent.start,
      end: ecEvent.end,
      isRecurring: Boolean(ecEvent.extendedProps?.isRecurring),
      rrule: ecEvent.extendedProps?.rrule || '',
      recurrenceId: ecEvent.extendedProps?.recurrenceId || '',
      location: ecEvent.extendedProps?.location || '',
      locationUrl: sanitizeMapQuestUrl(ecEvent.extendedProps?.locationUrl || ''),
      description: ecEvent.extendedProps?.description || '',
      organizer: ecEvent.extendedProps?.organizer || null,
      attendees: Array.isArray(ecEvent.extendedProps?.attendees)
        ? ecEvent.extendedProps.attendees
        : [],
      readOnly: Boolean(ecEvent.extendedProps?.readOnly),
      calendarName: ecEvent.extendedProps?.calendarName || 'Thundercal',
      color: ecEvent.extendedProps?.color || '#2563eb'
    };
    deleteError = '';
  }

  function closeEventDetails() {
    if (deletingEvent) return;
    selectedEvent = null;
    deleteError = '';
  }

  async function handleDeleteEvent() {
    if (!selectedEvent?.uid || selectedEvent.readOnly) return;

    if (selectedEvent.isRecurring) {
      recurringDeleteScope = 'single';
      recurringDeleteError = '';
      showRecurringDeleteModal = true;
      return;
    }

    deletingEvent = true;
    deleteError = '';

    try {
      const encodedUid = encodeURIComponent(selectedEvent.uid);
      const res = await fetch(`/api/events/${encodedUid}`, {
        method: 'DELETE',
        credentials: 'same-origin',
        headers: authHeaders({ Accept: 'application/json' })
      });

      if (res.status === 401) {
        selectedEvent = null;
        handleLogout();
        authError = 'Session expired. Please enter your passcode.';
        return;
      }

      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        deleteError = formatApiError(data, 'Failed to delete event.', res.status);
        return;
      }

      selectedEvent = null;
      await fetchEvents(null, null, { force: true });
    } catch (err) {
      deleteError = 'Network error while deleting event.';
    } finally {
      deletingEvent = false;
    }
  }

  async function confirmRecurringDelete() {
    if (!selectedEvent?.uid || deletingRecurringScope) return;
    deletingRecurringScope = true;
    recurringDeleteError = '';

    const recId =
      selectedEvent.recurrenceId ||
      (selectedEvent.allDay
        ? toLocalInputValue(selectedEvent.start).slice(0, 10)
        : selectedEvent.start instanceof Date
          ? selectedEvent.start.toISOString()
          : String(selectedEvent.start || ''));

    const params = new URLSearchParams({
      scope: recurringDeleteScope,
      recurrence_id: recId
    });

    try {
      const encodedUid = encodeURIComponent(selectedEvent.uid);
      const res = await fetch(`/api/events/${encodedUid}?${params.toString()}`, {
        method: 'DELETE',
        credentials: 'same-origin',
        headers: authHeaders({ Accept: 'application/json' })
      });

      if (res.status === 401) {
        showRecurringDeleteModal = false;
        selectedEvent = null;
        handleLogout();
        authError = 'Session expired. Please enter your passcode.';
        return;
      }

      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        recurringDeleteError = formatApiError(
          data,
          'Failed to delete recurring event.',
          res.status
        );
        return;
      }

      showRecurringDeleteModal = false;
      selectedEvent = null;
      await fetchEvents(null, null, { force: true });
    } catch {
      recurringDeleteError = 'Network error while deleting recurring event.';
    } finally {
      deletingRecurringScope = false;
    }
  }

  function cancelRecurringDelete() {
    if (deletingRecurringScope) return;
    showRecurringDeleteModal = false;
    recurringDeleteError = '';
  }

  // --- Browser Desktop Notifications ---

  function initNotifications() {
    if (typeof window === 'undefined') return;
    notificationsSupported = 'Notification' in window;
    if (notificationsSupported) {
      notificationPermission = Notification.permission;
    } else {
      notificationPermission = 'unsupported';
    }

    try {
      const raw = localStorage.getItem(NOTIF_SETTINGS_KEY);
      if (raw) {
        const parsed = JSON.parse(raw);
        notificationSettings = {
          enabled: Boolean(parsed.enabled) && notificationPermission === 'granted',
          leadMinutes:
            typeof parsed.leadMinutes === 'number' && parsed.leadMinutes >= 0
              ? parsed.leadMinutes
              : 10,
          notifyAtStart: parsed.notifyAtStart !== false,
          includeSubscribed: parsed.includeSubscribed !== false
        };
      }
    } catch {
      // ignore invalid storage
    }
  }

  function persistNotificationSettings() {
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(NOTIF_SETTINGS_KEY, JSON.stringify(notificationSettings));
    } catch {
      // ignore storage quota errors
    }
  }

  function openNotificationsModal() {
    if (typeof window !== 'undefined' && 'Notification' in window) {
      notificationPermission = Notification.permission;
    }
    notifStatusMsg = '';
    showNotificationsModal = true;
  }

  function closeNotificationsModal() {
    showNotificationsModal = false;
    notifStatusMsg = '';
  }

  async function handleToggleNotifications() {
    notifStatusMsg = '';
    if (!notificationsSupported) {
      notifStatusMsg = 'Desktop notifications are not supported by this browser.';
      return;
    }

    if (notificationSettings.enabled) {
      notificationSettings = { ...notificationSettings, enabled: false };
      persistNotificationSettings();
      return;
    }

    notificationPermission = Notification.permission;
    if (notificationPermission === 'default') {
      try {
        notificationPermission = await Notification.requestPermission();
      } catch {
        // fallback for older callback-style implementations
        notificationPermission = await new Promise((resolve) =>
          Notification.requestPermission(resolve)
        );
      }
    }

    if (notificationPermission !== 'granted') {
      notificationSettings = { ...notificationSettings, enabled: false };
      persistNotificationSettings();
      notifStatusMsg =
        'Permission was denied by your browser. Please allow notifications for this site in your browser address bar settings.';
      return;
    }

    notificationSettings = { ...notificationSettings, enabled: true };
    persistNotificationSettings();
    checkUpcomingNotifications();
    notifStatusMsg = 'Desktop notifications enabled!';
  }

  function handleUpdateNotifSetting(patch) {
    notificationSettings = { ...notificationSettings, ...patch };
    persistNotificationSettings();
    if (notificationSettings.enabled) {
      checkUpcomingNotifications();
    }
  }

  function sendTestNotification() {
    notifStatusMsg = '';
    if (!notificationsSupported) {
      notifStatusMsg = 'Desktop notifications are not supported in this browser.';
      return;
    }
    if (Notification.permission !== 'granted') {
      handleToggleNotifications().then(() => {
        if (Notification.permission === 'granted') {
          sendTestNotification();
        }
      });
      return;
    }

    try {
      const n = new Notification('Thundercal — Test Notification', {
        body: `Desktop reminders are active (${notificationSettings.leadMinutes} min before events).`,
        icon: '/apple-touch-icon.png?v=2',
        badge: '/favicon.png?v=2',
        tag: `ukko-test-${Date.now()}`
      });
      n.onclick = () => {
        window.focus();
        n.close();
      };
      notifStatusMsg = 'Sent test notification to your desktop!';
    } catch (err) {
      notifStatusMsg = 'Failed to trigger notification. Check OS notification settings.';
    }
  }

  function loadNotifiedCache() {
    if (typeof localStorage === 'undefined') return {};
    try {
      const raw = localStorage.getItem(NOTIFIED_EVENTS_KEY);
      if (!raw) return {};
      const parsed = JSON.parse(raw);
      const now = Date.now();
      const cutoff = now - 48 * 60 * 60 * 1000;
      const cleaned = {};
      for (const [k, ts] of Object.entries(parsed)) {
        if (typeof ts === 'number' && ts > cutoff) {
          cleaned[k] = ts;
        }
      }
      return cleaned;
    } catch {
      return {};
    }
  }

  function saveNotifiedCache(cache) {
    if (typeof localStorage === 'undefined') return;
    try {
      localStorage.setItem(NOTIFIED_EVENTS_KEY, JSON.stringify(cache));
    } catch {
      // ignore
    }
  }

  function dispatchEventNotification(ev, startDate, minutesLeft, tagKey) {
    const timeStr = startDate.toLocaleTimeString('en-US', {
      hour: 'numeric',
      minute: '2-digit',
      timeZoneName: 'short'
    });
    const estStr = startDate.toLocaleTimeString('en-US', {
      timeZone: 'America/New_York',
      hour: 'numeric',
      minute: '2-digit'
    });

    const whenLabel =
      minutesLeft <= 1
        ? 'Starting now'
        : `Starts in ${minutesLeft} min`;

    const lines = [`${whenLabel} • ${timeStr} (${estStr} EST)`];
    if (
      ev.extendedProps?.calendarName &&
      ev.extendedProps.calendarName !== 'Thundercal' &&
      ev.extendedProps.calendarName !== 'Ukko Calendar'
    ) {
      lines.push(`Calendar: ${ev.extendedProps.calendarName}`);
    }
    if (ev.extendedProps?.location) {
      lines.push(`Location: ${ev.extendedProps.location}`);
    }

    try {
      const n = new Notification(ev.title || '(No Title)', {
        body: lines.join('\n'),
        icon: '/apple-touch-icon.png?v=2',
        badge: '/favicon.png?v=2',
        tag: tagKey
      });
      n.onclick = () => {
        window.focus();
        openEventDetails(ev);
        n.close();
      };
    } catch {
      // ignore if blocked by browser
    }
  }

  function checkUpcomingNotifications() {
    if (
      !authenticated ||
      !notificationsSupported ||
      !notificationSettings.enabled ||
      Notification.permission !== 'granted'
    ) {
      return;
    }

    const nowMs = Date.now();
    const cache = loadNotifiedCache();
    let cacheModified = false;

    const thresholds = [];
    if (notificationSettings.leadMinutes > 0) {
      thresholds.push(notificationSettings.leadMinutes);
    }
    if (notificationSettings.notifyAtStart || notificationSettings.leadMinutes === 0) {
      thresholds.push(0);
    }

    for (const ev of events) {
      if (!ev || ev.allDay || ev.extendedProps?.allDay) continue;
      if (!notificationSettings.includeSubscribed && ev.extendedProps?.readOnly) continue;

      const startDate = ev.start instanceof Date ? ev.start : new Date(ev.start);
      const startMs = startDate.getTime();
      if (Number.isNaN(startMs)) continue;

      const diffMs = startMs - nowMs;
      // Ignore events more than 5 minutes in the past or more than 2 hours in the future
      if (diffMs < -5 * 60_000 || diffMs > 2 * 60 * 60 * 1000) continue;

      const uid = ev.extendedProps?.uid || ev.id || ev.title;
      const minutesLeft = Math.max(0, Math.round(diffMs / 60_000));

      for (const leadMin of thresholds) {
        const key = `${uid}_${startMs}_${leadMin}`;
        if (cache[key]) continue;

        if (leadMin === 0) {
          // Trigger when within 5 minutes of start time (matches 5-minute check interval)
          if (diffMs <= 5 * 60_000 && diffMs >= -5 * 60_000) {
            cache[key] = nowMs;
            cacheModified = true;
            dispatchEventNotification(ev, startDate, minutesLeft, key);
          }
        } else {
          // Trigger when within leadMin window
          const windowMs = leadMin * 60_000;
          if (diffMs <= windowMs && diffMs > 0) {
            cache[key] = nowMs;
            cacheModified = true;
            dispatchEventNotification(ev, startDate, minutesLeft, key);
          }
        }
      }
    }

    if (cacheModified) {
      saveNotifiedCache(cache);
    }
  }

  function startNotificationTimers() {
    stopNotificationTimers();
    // Check upcoming notifications every 5 minutes
    reminderIntervalId = setInterval(() => {
      checkUpcomingNotifications();
    }, 5 * 60_000);
    // Refresh events in the background every 10 minutes while the tab is open
    backgroundSyncIntervalId = setInterval(() => {
      if (authenticated && !loadingEvents) {
        fetchEvents(null, null, { force: true });
      }
    }, 10 * 60_000);
  }

  function stopNotificationTimers() {
    if (reminderIntervalId) {
      clearInterval(reminderIntervalId);
      reminderIntervalId = null;
    }
    if (backgroundSyncIntervalId) {
      clearInterval(backgroundSyncIntervalId);
      backgroundSyncIntervalId = null;
    }
  }

  function initCalendar() {
    if (!calendarEl || calendar) return;

    calendar = new Calendar({
      target: calendarEl,
      props: {
        plugins: [DayGrid, TimeGrid, Interaction],
        options: {
          view: 'timeGridWeek',
          height: '100%',
          scrollTime: '08:00:00',
          selectable: true,
          editable: true,
          eventStartEditable: true,
          eventDurationEditable: true,
          eventResizableFromStart: true,
          nowIndicator: true,
          slotLabelFormat: formatDualSlotLabel,
          allDayContent: createDualSidebarHeader,
          headerToolbar: {
            start: 'prev,next today',
            center: 'title',
            end: 'dayGridMonth,timeGridWeek,timeGridDay'
          },
          events: events,
          datesSet: (info) => {
            currentRange = { start: info.start, end: info.end };
            fetchEvents(info.start, info.end);
          },
          select: (info) => {
            openCreateModal(info.start, info.end, info.allDay);
          },
          dateClick: (info) => {
            const start = info.date;
            const end = new Date(start.getTime() + 60 * 60 * 1000);
            openCreateModal(start, end, info.allDay);
          },
          eventClick: (info) => {
            openEventDetails(info.event);
          },
          eventDrop: (info) => {
            handleEventDropOrResize(info);
          },
          eventResize: (info) => {
            handleEventDropOrResize(info);
          }
        }
      }
    });
  }

  function destroyCalendar() {
    if (calendar) {
      calendar.destroy();
      calendar = null;
    }
  }

  onMount(() => {
    initTheme();
    initNotifications();
    if (typeof document !== 'undefined') {
      document.addEventListener('visibilitychange', handleVisibilityChange);
    }
    startAsciiAnimation();
    fetchAppVersion();
    if (authenticated) {
      hydrateCachedEvents();
      hydrateCachedContacts();
      initCalendar();
      fetchSubscriptions();
      fetchContacts();
      startNotificationTimers();
    }
  });

  onDestroy(() => {
    if (typeof document !== 'undefined') {
      document.removeEventListener('visibilitychange', handleVisibilityChange);
    }
    if (eventsAbortController) {
      eventsAbortController.abort();
      eventsAbortController = null;
    }
    if (locationAbortController) {
      locationAbortController.abort();
      locationAbortController = null;
    }
    stopAsciiAnimation();
    stopNotificationTimers();
    destroyCalendar();
  });
</script>

{#if !authenticated}
  <main class="auth-screen">
    <form class="auth-card" on:submit={handleLogin}>
      <div class="auth-header-row">
        <div class="auth-header">
          <div
            class="logo-lockup logo-lockup-auth"
            aria-label="Thundercal"
            on:mouseenter={triggerAsciiSurge}
            role="img"
          >
            <img class="logo-mark-img" src="/logo.png" alt="Thundercal logo" />
            <div class="ascii-wordmark" aria-hidden="true">
              <pre class="ascii-part ascii-thunder">{asciiThunderText}</pre>
              <pre class="ascii-part ascii-cal">{asciiCalText}</pre>
            </div>
          </div>
          <p>Enter your passcode to access your Thundermail calendar.</p>
        </div>
        <button
          type="button"
          class="btn btn-secondary btn-icon"
          on:click={toggleTheme}
          title={darkMode ? 'Switch to light mode' : 'Switch to dark mode'}
        >
          {darkMode ? '☀️' : '🌙'}
        </button>
      </div>

      {#if authError}
        <div class="alert alert-error">{authError}</div>
      {/if}

      <label class="field">
        <span>Passcode</span>
        <input
          type="password"
          bind:value={passcode}
          placeholder="Enter passcode"
          required
          disabled={authLoading}
        />
      </label>

      <button type="submit" class="btn btn-primary btn-block" disabled={authLoading}>
        {authLoading ? 'Unlocking...' : 'Unlock Calendar'}
      </button>
    </form>
  </main>
{:else}
  <main class="container">
    <input
      type="file"
      accept=".ics,text/calendar"
      multiple
      class="sr-only-input"
      bind:this={icsFileInput}
      on:change={handleIcsFileSelected}
    />

    <header class="header">
      <div class="header-left">
        <div
          class="logo-lockup"
          aria-label="Thundercal"
          on:mouseenter={triggerAsciiSurge}
          role="img"
        >
          <img class="logo-mark-img" src="/logo.png" alt="Thundercal logo" />
          <div class="ascii-wordmark" aria-hidden="true">
            <pre class="ascii-part ascii-thunder">{asciiThunderText}</pre>
            <pre class="ascii-part ascii-cal">{asciiCalText}</pre>
          </div>
        </div>
        {#if loadingEvents || importingIcs}
          <span class="status-pill">
            {importingIcs ? 'Importing .ics...' : 'Syncing...'}
          </span>
        {/if}
      </div>

      <div class="header-actions">
        <button
          type="button"
          class="btn btn-secondary"
          on:click={toggleTheme}
          title={darkMode ? 'Switch to light mode' : 'Switch to dark mode'}
        >
          {darkMode ? '☀️ Light' : '🌙 Dark'}
        </button>
        <button
          type="button"
          class="btn btn-secondary"
          class:btn-notif-active={notificationSettings.enabled && notificationPermission === 'granted'}
          on:click={openNotificationsModal}
          title="Configure browser desktop notifications for upcoming events"
        >
          {notificationSettings.enabled && notificationPermission === 'granted'
            ? '🔔 Alerts On'
            : '🔕 Alerts'}
        </button>
        <button
          type="button"
          class="btn btn-secondary"
          on:click={openSubscriptionsModal}
          title="Subscribe to Google Calendar or other .ics feeds"
        >
          Calendars{subscriptions.length ? ` (${subscriptions.length + 1})` : ''}
        </button>
        <button
          type="button"
          class="btn btn-secondary"
          on:click={triggerIcsImport}
          disabled={importingIcs}
          title="Import .ics file into your calendar"
        >
          {importingIcs ? 'Importing...' : 'Import .ics'}
        </button>
        <button
          type="button"
          class="btn btn-secondary"
          on:click={() => fetchEvents(null, null, { force: true, serverRefresh: true })}
          disabled={loadingEvents}
        >
          Refresh
        </button>
        <button
          type="button"
          class="btn btn-primary"
          on:click={() => openCreateModal()}
        >
          + New Event
        </button>
        <button
          type="button"
          class="btn btn-ghost"
          on:click={handleLogout}
          title="Lock calendar"
        >
          Lock
        </button>
      </div>
    </header>

    {#if subscriptions.length > 0}
      <div class="calendar-legend">
        <span class="legend-chip">
          <span class="legend-dot" style="background: #039be5;"></span>
          <span>Thundercal</span>
        </span>
        {#each subscriptions as sub (sub.id)}
          <button
            type="button"
            class="legend-chip legend-chip-btn"
            class:legend-chip-muted={!sub.enabled}
            on:click={() => handleToggleSubscription(sub)}
            title={sub.enabled ? 'Click to hide calendar' : 'Click to show calendar'}
          >
            <span class="legend-dot" style="background: {sub.color || '#9333ea'};"></span>
            <span>{sub.name}</span>
          </button>
        {/each}
      </div>
    {/if}

    {#if bannerError}
      <div class="alert alert-error banner">
        <span>{bannerError}</span>
        <button type="button" class="btn-link" on:click={() => (bannerError = '')}>Dismiss</button>
      </div>
    {/if}

    {#if bannerSuccess}
      <div class="alert alert-success banner">
        <span>{bannerSuccess}</span>
        <button type="button" class="btn-link" on:click={() => (bannerSuccess = '')}>Dismiss</button>
      </div>
    {/if}

    <div
      class="calendar-wrapper"
      class:ec-dark={darkMode}
      bind:this={calendarEl}
    ></div>
  </main>

  {#if showSubscriptionsModal}
    <div class="modal-backdrop" on:click|self={closeSubscriptionsModal} role="presentation">
      <div class="modal modal-wide" role="dialog" aria-modal="true" aria-labelledby="sub-modal-title">
        <div class="modal-header">
          <h2 id="sub-modal-title">Calendars &amp; Google Calendar Subscriptions</h2>
          <button type="button" class="close-btn" on:click={closeSubscriptionsModal} aria-label="Close">
            &times;
          </button>
        </div>

        <div class="sub-list">
          <div class="sub-item sub-item-primary">
            <div class="sub-item-top">
              <div class="sub-item-left">
                <span class="legend-dot" style="background: #039be5;"></span>
                <div>
                  <div class="sub-item-name">Thundercal (Primary)</div>
                  <div class="sub-item-meta">Thundermail CalDAV • Read &amp; Write</div>
                </div>
              </div>
            </div>

            {#if publishedFeedUrl}
              <div class="publish-box">
                <div class="publish-box-label">
                  <span>Shareable iCal (<code>.ics</code>) URL for your calendar only:</span>
                  <button
                    type="button"
                    class="btn-link"
                    on:click={handleRotateFeedToken}
                    disabled={rotatingToken}
                    title="Generate a new secret link and invalidate the old one"
                  >
                    {rotatingToken ? 'Resetting...' : 'Reset Link'}
                  </button>
                </div>
                <div class="publish-url-row">
                  <input
                    type="text"
                    class="publish-url-input"
                    readonly
                    value={publishedFeedUrl}
                    on:focus={(e) => e.target.select()}
                  />
                  <button
                    type="button"
                    class="btn btn-secondary btn-sm"
                    on:click={handleCopyFeedUrl}
                  >
                    {feedCopied ? 'Copied!' : 'Copy URL'}
                  </button>
                </div>
                <div class="publish-hint">
                  Your wife can subscribe in Google Calendar via <strong>+</strong> next to
                  <em>Other calendars</em> → <strong>From URL</strong> → paste this link.
                </div>
              </div>
            {/if}
          </div>

          {#each subscriptions as sub (sub.id)}
            <div class="sub-item">
              <div class="sub-item-left">
                <input
                  type="checkbox"
                  checked={sub.enabled !== false}
                  on:change={() => handleToggleSubscription(sub)}
                  title="Show/hide this calendar"
                />
                <input
                  type="color"
                  class="color-picker-inline"
                  value={sub.color || '#9333ea'}
                  on:change={(e) => handleChangeSubColor(sub, e.target.value)}
                  title="Change calendar color"
                />
                <div>
                  <div class="sub-item-name">{sub.name}</div>
                  <div class="sub-item-meta">{sub.url}</div>
                </div>
              </div>
              <button
                type="button"
                class="btn btn-ghost btn-sm"
                on:click={() => handleDeleteSubscription(sub.id)}
              >
                Remove
              </button>
            </div>
          {/each}
        </div>

        <hr class="modal-divider" />

        <form on:submit={handleAddSubscription} class="modal-form">
          <h3 class="sub-form-heading">Subscribe to Wife's Google Calendar / iCal Feed</h3>
          <p class="sub-help-text">
            In Google Calendar: open <strong>Settings</strong> → click the calendar under
            <em>Settings for my calendars</em> → scroll to <strong>Integrate calendar</strong> →
            copy the <strong>Secret address in iCal format</strong> (<code>.ics</code> URL).
          </p>

          {#if subError}
            <div class="alert alert-error">{subError}</div>
          {/if}

          <div class="field-row">
            <label class="field">
              <span>Calendar Name</span>
              <input
                type="text"
                bind:value={subForm.name}
                placeholder="e.g. Nicole's Calendar"
                disabled={subSaving}
              />
            </label>

            <div class="field field-color">
              <span>Color</span>
              <div class="color-swatches">
                {#each SUBSCRIPTION_COLORS as swatch}
                  <button
                    type="button"
                    class="swatch-btn"
                    class:swatch-active={subForm.color === swatch.value}
                    style="background: {swatch.value};"
                    on:click={() => (subForm.color = swatch.value)}
                    title={swatch.name}
                    aria-label={swatch.name}
                  ></button>
                {/each}
              </div>
            </div>
          </div>

          <label class="field">
            <span>Google Calendar iCal (.ics) URL *</span>
            <input
              type="text"
              bind:value={subForm.url}
              placeholder="https://calendar.google.com/calendar/ical/.../basic.ics"
              required
              disabled={subSaving}
            />
          </label>

          <div class="modal-actions">
            <button
              type="button"
              class="btn btn-secondary"
              on:click={closeSubscriptionsModal}
              disabled={subSaving}
            >
              Close
            </button>
            <button type="submit" class="btn btn-primary" disabled={subSaving}>
              {subSaving ? 'Connecting Feed...' : '+ Subscribe Calendar'}
            </button>
          </div>
        </form>
      </div>
    </div>
  {/if}

  {#if showEventModal}
    <div class="modal-backdrop" on:click|self={closeEventModal} role="presentation">
      <div class="modal" role="dialog" aria-modal="true" aria-labelledby="event-modal-title">
        <div class="modal-header">
          <h2 id="event-modal-title">
            {editingUid ? 'Edit Calendar Event' : 'New Calendar Event'}
          </h2>
          <button type="button" class="close-btn" on:click={closeEventModal} aria-label="Close">
            &times;
          </button>
        </div>

        {#if formError}
          <div class="alert alert-error">{formError}</div>
        {/if}

        <form on:submit={handleSaveEvent} class="modal-form">
          <label class="field">
            <span>Title *</span>
            <input
              type="text"
              bind:value={eventForm.title}
              placeholder="Team Sync"
              required
              disabled={savingEvent}
            />
          </label>

          <label class="checkbox-field">
            <input
              type="checkbox"
              bind:checked={eventForm.all_day}
              disabled={savingEvent}
            />
            <span>All-day event</span>
          </label>

          <div class="field-row">
            <label class="field">
              <span>Start *</span>
              <input
                type="datetime-local"
                bind:value={eventForm.start}
                required
                disabled={savingEvent}
              />
            </label>

            <label class="field">
              <span>End *</span>
              <input
                type="datetime-local"
                bind:value={eventForm.end}
                required
                disabled={savingEvent}
              />
            </label>
          </div>

          <div class="field-row">
            <label class="field">
              <span>Repeat</span>
              <select class="select-input" bind:value={eventForm.rrule} disabled={savingEvent}>
                {#each RRULE_PRESETS as opt (opt.value)}
                  <option value={opt.value}>{opt.label}</option>
                {/each}
                {#if eventForm.rrule && !isPresetRrule(eventForm.rrule)}
                  <option value={eventForm.rrule}>
                    Custom ({formatRruleSummary(eventForm.rrule)})
                  </option>
                {/if}
              </select>
            </label>

            {#if eventForm.rrule}
              <label class="field">
                <span>Repeat Ends</span>
                <select
                  class="select-input"
                  value={repeatEndType}
                  on:change={handleRepeatEndTypeChange}
                  disabled={savingEvent}
                >
                  <option value="never">Never</option>
                  <option value="until">On date</option>
                  <option value="count">After N occurrences</option>
                </select>
              </label>
            {/if}
          </div>

          {#if eventForm.rrule && repeatEndType === 'until'}
            <label class="field">
              <span>End Repeat On</span>
              <input
                type="date"
                bind:value={repeatUntilDate}
                required
                disabled={savingEvent}
              />
            </label>
          {:else if eventForm.rrule && repeatEndType === 'count'}
            <label class="field">
              <span>Number of Occurrences</span>
              <input
                type="number"
                min="1"
                max="999"
                bind:value={repeatCount}
                required
                disabled={savingEvent}
              />
            </label>
          {/if}

          <label class="checkbox-field">
            <input
              type="checkbox"
              bind:checked={eventForm.create_zoom}
              disabled={savingEvent}
            />
            <span>
              {editingUid
                ? 'Generate & attach a new Zoom meeting'
                : 'Automatically create Zoom meeting'}
            </span>
          </label>

          <div class="field attendee-field">
            <span>
              Location {eventForm.create_zoom ? '(will be replaced with Zoom Join URL)' : ''}
              {#if locationLoading && !eventForm.create_zoom}
                <small class="field-hint">(Searching MapQuest...)</small>
              {/if}
            </span>
            <div class="attendee-input-wrapper">
              <input
                type="text"
                value={eventForm.location}
                on:input={handleLocationInput}
                on:focus={() => {
                  if (locationSuggestions.length > 0) {
                    locationDropdownOpen = true;
                  }
                }}
                on:blur={() => {
                  setTimeout(() => {
                    locationDropdownOpen = false;
                  }, 160);
                }}
                on:keydown={handleLocationKeydown}
                placeholder={eventForm.create_zoom
                  ? 'Zoom link generated automatically'
                  : 'Search address, place, or paste URL...'}
                disabled={savingEvent || eventForm.create_zoom}
                autocomplete="off"
              />

              {#if !eventForm.create_zoom && locationDropdownOpen && locationSuggestions.length > 0}
                <ul class="contact-suggestions" role="listbox">
                  {#each locationSuggestions as suggestion, idx (suggestion.display + idx)}
                    <li>
                      <button
                        type="button"
                        class="contact-suggestion-btn"
                        class:contact-suggestion-active={idx === locationHighlightIndex}
                        on:mousedown|preventDefault={() => selectLocationSuggestion(suggestion)}
                      >
                        <span class="contact-suggestion-name">📍 {suggestion.display}</span>
                        <span class="contact-suggestion-email">
                          {suggestion.type === 'poi' ? 'Place' : 'Address'}
                        </span>
                      </button>
                    </li>
                  {/each}
                </ul>
              {/if}
            </div>

            {#if !eventForm.create_zoom && eventForm.location.trim() && !isUrl(eventForm.location)}
              <div class="location-mapquest-preview">
                <a
                  href={buildMapQuestUrl(eventForm.location, eventForm.location_url)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="mapquest-inline-link"
                >
                  📍 Preview on MapQuest &nearr;
                </a>
              </div>
            {/if}
          </div>

          <div class="field attendee-field">
            <span>
              Invite People
              {#if allKnownContacts.length > 0}
                <small class="field-hint">
                  ({allKnownContacts.length} Thundermail CardDAV / calendar contact{allKnownContacts.length === 1 ? '' : 's'} available)
                </small>
              {/if}
            </span>

            {#if eventForm.attendees && eventForm.attendees.length > 0}
              <div class="attendee-chips">
                {#each eventForm.attendees as att (att.email)}
                  <span class="attendee-chip">
                    <span class="attendee-chip-label">
                      {#if att.name}
                        <strong>{att.name}</strong> &lt;{att.email}&gt;
                      {:else}
                        {att.email}
                      {/if}
                    </span>
                    <span
                      class="attendee-chip-status status-{(att.status || 'NEEDS-ACTION').toLowerCase()}"
                    >
                      {formatAttendeeStatus(att.status)}
                    </span>
                    <button
                      type="button"
                      class="attendee-chip-remove"
                      on:click={() => removeAttendee(att.email)}
                      disabled={savingEvent}
                      aria-label="Remove {att.email}"
                    >
                      &times;
                    </button>
                  </span>
                {/each}
              </div>
              {#if editingUid}
                <small class="field-hint attendee-pending-note">
                  Changing event details marks invitees as Pending until they accept the update.
                </small>
              {/if}
            {/if}

            <div class="attendee-input-wrapper">
              <div class="attendee-input-row">
                <input
                  type="text"
                  bind:value={attendeeQuery}
                  on:focus={() => {
                    attendeeDropdownOpen = true;
                    attendeeHighlightIndex = 0;
                  }}
                  on:input={() => {
                    attendeeDropdownOpen = true;
                    attendeeHighlightIndex = 0;
                  }}
                  on:blur={() => {
                    setTimeout(() => {
                      attendeeDropdownOpen = false;
                    }, 160);
                  }}
                  on:keydown={handleAttendeeKeydown}
                  placeholder="Type name or email (press Enter or Add)..."
                  disabled={savingEvent}
                  autocomplete="off"
                />
                <button
                  type="button"
                  class="btn btn-secondary btn-sm"
                  on:click={handleAddTypedAttendee}
                  disabled={savingEvent || !attendeeQuery.trim()}
                >
                  + Add
                </button>
              </div>

              {#if attendeeDropdownOpen && filteredContactSuggestions.length > 0}
                <ul class="contact-suggestions" role="listbox">
                  {#each filteredContactSuggestions as contact, idx (contact.email)}
                    <li>
                      <button
                        type="button"
                        class="contact-suggestion-btn"
                        class:contact-suggestion-active={idx === attendeeHighlightIndex}
                        on:mousedown|preventDefault={() => addAttendee(contact)}
                      >
                        <span class="contact-suggestion-name">
                          {contact.name || contact.email}
                        </span>
                        <span class="contact-suggestion-email">{contact.email}</span>
                      </button>
                    </li>
                  {/each}
                </ul>
              {/if}
            </div>
          </div>

          <label class="field">
            <span>Description</span>
            <textarea
              rows="4"
              bind:value={eventForm.description}
              placeholder="Agenda or notes..."
              disabled={savingEvent}
            ></textarea>
          </label>

          <div class="modal-actions">
            <button
              type="button"
              class="btn btn-secondary"
              on:click={closeEventModal}
              disabled={savingEvent}
            >
              Cancel
            </button>
            <button type="submit" class="btn btn-primary" disabled={savingEvent}>
              {#if savingEvent}
                {eventForm.create_zoom ? 'Creating Zoom & Saving...' : 'Saving...'}
              {:else}
                {editingUid ? 'Update Event' : 'Save Event'}
              {/if}
            </button>
          </div>
        </form>
      </div>
    </div>
  {/if}

  {#if selectedEvent}
    <div class="modal-backdrop" on:click|self={closeEventDetails} role="presentation">
      <div class="modal" role="dialog" aria-modal="true" aria-labelledby="detail-modal-title">
        <div class="modal-header">
          <div>
            <h2 id="detail-modal-title">{selectedEvent.title}</h2>
            <div class="detail-calendar-badge">
              <span class="legend-dot" style="background: {selectedEvent.color || '#039be5'};"></span>
              <span>{selectedEvent.calendarName || 'Thundercal'}</span>
              {#if selectedEvent.readOnly}
                <span class="readonly-tag">Subscribed</span>
              {/if}
            </div>
          </div>
          <button type="button" class="close-btn" on:click={closeEventDetails} aria-label="Close">
            &times;
          </button>
        </div>

        {#if deleteError}
          <div class="alert alert-error">{deleteError}</div>
        {/if}

        <div class="event-details">
          <div class="detail-row">
            <strong>Starts:</strong>
            <span>{formatDateTime(selectedEvent.start, selectedEvent.allDay)}</span>
          </div>
          {#if selectedEvent.end && !selectedEvent.allDay}
            <div class="detail-row">
              <strong>Ends:</strong>
              <span>{formatDateTime(selectedEvent.end, false)}</span>
            </div>
          {/if}
          {#if selectedEvent.isRecurring}
            <div class="detail-row">
              <strong>Repeats:</strong>
              <span>🔁 {formatRruleSummary(selectedEvent.rrule)}</span>
            </div>
          {/if}

          {#if selectedEvent.location}
            <div class="detail-row">
              <strong>Location:</strong>
              {#if isUrl(selectedEvent.location)}
                <a
                  href={selectedEvent.location}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="zoom-link"
                >
                  {selectedEvent.location}
                </a>
              {:else}
                <a
                  href={buildMapQuestUrl(selectedEvent.location, selectedEvent.locationUrl)}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="zoom-link mapquest-detail-link"
                  title="Open address in MapQuest"
                >
                  <span>📍 {selectedEvent.location}</span>
                  <span class="mapquest-tag">MapQuest &nearr;</span>
                </a>
              {/if}
            </div>
          {/if}

          {#if selectedEvent.organizer && selectedEvent.organizer.email}
            <div class="detail-row">
              <strong>Organizer:</strong>
              <span>
                {#if selectedEvent.organizer.name}
                  {selectedEvent.organizer.name} ({selectedEvent.organizer.email})
                {:else}
                  {selectedEvent.organizer.email}
                {/if}
              </span>
            </div>
          {/if}

          {#if selectedEvent.attendees && selectedEvent.attendees.length > 0}
            <div class="detail-attendees">
              <strong>Attendees ({selectedEvent.attendees.length}):</strong>
              <ul class="detail-attendee-list">
                {#each selectedEvent.attendees as att (att.email)}
                  <li class="detail-attendee-item">
                    <div class="detail-attendee-info">
                      {#if att.name}
                        <span class="detail-attendee-name">{att.name}</span>
                        <span class="detail-attendee-email">&lt;{att.email}&gt;</span>
                      {:else}
                        <span class="detail-attendee-name">{att.email}</span>
                      {/if}
                    </div>
                    <span
                      class="attendee-status-badge status-{(att.status || 'NEEDS-ACTION').toLowerCase()}"
                    >
                      {formatAttendeeStatus(att.status)}
                    </span>
                  </li>
                {/each}
              </ul>
            </div>
          {/if}

          {#if selectedEvent.description}
            <div class="detail-description">
              <strong>Description:</strong>
              <pre>{selectedEvent.description}</pre>
            </div>
          {/if}
        </div>

        <div class="modal-actions" class:modal-actions-split={!selectedEvent.readOnly}>
          {#if !selectedEvent.readOnly}
            <button
              type="button"
              class="btn btn-danger"
              on:click={handleDeleteEvent}
              disabled={deletingEvent}
              title={selectedEvent.attendees?.length
                ? 'Deletes event and notifies invitees via Thundermail'
                : 'Delete event'}
            >
              {#if deletingEvent}
                Deleting...
              {:else if selectedEvent.attendees && selectedEvent.attendees.length > 0}
                Cancel &amp; Notify Invitees
              {:else}
                Delete Event
              {/if}
            </button>
          {/if}
          <div class="modal-actions-right">
            {#if !selectedEvent.readOnly}
              <button
                type="button"
                class="btn btn-primary"
                on:click={() => openEditModal(selectedEvent)}
                disabled={deletingEvent}
              >
                Edit Event
              </button>
            {/if}
            <button
              type="button"
              class="btn btn-secondary"
              on:click={closeEventDetails}
              disabled={deletingEvent}
            >
              Close
            </button>
          </div>
        </div>
      </div>
    </div>
  {/if}

  {#if showNotificationsModal}
    <div class="modal-backdrop" on:click|self={closeNotificationsModal} role="presentation">
      <div class="modal" role="dialog" aria-modal="true" aria-labelledby="notif-modal-title">
        <div class="modal-header">
          <div>
            <h2 id="notif-modal-title">Desktop Notifications</h2>
            <div class="detail-calendar-badge">
              <span>Browser alerts for upcoming calendar events</span>
            </div>
          </div>
          <button
            type="button"
            class="close-btn"
            on:click={closeNotificationsModal}
            aria-label="Close"
          >
            &times;
          </button>
        </div>

        {#if notifStatusMsg}
          <div
            class="alert"
            class:alert-error={notificationPermission === 'denied' || !notificationsSupported}
            class:alert-success={notificationPermission !== 'denied' && notificationsSupported}
          >
            {notifStatusMsg}
          </div>
        {/if}

        <div class="notif-panel">
          <div class="notif-toggle-row">
            <div>
              <div class="sub-item-name">Enable Desktop Alerts</div>
              <div class="sub-item-meta">
                {#if !notificationsSupported}
                  Not supported by this browser
                {:else if notificationPermission === 'denied'}
                  Blocked in browser permissions
                {:else if notificationSettings.enabled && notificationPermission === 'granted'}
                  Active • Checking upcoming events in the background
                {:else}
                  Off • Click to grant permission and enable alerts
                {/if}
              </div>
            </div>
            <button
              type="button"
              class="btn"
              class:btn-primary={!notificationSettings.enabled}
              class:btn-secondary={notificationSettings.enabled}
              on:click={handleToggleNotifications}
              disabled={!notificationsSupported}
            >
              {notificationSettings.enabled && notificationPermission === 'granted'
                ? 'Disable Alerts'
                : 'Enable Alerts'}
            </button>
          </div>

          <label class="field">
            <span>Remind me before event starts</span>
            <select
              class="select-input"
              value={notificationSettings.leadMinutes}
              on:change={(e) =>
                handleUpdateNotifSetting({ leadMinutes: Number(e.target.value) })}
            >
              {#each REMINDER_OPTIONS as opt}
                <option value={opt.minutes}>{opt.label}</option>
              {/each}
            </select>
          </label>

          {#if notificationSettings.leadMinutes > 0}
            <label class="checkbox-field">
              <input
                type="checkbox"
                checked={notificationSettings.notifyAtStart}
                on:change={(e) =>
                  handleUpdateNotifSetting({ notifyAtStart: e.target.checked })}
              />
              <span>Also send a notification right when the event starts</span>
            </label>
          {/if}

          <label class="checkbox-field">
            <input
              type="checkbox"
              checked={notificationSettings.includeSubscribed}
              on:change={(e) =>
                handleUpdateNotifSetting({ includeSubscribed: e.target.checked })}
            />
            <span>Include events from subscribed calendars</span>
          </label>
        </div>

        <div class="modal-actions modal-actions-split">
          <button
            type="button"
            class="btn btn-secondary"
            on:click={sendTestNotification}
            disabled={!notificationsSupported}
          >
            Send Test Notification
          </button>
          <button type="button" class="btn btn-primary" on:click={closeNotificationsModal}>
            Done
          </button>
        </div>
      </div>
    </div>
  {/if}

  {#if showRecurringScopeModal}
    <div
      class="modal-backdrop modal-backdrop-nested"
      on:click|self={cancelRecurringChange}
      role="presentation"
    >
      <div
        class="modal modal-compact"
        role="dialog"
        aria-modal="true"
        aria-labelledby="recurring-scope-modal-title"
      >
        <div class="modal-header">
          <div>
            <h2 id="recurring-scope-modal-title">Change Recurring Event</h2>
            <div class="detail-calendar-badge">
              <span>Choose which occurrences to update</span>
            </div>
          </div>
          <button
            type="button"
            class="close-btn"
            on:click={cancelRecurringChange}
            disabled={applyingRecurringChange}
            aria-label="Close"
          >
            &times;
          </button>
        </div>

        {#if recurringScopeError}
          <div class="alert alert-error">{recurringScopeError}</div>
        {/if}

        <p class="scope-prompt">
          Would you like to apply this adjustment to just this single event, or to this event and
          every subsequent one in the series?
        </p>

        <div class="scope-options" role="radiogroup" aria-label="Recurring event edit scope">
          <label
            class="scope-option"
            class:scope-option-active={recurringEditScope === 'single'}
          >
            <input
              type="radio"
              name="recurring-edit-scope"
              value="single"
              bind:group={recurringEditScope}
              disabled={applyingRecurringChange}
            />
            <div class="scope-option-body">
              <span class="scope-option-title">Just this event</span>
              <span class="scope-option-desc">
                Only adjusts this single occurrence; all other events in the series remain unchanged.
              </span>
            </div>
          </label>

          <label
            class="scope-option"
            class:scope-option-active={recurringEditScope === 'following'}
          >
            <input
              type="radio"
              name="recurring-edit-scope"
              value="following"
              bind:group={recurringEditScope}
              disabled={applyingRecurringChange}
            />
            <div class="scope-option-body">
              <span class="scope-option-title">This and following events</span>
              <span class="scope-option-desc">
                Updates this event and every subsequent occurrence in the series.
              </span>
            </div>
          </label>
        </div>

        <div class="modal-actions">
          <button
            type="button"
            class="btn btn-secondary"
            on:click={cancelRecurringChange}
            disabled={applyingRecurringChange}
          >
            Cancel
          </button>
          <button
            type="button"
            class="btn btn-primary"
            on:click={confirmRecurringChange}
            disabled={applyingRecurringChange}
          >
            {applyingRecurringChange ? 'Applying...' : 'Apply Change'}
          </button>
        </div>
      </div>
    </div>
  {/if}

  {#if showRecurringDeleteModal}
    <div
      class="modal-backdrop modal-backdrop-nested"
      on:click|self={cancelRecurringDelete}
      role="presentation"
    >
      <div
        class="modal modal-compact"
        role="dialog"
        aria-modal="true"
        aria-labelledby="recurring-delete-modal-title"
      >
        <div class="modal-header">
          <div>
            <h2 id="recurring-delete-modal-title">Delete Recurring Event</h2>
            <div class="detail-calendar-badge">
              <span>Choose which occurrences to remove</span>
            </div>
          </div>
          <button
            type="button"
            class="close-btn"
            on:click={cancelRecurringDelete}
            disabled={deletingRecurringScope}
            aria-label="Close"
          >
            &times;
          </button>
        </div>

        {#if recurringDeleteError}
          <div class="alert alert-error">{recurringDeleteError}</div>
        {/if}

        <div class="scope-options" role="radiogroup" aria-label="Recurring event delete scope">
          <label
            class="scope-option"
            class:scope-option-active={recurringDeleteScope === 'single'}
          >
            <input
              type="radio"
              name="recurring-delete-scope"
              value="single"
              bind:group={recurringDeleteScope}
              disabled={deletingRecurringScope}
            />
            <div class="scope-option-body">
              <span class="scope-option-title">Just this event</span>
              <span class="scope-option-desc">
                Deletes only this single occurrence and keeps the rest of the series.
              </span>
            </div>
          </label>

          <label
            class="scope-option"
            class:scope-option-active={recurringDeleteScope === 'following'}
          >
            <input
              type="radio"
              name="recurring-delete-scope"
              value="following"
              bind:group={recurringDeleteScope}
              disabled={deletingRecurringScope}
            />
            <div class="scope-option-body">
              <span class="scope-option-title">This and following events</span>
              <span class="scope-option-desc">
                Deletes this event and all future occurrences while keeping earlier ones.
              </span>
            </div>
          </label>

          <label
            class="scope-option"
            class:scope-option-active={recurringDeleteScope === 'all'}
          >
            <input
              type="radio"
              name="recurring-delete-scope"
              value="all"
              bind:group={recurringDeleteScope}
              disabled={deletingRecurringScope}
            />
            <div class="scope-option-body">
              <span class="scope-option-title">All events in the series</span>
              <span class="scope-option-desc">
                Deletes the entire recurring series{selectedEvent?.attendees?.length
                  ? ' and notifies invitees'
                  : ''}.
              </span>
            </div>
          </label>
        </div>

        <div class="modal-actions">
          <button
            type="button"
            class="btn btn-secondary"
            on:click={cancelRecurringDelete}
            disabled={deletingRecurringScope}
          >
            Cancel
          </button>
          <button
            type="button"
            class="btn btn-danger"
            on:click={confirmRecurringDelete}
            disabled={deletingRecurringScope}
          >
            {deletingRecurringScope ? 'Deleting...' : 'Delete'}
          </button>
        </div>
      </div>
    </div>
  {/if}
{/if}

<div class="version-corner" aria-label="Application version">
  v{appVersion}
</div>

<style>
  .sr-only-input {
    display: none;
  }

  .auth-screen {
    min-height: 100vh;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1.5rem;
  }

  .auth-card {
    background: var(--bg-surface);
    border: 1px solid var(--border-subtle);
    border-radius: 0.75rem;
    padding: 2rem;
    width: 100%;
    max-width: 420px;
    box-shadow: var(--shadow-card);
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
  }

  .auth-header-row {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 0.75rem;
  }

  .auth-header p {
    margin: 0.65rem 0 0;
    color: var(--text-muted);
    font-size: 0.925rem;
  }

  .logo-lockup {
    display: inline-flex;
    align-items: center;
    gap: 0.75rem;
    color: var(--text-primary);
    user-select: none;
  }

  .logo-lockup .logo-mark-img {
    height: 2.75rem;
    width: 2.75rem;
    object-fit: contain;
    display: block;
    flex-shrink: 0;
    filter: drop-shadow(0 2px 6px rgba(37, 99, 235, 0.28));
    transition: transform 0.2s ease, filter 0.2s ease;
  }

  .logo-lockup:hover .logo-mark-img {
    transform: scale(1.06) rotate(-3deg);
    filter: drop-shadow(0 3px 10px rgba(99, 102, 241, 0.45));
  }

  .ascii-wordmark {
    display: inline-flex;
    align-items: center;
    overflow-x: auto;
    max-width: 100%;
  }

  .ascii-part {
    margin: 0;
    padding: 0;
    font-family: 'JetBrains Mono', 'Fira Code', 'SFMono-Regular', Consolas, 'Liberation Mono',
      Menlo, monospace;
    font-size: 0.46rem;
    line-height: 1.05;
    letter-spacing: 0.02em;
    font-weight: 700;
    white-space: pre;
    animation: ascii-electric-glow 3.2s ease-in-out infinite;
  }

  .ascii-thunder {
    color: var(--text-primary);
  }

  .ascii-cal {
    color: #3b82f6;
    text-shadow: 0 0 8px rgba(59, 130, 246, 0.35);
  }

  @keyframes ascii-electric-glow {
    0%,
    100% {
      filter: drop-shadow(0 0 0px rgba(59, 130, 246, 0));
    }
    50% {
      filter: drop-shadow(0 0 5px rgba(99, 102, 241, 0.45));
    }
  }

  .logo-lockup-auth .logo-mark-img {
    height: 2.9rem;
    width: 2.9rem;
  }

  .logo-lockup-auth .ascii-part {
    font-size: 0.42rem;
  }

  .container {
    max-width: 1280px;
    width: 100%;
    height: 100vh;
    max-height: 100vh;
    overflow: hidden;
    margin: 0 auto;
    padding: 1rem 1.5rem 1.25rem;
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .header {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    justify-content: space-between;
    flex-wrap: wrap;
    gap: 0.75rem;
  }

  .header-left {
    display: flex;
    align-items: center;
    gap: 0.85rem;
  }

  .status-pill {
    font-size: 0.8rem;
    background: var(--pill-bg);
    color: var(--pill-text);
    padding: 0.2rem 0.65rem;
    border-radius: 999px;
    font-weight: 500;
  }

  .header-actions {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    flex-wrap: wrap;
  }

  .calendar-legend {
    flex-shrink: 0;
    display: flex;
    align-items: center;
    gap: 0.5rem;
    flex-wrap: wrap;
  }

  .legend-chip {
    display: inline-flex;
    align-items: center;
    gap: 0.45rem;
    font-size: 0.8rem;
    font-weight: 500;
    padding: 0.25rem 0.65rem;
    border-radius: 999px;
    background: var(--bg-surface);
    border: 1px solid var(--border-subtle);
    color: var(--text-secondary);
  }

  .legend-chip-btn {
    cursor: pointer;
    transition: opacity 0.15s ease, border-color 0.15s ease;
  }

  .legend-chip-btn:hover {
    border-color: var(--border-color);
  }

  .legend-chip-muted {
    opacity: 0.45;
    text-decoration: line-through;
  }

  .legend-dot {
    width: 0.6rem;
    height: 0.6rem;
    border-radius: 999px;
    display: inline-block;
    flex-shrink: 0;
  }

  .calendar-wrapper {
    background: var(--bg-surface);
    border: 1px solid var(--border-subtle);
    border-radius: 0.75rem;
    padding: 1rem;
    box-shadow: var(--shadow-card);
    flex: 1 1 0%;
    min-height: 0;
    display: flex;
    flex-direction: column;
    overflow: hidden;
  }

  .btn {
    appearance: none;
    border: 1px solid transparent;
    border-radius: 0.5rem;
    padding: 0.5rem 0.9rem;
    font-size: 0.9rem;
    font-weight: 500;
    cursor: pointer;
    transition: background-color 0.15s ease, border-color 0.15s ease, color 0.15s ease;
  }

  .btn-sm {
    padding: 0.3rem 0.6rem;
    font-size: 0.8rem;
  }

  .btn-icon {
    padding: 0.45rem 0.65rem;
    line-height: 1;
  }

  .btn:disabled {
    opacity: 0.6;
    cursor: not-allowed;
  }

  .btn-block {
    width: 100%;
    padding: 0.65rem 1rem;
  }

  .btn-primary {
    background: #2563eb;
    color: #ffffff;
  }

  .btn-primary:hover:not(:disabled) {
    background: #1d4ed8;
  }

  .btn-secondary {
    background: var(--bg-surface);
    border-color: var(--border-color);
    color: var(--text-primary);
  }

  .btn-secondary:hover:not(:disabled) {
    background: var(--bg-subtle);
  }

  .btn-ghost {
    background: transparent;
    color: var(--text-muted);
  }

  .btn-ghost:hover:not(:disabled) {
    background: var(--bg-subtle);
    color: var(--text-primary);
  }

  .btn-danger {
    background: #dc2626;
    color: #ffffff;
  }

  .btn-danger:hover:not(:disabled) {
    background: #b91c1c;
  }

  .btn-link {
    background: none;
    border: none;
    color: inherit;
    text-decoration: underline;
    cursor: pointer;
    font-size: 0.85rem;
    flex-shrink: 0;
  }

  .alert {
    padding: 0.65rem 0.85rem;
    border-radius: 0.5rem;
    font-size: 0.875rem;
    word-break: break-word;
  }

  .alert-error {
    background: var(--error-bg);
    color: var(--error-text);
    border: 1px solid var(--error-border);
  }

  .alert-success {
    background: var(--pill-bg);
    color: var(--pill-text);
    border: 1px solid var(--border-color);
  }

  .banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
  }

  .modal-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(2, 6, 23, 0.6);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1rem;
    z-index: 1000;
  }

  .modal {
    background: var(--bg-surface);
    border: 1px solid var(--border-subtle);
    border-radius: 0.75rem;
    width: 100%;
    max-width: 520px;
    max-height: 90vh;
    overflow-y: auto;
    padding: 1.5rem;
    box-shadow: var(--shadow-modal);
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }

  .modal-wide {
    max-width: 600px;
  }

  .modal-backdrop-nested {
    z-index: 1100;
  }

  .modal-compact {
    max-width: 440px;
  }

  .scope-prompt {
    margin: 0;
    font-size: 0.9rem;
    line-height: 1.5;
    color: var(--text-secondary);
  }

  .scope-options {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
  }

  .scope-option {
    display: flex;
    align-items: flex-start;
    gap: 0.7rem;
    padding: 0.75rem 0.85rem;
    border-radius: 0.55rem;
    border: 1px solid var(--border-subtle);
    background: var(--bg-page);
    cursor: pointer;
    transition: border-color 0.15s ease, background 0.15s ease;
  }

  .scope-option:hover {
    border-color: var(--border-color);
  }

  .scope-option-active {
    border-color: #3b82f6;
    background: rgba(59, 130, 246, 0.08);
  }

  .scope-option input[type='radio'] {
    margin-top: 0.2rem;
    accent-color: #3b82f6;
    cursor: pointer;
  }

  .scope-option-body {
    display: flex;
    flex-direction: column;
    gap: 0.2rem;
  }

  .scope-option-title {
    font-size: 0.9rem;
    font-weight: 600;
    color: var(--text-primary);
  }

  .scope-option-desc {
    font-size: 0.8rem;
    line-height: 1.4;
    color: var(--text-muted);
  }

  .modal-header {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 1rem;
  }

  .modal-header h2 {
    margin: 0;
    font-size: 1.2rem;
    color: var(--text-primary);
  }

  .detail-calendar-badge {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    margin-top: 0.3rem;
    font-size: 0.8rem;
    color: var(--text-muted);
  }

  .readonly-tag {
    font-size: 0.7rem;
    padding: 0.1rem 0.45rem;
    border-radius: 999px;
    background: var(--bg-subtle);
    color: var(--text-secondary);
  }

  .close-btn {
    background: none;
    border: none;
    font-size: 1.5rem;
    line-height: 1;
    color: var(--text-muted);
    cursor: pointer;
  }

  .sub-list {
    display: flex;
    flex-direction: column;
    gap: 0.5rem;
  }

  .sub-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
    padding: 0.6rem 0.75rem;
    border-radius: 0.5rem;
    background: var(--bg-page);
    border: 1px solid var(--border-subtle);
  }

  .sub-item-primary {
    flex-direction: column;
    align-items: stretch;
  }

  .sub-item-top {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
  }

  .publish-box {
    margin-top: 0.25rem;
    padding-top: 0.6rem;
    border-top: 1px solid var(--border-subtle);
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
  }

  .publish-box-label {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
    font-size: 0.78rem;
    color: var(--text-secondary);
    font-weight: 500;
  }

  .publish-url-row {
    display: flex;
    align-items: center;
    gap: 0.45rem;
  }

  .publish-url-input {
    flex: 1;
    padding: 0.35rem 0.55rem;
    font-size: 0.78rem;
    font-family: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace;
    background: var(--bg-surface);
    border: 1px solid var(--border-color);
    border-radius: 0.375rem;
    color: var(--text-primary);
  }

  .publish-hint {
    font-size: 0.75rem;
    color: var(--text-muted);
    line-height: 1.4;
  }

  .sub-item-left {
    display: flex;
    align-items: center;
    gap: 0.65rem;
    min-width: 0;
  }

  .sub-item-name {
    font-size: 0.9rem;
    font-weight: 600;
    color: var(--text-primary);
  }

  .sub-item-meta {
    font-size: 0.75rem;
    color: var(--text-muted);
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    max-width: 360px;
  }

  .color-picker-inline {
    width: 1.5rem;
    height: 1.5rem;
    padding: 0;
    border: none;
    border-radius: 0.25rem;
    background: transparent;
    cursor: pointer;
    flex-shrink: 0;
  }

  .modal-divider {
    border: none;
    border-top: 1px solid var(--border-subtle);
    margin: 0.25rem 0;
  }

  .sub-form-heading {
    margin: 0;
    font-size: 1rem;
    color: var(--text-primary);
  }

  .sub-help-text {
    margin: 0;
    font-size: 0.8rem;
    color: var(--text-muted);
    line-height: 1.45;
  }

  .field-color {
    flex: 0 0 auto;
  }

  .color-swatches {
    display: flex;
    align-items: center;
    gap: 0.4rem;
    height: 2.25rem;
  }

  .swatch-btn {
    width: 1.65rem;
    height: 1.65rem;
    border-radius: 999px;
    border: 2px solid transparent;
    cursor: pointer;
    transition: transform 0.1s ease, border-color 0.1s ease;
  }

  .swatch-active {
    border-color: var(--text-primary);
    transform: scale(1.12);
  }

  .modal-form {
    display: flex;
    flex-direction: column;
    gap: 0.9rem;
  }

  .field {
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
    font-size: 0.875rem;
    color: var(--text-secondary);
    flex: 1;
  }

  .field span {
    font-weight: 500;
  }

  .field input,
  .field textarea,
  .select-input {
    width: 100%;
    box-sizing: border-box;
    padding: 0.55rem 0.7rem;
    background: var(--bg-page);
    border: 1px solid var(--border-color);
    border-radius: 0.45rem;
    font-size: 0.925rem;
    font-family: inherit;
    color: var(--text-primary);
  }

  .field input:focus,
  .field textarea:focus,
  .select-input:focus {
    outline: none;
    border-color: #3b82f6;
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.25);
  }

  .btn-notif-active {
    border-color: #3b82f6;
  }

  .notif-panel {
    display: flex;
    flex-direction: column;
    gap: 0.95rem;
  }

  .notif-toggle-row {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
    padding: 0.75rem 0.85rem;
    border-radius: 0.5rem;
    background: var(--bg-page);
    border: 1px solid var(--border-subtle);
  }

  .field-row {
    display: flex;
    gap: 0.75rem;
    flex-wrap: wrap;
  }

  .checkbox-field {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    font-size: 0.9rem;
    color: var(--text-primary);
    cursor: pointer;
    user-select: none;
  }

  .modal-actions {
    display: flex;
    justify-content: flex-end;
    gap: 0.5rem;
    margin-top: 0.5rem;
  }

  .modal-actions-split {
    justify-content: space-between;
  }

  .modal-actions-right {
    display: flex;
    gap: 0.5rem;
  }

  .event-details {
    display: flex;
    flex-direction: column;
    gap: 0.65rem;
    font-size: 0.925rem;
    color: var(--text-secondary);
  }

  .detail-row {
    display: flex;
    gap: 0.5rem;
    flex-wrap: wrap;
  }

  .zoom-link {
    color: var(--link-color);
    word-break: break-all;
  }

  .mapquest-detail-link {
    display: inline-flex;
    align-items: center;
    gap: 0.4rem;
    flex-wrap: wrap;
    word-break: normal;
    text-decoration: none;
  }

  .mapquest-detail-link:hover {
    text-decoration: underline;
  }

  .mapquest-tag {
    font-size: 0.72rem;
    font-weight: 600;
    padding: 0.1rem 0.45rem;
    border-radius: 999px;
    background: var(--pill-bg);
    color: var(--pill-text);
    text-decoration: none;
  }

  .location-mapquest-preview {
    margin-top: 0.15rem;
  }

  .mapquest-inline-link {
    font-size: 0.78rem;
    color: var(--link-color);
    text-decoration: none;
  }

  .mapquest-inline-link:hover {
    text-decoration: underline;
  }

  .detail-description pre {
    margin: 0.4rem 0 0;
    padding: 0.75rem;
    background: var(--bg-page);
    border: 1px solid var(--border-subtle);
    border-radius: 0.45rem;
    white-space: pre-wrap;
    word-break: break-word;
    font-family: inherit;
    font-size: 0.875rem;
    color: var(--text-secondary);
  }

  .field-hint {
    font-weight: 400;
    color: var(--text-muted);
    font-size: 0.78rem;
    margin-left: 0.25rem;
  }

  .attendee-field {
    position: relative;
  }

  .attendee-chips {
    display: flex;
    flex-wrap: wrap;
    gap: 0.4rem;
    margin-bottom: 0.2rem;
  }

  .attendee-chip {
    display: inline-flex;
    align-items: center;
    gap: 0.35rem;
    padding: 0.22rem 0.55rem;
    border-radius: 999px;
    background: var(--pill-bg);
    color: var(--pill-text);
    font-size: 0.78rem;
    border: 1px solid var(--border-subtle);
  }

  .attendee-chip-remove {
    background: none;
    border: none;
    color: inherit;
    font-size: 0.95rem;
    line-height: 1;
    cursor: pointer;
    padding: 0 0.1rem;
    opacity: 0.75;
  }

  .attendee-chip-remove:hover {
    opacity: 1;
  }

  .attendee-input-wrapper {
    position: relative;
    width: 100%;
  }

  .attendee-input-row {
    display: flex;
    align-items: center;
    gap: 0.45rem;
  }

  .attendee-input-row input {
    flex: 1;
  }

  .contact-suggestions {
    position: absolute;
    top: calc(100% + 0.25rem);
    left: 0;
    right: 0;
    margin: 0;
    padding: 0.3rem;
    list-style: none;
    background: var(--bg-surface);
    border: 1px solid var(--border-color);
    border-radius: 0.5rem;
    box-shadow: var(--shadow-modal);
    z-index: 30;
    max-height: 210px;
    overflow-y: auto;
  }

  .contact-suggestion-btn {
    width: 100%;
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.75rem;
    padding: 0.45rem 0.6rem;
    border: none;
    border-radius: 0.375rem;
    background: transparent;
    color: var(--text-primary);
    text-align: left;
    cursor: pointer;
    font-size: 0.84rem;
  }

  .contact-suggestion-btn:hover,
  .contact-suggestion-active {
    background: var(--bg-subtle);
  }

  .contact-suggestion-name {
    font-weight: 600;
    color: var(--text-primary);
    overflow: hidden;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .contact-suggestion-email {
    font-size: 0.78rem;
    color: var(--text-muted);
    flex-shrink: 0;
  }

  .detail-attendees {
    display: flex;
    flex-direction: column;
    gap: 0.4rem;
  }

  .detail-attendee-list {
    margin: 0;
    padding: 0;
    list-style: none;
    display: flex;
    flex-direction: column;
    gap: 0.35rem;
  }

  .detail-attendee-item {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 0.5rem;
    padding: 0.4rem 0.65rem;
    border-radius: 0.45rem;
    background: var(--bg-page);
    border: 1px solid var(--border-subtle);
    font-size: 0.84rem;
  }

  .detail-attendee-info {
    display: flex;
    align-items: center;
    gap: 0.35rem;
    flex-wrap: wrap;
    min-width: 0;
  }

  .detail-attendee-name {
    font-weight: 500;
    color: var(--text-primary);
  }

  .detail-attendee-email {
    color: var(--text-muted);
    font-size: 0.78rem;
  }

  .attendee-status-badge {
    font-size: 0.72rem;
    font-weight: 600;
    padding: 0.12rem 0.5rem;
    border-radius: 999px;
    background: var(--bg-subtle);
    color: var(--text-secondary);
    flex-shrink: 0;
  }

  .status-accepted {
    background: rgba(16, 185, 129, 0.16);
    color: #10b981;
  }

  .status-declined {
    background: rgba(239, 68, 68, 0.16);
    color: #ef4444;
  }

  .status-tentative {
    background: rgba(245, 158, 11, 0.16);
    color: #f59e0b;
  }

  .status-needs-action {
    background: rgba(59, 130, 246, 0.14);
    color: #3b82f6;
  }

  .attendee-chip-status {
    font-size: 0.68rem;
    font-weight: 600;
    padding: 0.08rem 0.4rem;
    border-radius: 999px;
  }

  .attendee-pending-note {
    margin-left: 0;
    margin-bottom: 0.15rem;
    display: block;
  }

  .version-corner {
    position: fixed;
    bottom: 0.65rem;
    right: 0.85rem;
    font-size: 0.75rem;
    font-weight: 600;
    letter-spacing: 0.04em;
    color: var(--text-muted);
    background: var(--bg-surface);
    border: 1px solid var(--border-subtle);
    padding: 0.18rem 0.55rem;
    border-radius: 999px;
    opacity: 0.75;
    pointer-events: none;
    z-index: 50;
  }
</style>
