defmodule Ukko.ICalTest do
  use ExUnit.Case, async: true

  alias Ukko.{CalDAV, ICal}

  test "builds and parses a VEVENT payload round-trip" do
    uid = ICal.generate_uid()

    ics =
      ICal.build_ics(%{
        uid: uid,
        title: "Team Sync, Q4",
        start: "2026-11-05T15:00:00Z",
        end: "2026-11-05T15:30:00Z",
        description: "Line 1\nLine 2",
        location: "https://zoom.us/j/123456789"
      })

    assert [event] = ICal.parse_vevents(ics)
    assert event.uid == uid
    assert event.id == "#{uid}::2026-11-05T15:00:00Z"
    assert event.title == "Team Sync, Q4"
    assert event.start == "2026-11-05T15:00:00Z"
    assert event.end == "2026-11-05T15:30:00Z"
    assert event.description == "Line 1\nLine 2"
    assert event.location == "https://zoom.us/j/123456789"
  end

  test "parses CalDAV multistatus XML response with CDATA, ALTREP, and VALARM" do
    xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
      <d:response>
        <d:href>/dav/cal/user/default/evt-1.ics</d:href>
        <d:propstat>
          <d:prop>
            <d:getetag>"12345"</d:getetag>
            <cal:calendar-data><![CDATA[BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:evt-1
    DTSTART:20261106T100000Z
    DTEND:20261106T110000Z
    SUMMARY:Design Review
    DESCRIPTION;ALTREP="data:text/html;base64,abc=":Review mockups
    LOCATION:Room 101
    BEGIN:VALARM
    ACTION:DISPLAY
    DESCRIPTION:Alarm description should be ignored
    END:VALARM
    END:VEVENT
    END:VCALENDAR]]></cal:calendar-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    assert [event] = CalDAV.parse_multistatus_response(xml)
    assert event.uid == "evt-1"
    assert event.title == "Design Review"
    assert event.start == "2026-11-06T10:00:00Z"
    assert event.end == "2026-11-06T11:00:00Z"
    assert event.description == "Review mockups"
    assert event.location == "Room 101"
  end
end
