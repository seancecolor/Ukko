defmodule Ukko.ICalTest do
  use ExUnit.Case, async: true

  alias Ukko.{CalDAV, CardDAV, ICal}

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

  test "converts TZID=\"GMT-08:00\" invited events to proper UTC timestamps" do
    ics = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VTIMEZONE
    TZID:GMT-08:00
    BEGIN:STANDARD
    TZOFFSETFROM:-0800
    TZOFFSETTO:-0800
    DTSTART:19700101T000000
    END:STANDARD
    END:VTIMEZONE
    BEGIN:VEVENT
    UID:1B84EB66-2C07-423D-8FE4-592A2FFBA30B
    SUMMARY:Samsung Microwave Repair Service
    DTSTART;TZID="GMT-08:00":20261106T130000
    DTEND;TZID="GMT-08:00":20261106T160000
    END:VEVENT
    END:VCALENDAR
    """

    assert [event] = ICal.parse_vevents(ics)
    assert event.title == "Samsung Microwave Repair Service"
    assert event.start == "2026-11-06T21:00:00Z"
    assert event.end == "2026-11-07T00:00:00Z"
    assert event.allDay == false
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

  test "builds and parses VEVENT with organizer and attendees" do
    uid = ICal.generate_uid()

    ics =
      ICal.build_ics(%{
        uid: uid,
        title: "Product Kickoff",
        start: "2026-11-07T18:00:00Z",
        end: "2026-11-07T19:00:00Z",
        organizer_email: "visitantmedia@thundermail.com",
        attendees: [
          %{name: "Nicole", email: "nicole@example.com", status: "ACCEPTED"},
          %{name: "", email: "partner@example.org", status: "NEEDS-ACTION"}
        ]
      })

    assert [event] = ICal.parse_vevents(ics)
    assert event.organizer == %{name: "", email: "visitantmedia@thundermail.com"}

    assert [
             %{name: "Nicole", email: "nicole@example.com", status: "ACCEPTED"},
             %{name: "", email: "partner@example.org", status: "NEEDS-ACTION"}
           ] = Enum.map(event.attendees, &Map.take(&1, [:name, :email, :status]))
  end

  test "parses CardDAV multistatus vCard contacts" do
    xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <d:multistatus xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav">
      <d:response>
        <d:href>/dav/card/visitantmedia%40thundermail.com/default/c1.vcf</d:href>
        <d:propstat>
          <d:prop>
            <card:address-data>BEGIN:VCARD
    VERSION:3.0
    FN:Nicole Visitant
    EMAIL;TYPE=INTERNET:nicole@example.com
    END:VCARD</card:address-data>
          </d:prop>
          <d:status>HTTP/1.1 200 OK</d:status>
        </d:propstat>
      </d:response>
    </d:multistatus>
    """

    assert [%{name: "Nicole Visitant", email: "nicole@example.com"}] =
             CardDAV.parse_multistatus_vcards(xml)
  end
end
