<script>
  import { onMount, onDestroy, tick } from 'svelte';
  import Calendar from '@event-calendar/core';
  import DayGrid from '@event-calendar/day-grid';
  import TimeGrid from '@event-calendar/time-grid';
  import Interaction from '@event-calendar/interaction';
  import '@event-calendar/core/index.css';

  const TOKEN_KEY = 'ukko_auth_token';
  const THEME_KEY = 'ukko_theme';

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
  let currentRange = { start: null, end: null };

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
    const e = typeof ev.end === 'string' ? ev.end.trim() : s;
    if (s.length === 10) return true;
    if (
      s !== e &&
      (s.endsWith('T00:00:00Z') || s.endsWith('T00:00:00')) &&
      (e.endsWith('T00:00:00Z') || e.endsWith('T00:00:00'))
    ) {
      return true;
    }
    return false;
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

            return {
              id: ev.id || ev.uid,
              title: ev.title || '(No Title)',
              allDay,
              start: allDay ? String(rawStart).slice(0, 10) : parseTimedDate(rawStart),
              end: allDay ? String(rawEnd).slice(0, 10) : parseTimedDate(rawEnd),
              extendedProps: {
                uid: ev.uid || ev.id,
                allDay,
                description: ev.description ?? ev.extendedProps?.description ?? '',
                location: ev.location ?? ev.extendedProps?.location ?? ''
              }
            };
          })
        : [];

      if (calendar) {
        calendar.setOption('events', events);
      }
    } catch (err) {
      bannerError = 'Network error while fetching calendar events.';
    } finally {
      loadingEvents = false;
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
    if (!ev) return;
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
      description: ecEvent.extendedProps?.description || ''
    };
    deleteError = '';
  }

  function closeEventDetails() {
    if (deletingEvent) return;
    selectedEvent = null;
    deleteError = '';
  }

  async function handleDeleteEvent() {
    if (!selectedEvent?.uid) return;
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
    if (authenticated) {
      initCalendar();
    }
  });

  onDestroy(() => {
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
        {#if loadingEvents}
          <span class="status-pill">Syncing CalDAV...</span>
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

    {#if bannerError}
      <div class="alert alert-error banner">
        <span>{bannerError}</span>
        <button type="button" class="btn-link" on:click={() => (bannerError = '')}>Dismiss</button>
      </div>
    {/if}

    <div
      class="calendar-wrapper"
      class:ec-dark={darkMode}
      bind:this={calendarEl}
    ></div>
  </main>

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
          <h2 id="detail-modal-title">{selectedEvent.title}</h2>
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

        <div class="modal-actions modal-actions-split">
          <button
            type="button"
            class="btn btn-danger"
            on:click={handleDeleteEvent}
            disabled={deletingEvent}
          >
            {deletingEvent ? 'Deleting...' : 'Delete Event'}
          </button>
          <div class="modal-actions-right">
            <button
              type="button"
              class="btn btn-primary"
              on:click={() => openEditModal(selectedEvent)}
              disabled={deletingEvent}
            >
              Edit Event
            </button>
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
{/if}

<style>
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
    gap: 1rem;
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
    padding: 1.5rem;
    box-shadow: var(--shadow-modal);
    display: flex;
    flex-direction: column;
    gap: 1rem;
  }

  .modal-header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 1rem;
  }

  .modal-header h2 {
    margin: 0;
    font-size: 1.2rem;
    color: var(--text-primary);
  }

  .close-btn {
    background: none;
    border: none;
    font-size: 1.5rem;
    line-height: 1;
    color: var(--text-muted);
    cursor: pointer;
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
  .field textarea {
    padding: 0.55rem 0.7rem;
    background: var(--bg-page);
    border: 1px solid var(--border-color);
    border-radius: 0.45rem;
    font-size: 0.925rem;
    font-family: inherit;
    color: var(--text-primary);
  }

  .field input:focus,
  .field textarea:focus {
    outline: none;
    border-color: #3b82f6;
    box-shadow: 0 0 0 2px rgba(59, 130, 246, 0.25);
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
