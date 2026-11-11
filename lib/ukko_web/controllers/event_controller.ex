defmodule UkkoWeb.EventController do
  use UkkoWeb, :controller

  alias Ukko.{CalDAV, CardDAV, ICal, MapQuest, Subscriptions, Zoom}

  @doc """
  GET /api/events?start=ISO8601&end=ISO8601
  """
  def index(conn, params) do
    start_iso = Map.get(params, "start")
    end_iso = Map.get(params, "end")

    caldav_task = Task.async(fn -> CalDAV.list_events(start_iso, end_iso) end)
    sub_events = Subscriptions.fetch_events(start_iso, end_iso)

    case Task.await(caldav_task, 45_000) do
      {:ok, events} ->
        conn
        |> put_status(:ok)
        |> json(events ++ sub_events)

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{
          error: "Failed to fetch CalDAV events",
          details: format_reason(reason)
        })
    end
  end

  @doc """
  POST /api/events
  Accepts `{ title, start, end, description, location, create_zoom: boolean }`.
  """
  def create(conn, params) do
    save_event(conn, ICal.generate_uid(), params, :created)
  end

  @doc """
  PUT /api/events/:uid
  Updates an existing event on CalDAV (and optionally attaches a Zoom meeting).
  """
  def update(conn, %{"uid" => uid} = params) do
    save_event(conn, uid, params, :ok)
  end

  @doc """
  POST /api/events/import
  Accepts `{ "ics": "<raw .ics text>" }` or `{ "ics_list": ["<raw .ics>", ...] }`.
  """
  def import_ics(conn, params) do
    ics_payloads =
      cond do
        is_list(Map.get(params, "ics_list")) ->
          Enum.filter(Map.get(params, "ics_list"), &is_binary/1)

        is_binary(Map.get(params, "ics")) ->
          [Map.get(params, "ics")]

        true ->
          []
      end

    if ics_payloads == [] do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "No .ics content provided"})
    else
      combined_ics = Enum.join(ics_payloads, "\r\n")

      case CalDAV.import_ics(combined_ics) do
        {:ok, imported_events} ->
          conn
          |> put_status(:created)
          |> json(%{
            imported: length(imported_events),
            events: imported_events
          })

        {:error, :no_events_found} ->
          conn
          |> put_status(:unprocessable_entity)
          |> json(%{error: "No valid VEVENT entries found in the .ics file"})

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{
            error: "Failed to import .ics file to CalDAV",
            details: format_reason(reason)
          })
      end
    end
  end

  @doc """
  GET /api/subscriptions
  """
  def list_subscriptions(conn, _params) do
    subs = Subscriptions.list_subscriptions()

    conn
    |> put_status(:ok)
    |> json(subs)
  end

  @doc """
  POST /api/subscriptions
  Accepts `{ "name": "Nicole's Calendar", "url": "https://...", "color": "#9333ea" }`.
  """
  def create_subscription(conn, params) do
    case Subscriptions.add_subscription(params) do
      {:ok, sub} ->
        conn
        |> put_status(:created)
        |> json(sub)

      {:error, reason} when is_binary(reason) ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: reason})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to add calendar subscription", details: format_reason(reason)})
    end
  end

  @doc """
  PUT /api/subscriptions/:id
  """
  def update_subscription(conn, %{"id" => id} = params) do
    case Subscriptions.update_subscription(id, params) do
      {:ok, sub} ->
        conn
        |> put_status(:ok)
        |> json(sub)

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Subscription not found"})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{error: "Failed to update subscription", details: format_reason(reason)})
    end
  end

  @doc """
  DELETE /api/subscriptions/:id
  """
  def delete_subscription(conn, %{"id" => id}) do
    :ok = Subscriptions.delete_subscription(id)

    conn
    |> put_status(:ok)
    |> json(%{deleted: true, id: id})
  end

  @doc """
  GET /api/feed-token
  Returns the secret token for the user's published `.ics` feed.
  """
  def get_feed_token(conn, _params) do
    token = Subscriptions.get_feed_token()

    conn
    |> put_status(:ok)
    |> json(%{token: token})
  end

  @doc """
  POST /api/feed-token/rotate
  Generates and persists a new secret `.ics` feed token.
  """
  def rotate_feed_token(conn, _params) do
    {:ok, token} = Subscriptions.rotate_feed_token()

    conn
    |> put_status(:ok)
    |> json(%{token: token})
  end

  @doc """
  GET /api/contacts
  Fetches contacts from the user's Thundermail CardDAV addressbook for attendee autocomplete.
  """
  def list_contacts(conn, _params) do
    case CardDAV.list_contacts() do
      {:ok, contacts} ->
        conn
        |> put_status(:ok)
        |> json(contacts)

      {:error, _reason} ->
        conn
        |> put_status(:ok)
        |> json([])
    end
  end

  @doc """
  GET /api/locations/autocomplete?q=...
  Queries MapQuest Search Ahead API for live address / POI autocomplete suggestions.
  """
  def autocomplete_locations(conn, params) do
    query = Map.get(params, "q") || ""

    case MapQuest.autocomplete(query) do
      {:ok, suggestions} ->
        conn
        |> put_status(:ok)
        |> json(suggestions)

      {:error, _reason} ->
        conn
        |> put_status(:ok)
        |> json([])
    end
  end

  defp save_event(conn, uid, params, success_status) do
    title = Map.get(params, "title")
    start_iso = Map.get(params, "start")
    end_iso = Map.get(params, "end") || start_iso
    description = Map.get(params, "description") || ""
    location = Map.get(params, "location") || ""
    raw_location_url = Map.get(params, "location_url")
    rrule = Map.get(params, "rrule")
    timezone = Map.get(params, "timezone")
    edit_scope = Map.get(params, "edit_scope")
    recurrence_id = Map.get(params, "recurrence_id") || Map.get(params, "occurrence_start")
    attendees = ICal.normalize_attendees(Map.get(params, "attendees") || [])
    create_zoom = truthy?(Map.get(params, "create_zoom", false))

    if is_nil(title) or String.trim(to_string(title)) == "" or is_nil(start_iso) do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "title and start are required"})
    else
      base_attrs = %{
        uid: uid,
        title: String.trim(to_string(title)),
        start: start_iso,
        end: end_iso,
        description: description,
        location: location,
        location_url: MapQuest.resolve_location_url(location, raw_location_url),
        rrule: rrule,
        timezone: timezone,
        attendees: attendees
      }

      is_update = success_status == :ok
      sync_zoom_on_update = is_update and edit_scope != "single"

      with {:ok, enriched_attrs} <- maybe_sync_zoom(base_attrs, create_zoom, sync_zoom_on_update),
           {:ok, saved_uid, final_attendees} <-
             persist_event_save(uid, enriched_attrs, is_update, edit_scope, recurrence_id) do
        is_rec =
          is_binary(enriched_attrs[:rrule]) and String.trim(enriched_attrs[:rrule]) != "" and
            edit_scope != "single"

        event_response = %{
          id: saved_uid,
          uid: saved_uid,
          title: enriched_attrs.title,
          start: enriched_attrs.start,
          end: enriched_attrs.end,
          description: enriched_attrs.description,
          location: enriched_attrs.location,
          locationUrl: enriched_attrs.location_url,
          isRecurring: is_rec,
          rrule: enriched_attrs[:rrule] || "",
          attendees: final_attendees,
          extendedProps: %{
            uid: saved_uid,
            description: enriched_attrs.description,
            location: enriched_attrs.location,
            locationUrl: enriched_attrs.location_url,
            isRecurring: is_rec,
            rrule: enriched_attrs[:rrule] || "",
            attendees: final_attendees
          }
        }

        conn
        |> put_status(success_status)
        |> json(event_response)
      else
        {:error, {:zoom_error, reason}} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{
            error: "Failed to create Zoom meeting",
            details: format_reason(reason)
          })

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{
            error: "Failed to save event to CalDAV",
            details: format_reason(reason)
          })
      end
    end
  end

  defp persist_event_save(uid, enriched_attrs, true, edit_scope, recurrence_id)
       when edit_scope in ["single", "following"] do
    case CalDAV.get_event_resource(uid) do
      {:ok, %{url: resource_url, ics: raw_ics}} ->
        case ICal.apply_recurring_edit(raw_ics, edit_scope, recurrence_id, enriched_attrs) do
          {:single_put, updated_ics, final_attendees} ->
            case CalDAV.put_raw_ics_to_url(resource_url, updated_ics) do
              :ok -> {:ok, uid, final_attendees}
              {:error, reason} -> {:error, reason}
            end

          {:split_put, truncated_ics, new_uid, new_series_ics, final_attendees} ->
            with :ok <- CalDAV.put_raw_ics_to_url(resource_url, truncated_ics),
                  {:ok, ^new_uid} <- CalDAV.put_raw_ics(new_uid, new_series_ics) do
              {:ok, new_uid, final_attendees}
            end
        end

      {:error, :not_found} ->
        final_attendees = ICal.reset_attendees_to_pending(enriched_attrs.attendees)
        updated_attrs = %{enriched_attrs | attendees: final_attendees}

        case CalDAV.put_event(updated_attrs) do
          {:ok, saved_uid} -> {:ok, saved_uid, final_attendees}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_event_save(uid, enriched_attrs, true, _edit_scope, _recurrence_id) do
    case CalDAV.get_event_resource(uid) do
      {:ok, %{url: resource_url, ics: raw_ics}} ->
        {ics_payload, final_attendees} = ICal.prepare_single_event_update(raw_ics, enriched_attrs)

        case CalDAV.put_raw_ics_to_url(resource_url, ics_payload) do
          :ok -> {:ok, uid, final_attendees}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        final_attendees = ICal.reset_attendees_to_pending(enriched_attrs.attendees)
        updated_attrs = %{enriched_attrs | attendees: final_attendees}

        case CalDAV.put_event(updated_attrs) do
          {:ok, saved_uid} -> {:ok, saved_uid, final_attendees}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp persist_event_save(_uid, enriched_attrs, false, _edit_scope, _recurrence_id) do
    final_attendees = ICal.reset_attendees_to_pending(enriched_attrs.attendees)
    new_attrs = %{enriched_attrs | attendees: final_attendees}

    case CalDAV.put_event(new_attrs) do
      {:ok, saved_uid} -> {:ok, saved_uid, final_attendees}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  DELETE /api/events/:uid
  Supports optional `scope` (`"single"` | `"following"` | `"all"`) and `recurrence_id` query params
  when deleting occurrences of a recurring event.
  """
  def delete(conn, %{"uid" => uid} = params) do
    scope = Map.get(params, "scope")
    recurrence_id = Map.get(params, "recurrence_id")

    result =
      if scope in ["single", "following"] do
        delete_recurring_occurrence(uid, scope, recurrence_id)
      else
        maybe_cancel_attached_zoom(uid)
        CalDAV.delete_event(uid)
      end

    case result do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{deleted: true, uid: uid, scope: scope || "all"})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{
          error: "Failed to delete event from CalDAV",
          details: format_reason(reason)
        })
    end
  end

  defp delete_recurring_occurrence(uid, scope, recurrence_id) do
    case CalDAV.get_event_resource(uid) do
      {:ok, %{url: resource_url, ics: raw_ics}} ->
        case ICal.apply_recurring_delete(raw_ics, scope, recurrence_id) do
          {:single_put, updated_ics} ->
            CalDAV.put_raw_ics_to_url(resource_url, updated_ics)

          :delete_all ->
            maybe_cancel_attached_zoom(uid)
            CalDAV.delete_event(uid)
        end

      {:error, :not_found} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_cancel_attached_zoom(uid) do
    case CalDAV.get_raw_ics(uid) do
      {:ok, raw_ics} ->
        case ICal.parse_vevents(raw_ics) do
          [ev | _] ->
            case Zoom.extract_meeting_id(ev.location, ev.description) do
              nil -> :ok
              meeting_id -> _ = Zoom.delete_meeting(meeting_id)
            end

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp maybe_sync_zoom(attrs, true, _is_update) do
    case Zoom.create_meeting(attrs) do
      {:ok, %{join_url: join_url} = meeting} ->
        updated_description = Zoom.append_meeting_details(attrs.description, meeting)

        {:ok,
         %{
           attrs
           | location: join_url || attrs.location,
             location_url: nil,
             description: updated_description
         }}

      {:error, reason} ->
        {:error, {:zoom_error, reason}}
    end
  end

  defp maybe_sync_zoom(attrs, false, true) do
    case Zoom.extract_meeting_id(attrs.location, attrs.description) do
      nil ->
        {:ok, attrs}

      meeting_id ->
        # Sync updated start_time, duration, and topic to the existing Zoom meeting
        _ = Zoom.update_meeting(meeting_id, attrs)
        {:ok, attrs}
    end
  end

  defp maybe_sync_zoom(attrs, false, false), do: {:ok, attrs}

  defp format_reason(:missing_caldav_credentials) do
    "Missing THUNDERMAIL_CALDAV_URL, THUNDERMAIL_USER, or THUNDERMAIL_PASS environment variable."
  end

  defp format_reason(:missing_zoom_credentials) do
    "Missing ZOOM_ACCOUNT_ID, ZOOM_CLIENT_ID, or ZOOM_CLIENT_SECRET environment variable."
  end

  defp format_reason({:caldav_error, 401, _body}) do
    "CalDAV returned 401 Unauthorized — check THUNDERMAIL_USER and THUNDERMAIL_PASS (Thundermail requires an App Password for CalDAV if 2FA/SSO is used)."
  end

  defp format_reason({:caldav_error, 403, _body}) do
    "CalDAV returned 403 Forbidden — check calendar permissions and THUNDERMAIL_CALDAV_URL."
  end

  defp format_reason({:caldav_error, 404, _body}) do
    "CalDAV returned 404 Not Found — verify THUNDERMAIL_CALDAV_URL points to the calendar collection."
  end

  defp format_reason({:caldav_error, status, body}) do
    "CalDAV HTTP #{status}: #{inspect(body)}"
  end

  defp format_reason({:exception, msg}) do
    msg
  end

  defp format_reason(other) do
    inspect(other)
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false
end
