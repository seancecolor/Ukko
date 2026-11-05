<script>
  import { onMount } from 'svelte';
  import Calendar from '@event-calendar/core';
  import DayGrid from '@event-calendar/day-grid';
  import TimeGrid from '@event-calendar/time-grid';
  import Interaction from '@event-calendar/interaction';
  import '@event-calendar/core/index.css';

  let calendarEl;
  let calendar;

  onMount(() => {
    calendar = new Calendar({
      target: calendarEl,
      props: {
        plugins: [DayGrid, TimeGrid, Interaction],
        options: {
          view: 'timeGridWeek',
          headerToolbar: {
            start: 'prev,next today',
            center: 'title',
            end: 'dayGridMonth,timeGridWeek,timeGridDay'
          },
          events: []
        }
      }
    });

    return () => {
      if (calendar) {
        calendar.destroy();
      }
    };
  });
</script>

<main class="container">
  <header class="header">
    <h1>Ukko Calendar</h1>
  </header>
  <div class="calendar-wrapper" bind:this={calendarEl}></div>
</main>

<style>
  .container {
    max-width: 1280px;
    width: 100%;
    margin: 0 auto;
    padding: 1.5rem;
    flex: 1;
    display: flex;
    flex-direction: column;
  }

  .header {
    display: flex;
    align-items: center;
    justify-content: space-between;
    margin-bottom: 1rem;
  }

  .header h1 {
    margin: 0;
    font-size: 1.5rem;
  }

  .calendar-wrapper {
    background: #ffffff;
    border-radius: 0.5rem;
    padding: 1rem;
    box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
    flex: 1;
  }
</style>

