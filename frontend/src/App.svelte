<script>
  import { onMount, onDestroy, tick } from 'svelte';
  import Calendar from '@event-calendar/core';
  import DayGrid from '@event-calendar/day-grid';
  import TimeGrid from '@event-calendar/time-grid';
  import Interaction from '@event-calendar/interaction';
  import '@event-calendar/core/index.css';

  const TOKEN_KEY = 'ukko_auth_token';

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

  // Create Event modal state
  let showCreateModal = false;
  let creatingEvent = false;
  let createError = '';
  let newEvent = {
    title: '',
    start: '',
    end: '',
    location: '',
    description: '',
    create_zoom: false
  };

  // Event Details / Delete modal state
  let selectedEvent = null;
  let deletingEvent = false;
  let deleteError = '';

  function authHeaders(extra = {}) {
    const headers = { ...extra };
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
    }
    return headers;
  }

  function toLocalInputValue(date) {
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

  function localInputToIso(value) {
    if (!value) return null;
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return value;
    return d.toISOString();
  }

  function formatDateTime(value) {
    if (!value) return '';
    const d = value instanceof Date ? value : new Date(value);
    if (Number.isNaN(d.getTime())) return String(value);
    return d.toLocaleString(undefined, {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      year: 'numeric',
      hour: 'numeric',
      minute: '2-digit'
    });
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
        authError = data.error || 'Invalid passcode';
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

      const data = await res.json().catch(() => []);
      if (!res.ok) {
        bannerError = data.error || 'Failed to load calendar events.';
        return;
      }

      events = Array.isArray(data)
        ? data.map((ev) => ({
            id: ev.id || ev.uid,
            title: ev.title || '(No Title)',
            start: ev.start,
            end: ev.end || ev.start,
            extendedProps: {
              uid: ev.uid || ev.id,
              description: ev.description ?? ev.extendedProps?.description ?? '',
              location: ev.location ?? ev.extendedProps?.location ?? ''
            }
          }))
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

  function openCreateModal(startDate, endDate) {
    const now = new Date();
    now.setMinutes(0, 0, 0);
    now.setHours(now.getHours() + 1);

    const start = startDate ? new Date(startDate) : now;
    const end = endDate
      ? new Date(endDate)
      : new Date(start.getTime() + 60 * 60 * 1000);

    newEvent = {
      title: '',
      start: toLocalInputValue(start),
      end: toLocalInputValue(end),
      location: '',
      description: '',
      create_zoom: false
    };
    createError = '';
    showCreateModal = true;
  }

  function closeCreateModal() {
    if (creatingEvent) return;
    showCreateModal = false;
    createError = '';
  }

  async function handleCreateEvent(e) {
    e.preventDefault();
    createError = '';

    if (!newEvent.title.trim() || !newEvent.start) {
      createError = 'Title and start time are required.';
      return;
    }

    creatingEvent = true;

    try {
      const payload = {
        title: newEvent.title.trim(),
        start: localInputToIso(newEvent.start),
        end: localInputToIso(newEvent.end || newEvent.start),
        location: newEvent.location.trim(),
        description: newEvent.description.trim(),
        create_zoom: Boolean(newEvent.create_zoom)
      };

      const res = await fetch('/api/events', {
        method: 'POST',
        credentials: 'same-origin',
        headers: authHeaders({
          'Content-Type': 'application/json',
          Accept: 'application/json'
        }),
        body: JSON.stringify(payload)
      });

      if (res.status === 401) {
        showCreateModal = false;
        handleLogout();
        authError = 'Session expired. Please enter your passcode.';
        return;
      }

      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        createError = data.error || 'Failed to create event.';
        return;
      }

      showCreateModal = false;
      await fetchEvents();
    } catch (err) {
      createError = 'Network error while creating event.';
    } finally {
      creatingEvent = false;
    }
  }

  function openEventDetails(ecEvent) {
    const uid = ecEvent.extendedProps?.uid || ecEvent.id;
    selectedEvent = {
      uid,
      title: ecEvent.title,
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
        deleteError = data.error || 'Failed to delete event.';
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
            openCreateModal(info.start, info.end);
          },
          dateClick: (info) => {
            const start = info.date;
            const end = new Date(start.getTime() + 60 * 60 * 1000);
            openCreateModal(start, end);
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
      <div class="auth-header">
        <h1>Ukko Calendar</h1>
        <p>Enter your passcode to access your Thundermail calendar.</p>
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
        <h1>Ukko Calendar</h1>
        {#if loadingEvents}
          <span class="status-pill">Syncing CalDAV...</span>
        {/if}
      </div>

      <div class="header-actions">
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

    <div class="calendar-wrapper" bind:this={calendarEl}></div>
  </main>

  {#if showCreateModal}
    <div class="modal-backdrop" on:click|self={closeCreateModal} role="presentation">
      <div class="modal" role="dialog" aria-modal="true" aria-labelledby="create-modal-title">
        <div class="modal-header">
          <h2 id="create-modal-title">New Calendar Event</h2>
          <button type="button" class="close-btn" on:click={closeCreateModal} aria-label="Close">
            &times;
          </button>
        </div>

        {#if createError}
          <div class="alert alert-error">{createError}</div>
        {/if}

        <form on:submit={handleCreateEvent} class="modal-form">
          <label class="field">
            <span>Title *</span>
            <input
              type="text"
              bind:value={newEvent.title}
              placeholder="Team Sync"
              required
              disabled={creatingEvent}
            />
          </label>

          <div class="field-row">
            <label class="field">
              <span>Start *</span>
              <input
                type="datetime-local"
                bind:value={newEvent.start}
                required
                disabled={creatingEvent}
              />
            </label>

            <label class="field">
              <span>End *</span>
              <input
                type="datetime-local"
                bind:value={newEvent.end}
                required
                disabled={creatingEvent}
              />
            </label>
          </div>

          <label class="checkbox-field">
            <input
              type="checkbox"
              bind:checked={newEvent.create_zoom}
              disabled={creatingEvent}
            />
            <span>Automatically create Zoom meeting</span>
          </label>

          <label class="field">
            <span>Location {newEvent.create_zoom ? '(will be replaced with Zoom Join URL)' : ''}</span>
            <input
              type="text"
              bind:value={newEvent.location}
              placeholder={newEvent.create_zoom ? 'Zoom link generated automatically' : 'Room / URL'}
              disabled={creatingEvent || newEvent.create_zoom}
            />
          </label>

          <label class="field">
            <span>Description</span>
            <textarea
              rows="4"
              bind:value={newEvent.description}
              placeholder="Agenda or notes..."
              disabled={creatingEvent}
            ></textarea>
          </label>

          <div class="modal-actions">
            <button
              type="button"
              class="btn btn-secondary"
              on:click={closeCreateModal}
              disabled={creatingEvent}
            >
              Cancel
            </button>
            <button type="submit" class="btn btn-primary" disabled={creatingEvent}>
              {#if creatingEvent}
                {newEvent.create_zoom ? 'Creating Zoom & Saving...' : 'Saving...'}
              {:else}
                Save Event
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
            <span>{formatDateTime(selectedEvent.start)}</span>
          </div>
          {#if selectedEvent.end}
            <div class="detail-row">
              <strong>Ends:</strong>
              <span>{formatDateTime(selectedEvent.end)}</span>
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
    background: #ffffff;
    border-radius: 0.75rem;
    padding: 2rem;
    width: 100%;
    max-width: 400px;
    box-shadow: 0 10px 25px rgba(15, 23, 42, 0.08);
    display: flex;
    flex-direction: column;
    gap: 1.25rem;
  }

  .auth-header h1 {
    margin: 0 0 0.25rem;
    font-size: 1.5rem;
    color: #0f172a;
  }

  .auth-header p {
    margin: 0;
    color: #64748b;
    font-size: 0.925rem;
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
    gap: 0.75rem;
  }

  .header h1 {
    margin: 0;
    font-size: 1.5rem;
    color: #0f172a;
  }

  .status-pill {
    font-size: 0.8rem;
    background: #e0f2fe;
    color: #0369a1;
    padding: 0.2rem 0.65rem;
    border-radius: 999px;
    font-weight: 500;
  }

  .header-actions {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .calendar-wrapper {
    background: #ffffff;
    border-radius: 0.75rem;
    padding: 1rem;
    box-shadow: 0 1px 3px rgba(15, 23, 42, 0.08);
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
    transition: background-color 0.15s ease, border-color 0.15s ease;
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
    background: #ffffff;
    border-color: #cbd5e1;
    color: #1e293b;
  }

  .btn-secondary:hover:not(:disabled) {
    background: #f1f5f9;
  }

  .btn-ghost {
    background: transparent;
    color: #64748b;
  }

  .btn-ghost:hover:not(:disabled) {
    background: #e2e8f0;
    color: #0f172a;
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
  }

  .alert {
    padding: 0.65rem 0.85rem;
    border-radius: 0.5rem;
    font-size: 0.875rem;
  }

  .alert-error {
    background: #fef2f2;
    color: #b91c1c;
    border: 1px solid #fecaca;
  }

  .banner {
    display: flex;
    align-items: center;
    justify-content: space-between;
  }

  .modal-backdrop {
    position: fixed;
    inset: 0;
    background: rgba(15, 23, 42, 0.45);
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 1rem;
    z-index: 1000;
  }

  .modal {
    background: #ffffff;
    border-radius: 0.75rem;
    width: 100%;
    max-width: 520px;
    padding: 1.5rem;
    box-shadow: 0 20px 35px rgba(15, 23, 42, 0.2);
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
    color: #0f172a;
  }

  .close-btn {
    background: none;
    border: none;
    font-size: 1.5rem;
    line-height: 1;
    color: #64748b;
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
    color: #334155;
    flex: 1;
  }

  .field span {
    font-weight: 500;
  }

  .field input,
  .field textarea {
    padding: 0.55rem 0.7rem;
    border: 1px solid #cbd5e1;
    border-radius: 0.45rem;
    font-size: 0.925rem;
    font-family: inherit;
    color: #0f172a;
  }

  .field input:focus,
  .field textarea:focus {
    outline: none;
    border-color: #2563eb;
    box-shadow: 0 0 0 2px rgba(37, 99, 235, 0.15);
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
    color: #1e293b;
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

  .event-details {
    display: flex;
    flex-direction: column;
    gap: 0.65rem;
    font-size: 0.925rem;
  }

  .detail-row {
    display: flex;
    gap: 0.5rem;
    flex-wrap: wrap;
  }

  .zoom-link {
    color: #2563eb;
    word-break: break-all;
  }

  .detail-description pre {
    margin: 0.4rem 0 0;
    padding: 0.75rem;
    background: #f8fafc;
    border: 1px solid #e2e8f0;
    border-radius: 0.45rem;
    white-space: pre-wrap;
    word-break: break-word;
    font-family: inherit;
    font-size: 0.875rem;
    color: #334155;
  }
</style>
