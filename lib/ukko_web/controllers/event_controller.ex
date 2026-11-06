defmodule UkkoWeb.EventController do
  use UkkoWeb, :controller

  alias Ukko.{CalDAV, ICal, Subscriptions, Zoom}

  @doc """
  GET /api/events?start=ISO8601&end=ISO8601
  """
  def index(conn, params) do
    start_iso = Map.get(params, "start")
    end_iso = Map.get(params, "end")

    caldav_task = Task.async(fn -> CalDAV.list_events(start_iso, end_iso) end)
    sub_events = Subscriptions.fetch_events(start_iso, end_iso)

    case Task.await(caldav_task, 20_000) do
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

  defp save_event(conn, uid, params, success_status) do
    title = Map.get(params, "title")
    start_iso = Map.get(params, "start")
    end_iso = Map.get(params, "end") || start_iso
    description = Map.get(params, "description") || ""
    location = Map.get(params, "location") || ""
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
        location: location
      }

      with {:ok, enriched_attrs} <- maybe_attach_zoom(base_attrs, create_zoom),
           {:ok, ^uid} <- CalDAV.put_event(enriched_attrs) do
        event_response = %{
          id: uid,
          uid: uid,
          title: enriched_attrs.title,
          start: enriched_attrs.start,
          end: enriched_attrs.end,
          description: enriched_attrs.description,
          location: enriched_attrs.location,
          extendedProps: %{
            uid: uid,
            description: enriched_attrs.description,
            location: enriched_attrs.location
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

  @doc """
  DELETE /api/events/:uid
  """
  def delete(conn, %{"uid" => uid}) do
    case CalDAV.delete_event(uid) do
      :ok ->
        conn
        |> put_status(:ok)
        |> json(%{deleted: true, uid: uid})

      {:error, reason} ->
        conn
        |> put_status(:bad_gateway)
        |> json(%{
          error: "Failed to delete event from CalDAV",
          details: format_reason(reason)
        })
    end
  end

  defp maybe_attach_zoom(attrs, false), do: {:ok, attrs}

  defp maybe_attach_zoom(attrs, true) do
    case Zoom.create_meeting(attrs) do
      {:ok, %{join_url: join_url} = meeting} ->
        updated_description = Zoom.append_meeting_details(attrs.description, meeting)

        {:ok,
         %{
           attrs
           | location: join_url || attrs.location,
             description: updated_description
         }}

      {:error, reason} ->
        {:error, {:zoom_error, reason}}
    end
  end

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
