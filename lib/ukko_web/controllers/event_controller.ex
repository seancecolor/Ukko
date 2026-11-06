defmodule UkkoWeb.EventController do
  use UkkoWeb, :controller

  alias Ukko.{CalDAV, ICal, Zoom}

  @doc """
  GET /api/events?start=ISO8601&end=ISO8601
  """
  def index(conn, params) do
    start_iso = Map.get(params, "start")
    end_iso = Map.get(params, "end")

    case CalDAV.list_events(start_iso, end_iso) do
      {:ok, events} ->
        conn
        |> put_status(:ok)
        |> json(events)

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
