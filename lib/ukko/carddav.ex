defmodule Ukko.CardDAV do
  @moduledoc """
  Thundermail CardDAV client using `Req` and `Ukko.FastCache` for fetching contacts
  and providing fast attendee autocomplete suggestions.
  """

  alias Ukko.FastCache

  @default_carddav_base "https://mail.thundermail.com/dav/card/"
  @contacts_soft_ttl_seconds 900

  @doc """
  Fetches contacts from the user's Thundermail CardDAV addressbook, backed by a 15-minute
  Stale-While-Revalidate ETS cache so `/api/contacts` responds in sub-millisecond time.
  """
  def list_contacts(opts \\ []) do
    force_refresh = Keyword.get(opts, :force_refresh, false)

    FastCache.fetch_swr(
      FastCache.contacts_key(),
      @contacts_soft_ttl_seconds,
      force_refresh,
      &fetch_contacts_uncached/0
    )
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp fetch_contacts_uncached do
    with {:ok, cfg} <- get_config() do
      case Req.request(
             method: "REPORT",
             url: cfg.url,
             auth: {:basic, "#{cfg.user}:#{cfg.pass}"},
             headers: [
               {"depth", "1"},
               {"content-type", "application/xml; charset=utf-8"}
             ],
             body: build_addressbook_query_xml(),
             decode_body: false,
             receive_timeout: 20_000,
             connect_options: [timeout: 10_000]
           ) do
        {:ok, %Req.Response{status: status, body: body}} when status in [200, 207] ->
          contacts = parse_multistatus_vcards(to_string(body))
          {:ok, contacts}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:carddav_error, status, body}}

        {:error, exception} ->
          {:error, exception}
      end
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  @doc """
  Parses a CardDAV `<multistatus>` XML body and extracts all contacts from `<address-data>`.
  """
  def parse_multistatus_vcards(xml_body) when is_binary(xml_body) do
    xml_body
    |> FastCache.extract_xml_tag_bodies("address-data")
    |> Enum.flat_map(&parse_vcards/1)
    |> deduplicate_contacts()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  @doc """
  Parses raw `.vcf` / `VCARD` text (containing one or more `BEGIN:VCARD ... END:VCARD` blocks)
  into a list of `%{name: String.t(), email: String.t()}` maps.
  """
  def parse_vcards(vcard_text) when is_binary(vcard_text) do
    unfolded = String.replace(vcard_text, ~r/\r?\n[ \t]/, "")

    ~r/BEGIN:VCARD\r?\n(.*?)END:VCARD/is
    |> Regex.scan(unfolded, capture: :all_but_first)
    |> Enum.flat_map(fn [block] -> parse_single_vcard(block) end)
    |> deduplicate_contacts()
  end

  defp parse_single_vcard(block) do
    lines = String.split(block, ~r/\r?\n/, trim: true)

    {fn_name, structured_name, org_name, emails} =
      Enum.reduce(lines, {nil, nil, nil, []}, fn line, {fn_acc, n_acc, org_acc, emails_acc} ->
        case String.split(line, ":", parts: 2) do
          [raw_key, raw_val] ->
            prop_name =
              raw_key
              |> String.split(";")
              |> List.first()
              |> String.replace(~r/^item\d+\./i, "")
              |> String.upcase()
              |> String.trim()

            val = clean_vcard_value(raw_val)

            cond do
              prop_name == "FN" and val != "" ->
                {fn_acc || val, n_acc, org_acc, emails_acc}

              prop_name == "N" and val != "" ->
                formatted_n = format_structured_name(val)
                {fn_acc, n_acc || formatted_n, org_acc, emails_acc}

              prop_name == "ORG" and val != "" ->
                clean_org = val |> String.split(";") |> Enum.reject(&(&1 == "")) |> Enum.join(" ")
                {fn_acc, n_acc, org_acc || clean_org, emails_acc}

              prop_name == "EMAIL" and val != "" ->
                clean_email =
                  val
                  |> String.replace(~r/^mailto:/i, "")
                  |> String.trim()

                if String.contains?(clean_email, "@") do
                  {fn_acc, n_acc, org_acc, emails_acc ++ [clean_email]}
                else
                  {fn_acc, n_acc, org_acc, emails_acc}
                end

              true ->
                {fn_acc, n_acc, org_acc, emails_acc}
            end

          _ ->
            {fn_acc, n_acc, org_acc, emails_acc}
        end
      end)

    display_name =
      cond do
        is_binary(fn_name) and fn_name != "" -> fn_name
        is_binary(structured_name) and structured_name != "" -> structured_name
        is_binary(org_name) and org_name != "" -> org_name
        true -> ""
      end

    Enum.map(emails, fn email ->
      name =
        if display_name == "" or String.downcase(display_name) == String.downcase(email) do
          email |> String.split("@") |> List.first() || email
        else
          display_name
        end

      %{
        name: name,
        email: email
      }
    end)
  end

  defp format_structured_name(raw_n) do
    parts = String.split(raw_n, ";")
    last = Enum.at(parts, 0, "") |> String.trim()
    first = Enum.at(parts, 1, "") |> String.trim()
    middle = Enum.at(parts, 2, "") |> String.trim()

    [first, middle, last]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
  end

  defp clean_vcard_value(val) when is_binary(val) do
    val
    |> String.trim()
    |> String.replace("\\n", " ")
    |> String.replace("\\N", " ")
    |> String.replace("\\,", ",")
    |> String.replace("\\;", ";")
    |> String.replace("\\\\", "\\")
  end

  @doc """
  Deduplicates a list of `%{name, email}` contacts case-insensitively by email,
  preferring entries that have a full display name.
  """
  def deduplicate_contacts(contacts) when is_list(contacts) do
    contacts
    |> Enum.reduce(%{}, fn contact, acc ->
      email = String.trim(to_string(contact[:email] || contact["email"] || ""))
      name = String.trim(to_string(contact[:name] || contact["name"] || ""))

      if email == "" or not String.contains?(email, "@") do
        acc
      else
        key = String.downcase(email)
        local_part = email |> String.split("@") |> List.first() || ""

        case Map.get(acc, key) do
          nil ->
            Map.put(acc, key, %{name: if(name == "", do: local_part, else: name), email: email})

          existing ->
            if (existing.name == "" or
                  String.downcase(existing.name) == String.downcase(local_part)) and
                 name != "" do
              Map.put(acc, key, %{name: name, email: existing.email})
            else
              acc
            end
        end
      end
    end)
    |> Map.values()
    |> Enum.sort_by(fn c -> {String.downcase(c.name), String.downcase(c.email)} end)
  end

  def build_addressbook_query_xml do
    """
    <?xml version="1.0" encoding="utf-8" ?>
    <C:addressbook-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:carddav">
      <D:prop>
        <D:getetag/>
        <C:address-data/>
      </D:prop>
    </C:addressbook-query>
    """
  end

  @doc """
  Resolves the CardDAV URL and credentials.
  Uses `THUNDERMAIL_CARDDAV_URL` if set, otherwise derives it from `THUNDERMAIL_CALDAV_URL`
  (replacing `/dav/cal/` with `/dav/card/`) or falls back to
  `https://mail.thundermail.com/dav/card/<encoded_user>/default/`.
  """
  def get_config do
    explicit_carddav = non_empty(Application.get_env(:ukko, :thundermail_carddav_url))
    caldav_url = non_empty(Application.get_env(:ukko, :thundermail_caldav_url))
    user = non_empty(Application.get_env(:ukko, :thundermail_user))
    pass = non_empty(Application.get_env(:ukko, :thundermail_pass))

    url =
      cond do
        not is_nil(explicit_carddav) ->
          ensure_trailing_slash(explicit_carddav)

        not is_nil(caldav_url) and String.contains?(caldav_url, "/dav/cal/") ->
          caldav_url
          |> String.replace("/dav/cal/", "/dav/card/")
          |> ensure_trailing_slash()

        not is_nil(user) ->
          encoded_user = URI.encode(user, &URI.char_unreserved?/1)
          "#{@default_carddav_base}#{encoded_user}/default/"

        true ->
          nil
      end

    if is_nil(url) or is_nil(user) or is_nil(pass) do
      {:error, :missing_carddav_credentials}
    else
      {:ok, %{url: url, user: user, pass: pass}}
    end
  end

  defp ensure_trailing_slash(url) when is_binary(url) do
    if String.ends_with?(url, "/"), do: url, else: url <> "/"
  end

  defp non_empty(nil), do: nil

  defp non_empty(str) when is_binary(str) do
    trimmed = String.trim(str)
    if trimmed == "", do: nil, else: trimmed
  end
end

