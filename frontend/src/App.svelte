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

  // Create / Edit Event modal state
  let showEventModal = false;
  let editingUid = null;
  let savingEvent = false;
  let formError = '';
  let eventForm = {
    title: '',
    start: '',
    end: '',
    all_day: false,
    location: '',
    description: '',
    create_zoom: false
  };

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
      await tick();
      initCalendar();
      fetchSubscriptions();
      startNotificationTimers();
    } catch (err) {
      authError = 'Could not reach server. Please try again.';
    } finally {
      authLoading = false;
    }
  }

  function handleLogout() {
    token = '';
    authenticated = false;
    localStorage.removeItem(TOKEN_KEY);
    stopNotificationTimers();
    destroyCalendar();
  }

  async function fetchEvents(rangeStart, rangeEnd) {
    if (!authenticated) return;
    loadingEvents = true;
    bannerError = '';

    const startParam = rangeStart || currentRange.start;
    const endParam = rangeEnd || currentRange.end;

    const params = new URLSearchParams();
    if (startParam) params.set('start', new Date(startParam).toISOString());
    if (endParam) params.set('end', new Date(endParam).toISOString());

    try {
      const query = params.toString();
      const url = query ? `/api/events?${query}` : '/api/events';
      const res = await fetch(url, {
        method: 'GET',
        credentials: 'same-origin',
        headers: authHeaders({ Accept: 'application/json' })
      });

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

      events = Array.isArray(data)
        ? data.map((ev) => {
            const allDay = isEventAllDay(ev);
            const rawStart = ev.start;
            const rawEnd = ev.end || ev.start;
            const bgColor = ev.backgroundColor || ev.color || ev.extendedProps?.color;
            const readOnly = Boolean(ev.readOnly || ev.extendedProps?.readOnly);
            const calendarName =
              ev.calendarName || ev.extendedProps?.calendarName || 'Ukko Calendar';

            const mapped = {
              id: ev.id || ev.uid,
              title: ev.title || '(No Title)',
              allDay,
              start: allDay ? String(rawStart).slice(0, 10) : parseTimedDate(rawStart),
              end: allDay ? String(rawEnd).slice(0, 10) : parseTimedDate(rawEnd),
              extendedProps: {
                uid: ev.uid || ev.id,
                allDay,
                description: ev.description ?? ev.extendedProps?.description ?? '',
                location: ev.location ?? ev.extendedProps?.location ?? '',
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
          })
        : [];

      if (calendar) {
        calendar.setOption('events', events);
      }
      checkUpcomingNotifications();
    } catch (err) {
      bannerError = 'Network error while fetching calendar events.';
    } finally {
      loadingEvents = false;
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
      await fetchEvents();
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
      await fetchEvents();
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
        await fetchEvents();
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
        await fetchEvents();
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
        await fetchEvents();
      }
    } catch {
      // ignore
    }
  }

  // --- Create / Edit / Delete Events ---

  function openCreateModal(startDate, endDate, allDay = false) {
    const now = new Date();
    now.setMinutes(0, 0, 0);
    now.setHours(now.getHours() + 1);

    const start = startDate ? new Date(startDate) : now;
    const end = endDate
      ? new Date(endDate)
      : new Date(start.getTime() + 60 * 60 * 1000);

    editingUid = null;
    eventForm = {
      title: '',
      start: toLocalInputValue(start),
      end: toLocalInputValue(end),
      all_day: Boolean(allDay),
      location: '',
      description: '',
      create_zoom: false
    };
    formError = '';
    showEventModal = true;
  }

  function openEditModal(ev) {
    if (!ev || ev.readOnly) return;
    editingUid = ev.uid;
    eventForm = {
      title: ev.title || '',
      start: toLocalInputValue(ev.start),
      end: toLocalInputValue(ev.end || ev.start),
      all_day: Boolean(ev.allDay),
      location: ev.location || '',
      description: ev.description || '',
      create_zoom: false
    };
    formError = '';
    selectedEvent = null;
    showEventModal = true;
  }

  function closeEventModal() {
    if (savingEvent) return;
    showEventModal = false;
    editingUid = null;
    formError = '';
  }

  async function handleSaveEvent(e) {
    e.preventDefault();
    formError = '';

    if (!eventForm.title.trim() || !eventForm.start) {
      formError = 'Title and start time are required.';
      return;
    }

    savingEvent = true;

    try {
      const isAllDay = Boolean(eventForm.all_day);
      let startVal = localInputToIso(eventForm.start, isAllDay);
      let endVal = localInputToIso(eventForm.end || eventForm.start, isAllDay);

      if (isAllDay && startVal === endVal) {
        const [y, m, d] = startVal.split('-').map(Number);
        const nextDay = new Date(Date.UTC(y, m - 1, d + 1));
        endVal = nextDay.toISOString().slice(0, 10);
      }

      const payload = {
        title: eventForm.title.trim(),
        start: startVal,
        end: endVal,
        location: eventForm.location.trim(),
        description: eventForm.description.trim(),
        create_zoom: Boolean(eventForm.create_zoom)
      };

      const isEdit = Boolean(editingUid);
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
      await fetchEvents();
    } catch (err) {
      formError = 'Network error while saving event.';
    } finally {
      savingEvent = false;
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
      location: ecEvent.extendedProps?.location || '',
      description: ecEvent.extendedProps?.description || '',
      readOnly: Boolean(ecEvent.extendedProps?.readOnly),
      calendarName: ecEvent.extendedProps?.calendarName || 'Ukko Calendar',
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
      await fetchEvents();
    } catch (err) {
      deleteError = 'Network error while deleting event.';
    } finally {
      deletingEvent = false;
    }
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
      const n = new Notification('Ukko Calendar — Test Notification', {
        body: `Desktop reminders are active (${notificationSettings.leadMinutes} min before events).`,
        icon: '/apple-touch-icon.png',
        badge: '/favicon.png',
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
    if (ev.extendedProps?.calendarName && ev.extendedProps.calendarName !== 'Ukko Calendar') {
      lines.push(`Calendar: ${ev.extendedProps.calendarName}`);
    }
    if (ev.extendedProps?.location) {
      lines.push(`Location: ${ev.extendedProps.location}`);
    }

    try {
      const n = new Notification(ev.title || '(No Title)', {
        body: lines.join('\n'),
        icon: '/apple-touch-icon.png',
        badge: '/favicon.png',
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
        fetchEvents();
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
          selectable: true,
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
    if (authenticated) {
      initCalendar();
      fetchSubscriptions();
      startNotificationTimers();
    }
  });

  onDestroy(() => {
    stopNotificationTimers();
    destroyCalendar();
  });
</script>

{#if !authenticated}
  <main class="auth-screen">
    <form class="auth-card" on:submit={handleLogin}>
      <div class="auth-header-row">
        <div class="auth-header">
          <div class="logo-lockup logo-lockup-auth" aria-label="Ukko Cal">
            <svg class="logo-mark-svg" viewBox="130 110 764 680" role="img" aria-hidden="true">
              <defs>
                <mask id="ukko-auth-mark-mask">
                  <image href="/logo.jpg" width="1024" height="1024" />
                </mask>
              </defs>
              <rect
                x="0"
                y="0"
                width="1024"
                height="1024"
                fill="currentColor"
                mask="url(#ukko-auth-mark-mask)"
              />
            </svg>
            <span class="logo-wordmark">UKKO <span class="logo-wordmark-accent">CAL</span></span>
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
        <div class="logo-lockup" aria-label="Ukko Cal">
          <svg class="logo-mark-svg" viewBox="130 110 764 680" role="img" aria-hidden="true">
            <defs>
              <mask id="ukko-header-mark-mask">
                <image href="/logo.jpg" width="1024" height="1024" />
              </mask>
            </defs>
            <rect
              x="0"
              y="0"
              width="1024"
              height="1024"
              fill="currentColor"
              mask="url(#ukko-header-mark-mask)"
            />
          </svg>
          <span class="logo-wordmark">UKKO <span class="logo-wordmark-accent">CAL</span></span>
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
          on:click={() => fetchEvents()}
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
          <span>Ukko Calendar</span>
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
                  <div class="sub-item-name">Ukko Calendar (Primary)</div>
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

          <label class="field">
            <span>
              Location {eventForm.create_zoom ? '(will be replaced with Zoom Join URL)' : ''}
            </span>
            <input
              type="text"
              bind:value={eventForm.location}
              placeholder={eventForm.create_zoom ? 'Zoom link generated automatically' : 'Room / URL'}
              disabled={savingEvent || eventForm.create_zoom}
            />
          </label>

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
              <span>{selectedEvent.calendarName || 'Ukko Calendar'}</span>
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
                <span>{selectedEvent.location}</span>
              {/if}
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
            >
              {deletingEvent ? 'Deleting...' : 'Delete Event'}
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
{/if}

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

  .logo-lockup .logo-mark-svg {
    height: 2.35rem;
    width: auto;
    display: block;
    flex-shrink: 0;
  }

  .logo-wordmark {
    font-size: 1.45rem;
    font-weight: 900;
    letter-spacing: 0.14em;
    line-height: 1;
    color: var(--text-primary);
    text-transform: uppercase;
  }

  .logo-wordmark-accent {
    color: #3b82f6;
  }

  .logo-lockup-auth .logo-mark-svg {
    height: 2.6rem;
  }

  .logo-lockup-auth .logo-wordmark {
    font-size: 1.55rem;
  }

  .container {
    max-width: 1280px;
    width: 100%;
    margin: 0 auto;
    padding: 1.25rem 1.5rem;
    flex: 1;
    display: flex;
    flex-direction: column;
    gap: 0.85rem;
  }

  .header {
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
    flex: 1;
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
</style>
