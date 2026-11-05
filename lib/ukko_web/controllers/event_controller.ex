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
        |> json(%{error: "Failed to fetch CalDAV events", details: inspect(reason)})
    end
  end

  @doc """
  POST /api/events
  Accepts `{ title, start, end, description, location, create_zoom: boolean }`.
  """
  def create(conn, params) do
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
      uid = ICal.generate_uid()

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
            description: enriched_attrs.description,
            location: enriched_attrs.location
          }
        }

        conn
        |> put_status(:created)
        |> json(event_response)
      else
        {:error, {:zoom_error, reason}} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{error: "Failed to create Zoom meeting", details: inspect(reason)})

        {:error, reason} ->
          conn
          |> put_status(:bad_gateway)
          |> json(%{error: "Failed to save event to CalDAV", details: inspect(reason)})
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
        |> json(%{error: "Failed to delete event from CalDAV", details: inspect(reason)})
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

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(1), do: true
  defp truthy?("1"), do: true
  defp truthy?(_), do: false
end
