defmodule Ukko.ICalTest do
  use ExUnit.Case, async: true

  alias Ukko.{CalDAV, CardDAV, ICal, MapQuest, Zoom}

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

  test "extracts Zoom meeting ID from location URL or description block" do
    assert Zoom.extract_meeting_id("https://us06web.zoom.us/j/81234567890?pwd=abc", "") ==
             "81234567890"

    assert Zoom.extract_meeting_id("", "--- Zoom Meeting ---\nMeeting ID: 898 7654 3210\n") ==
             "89876543210"

    assert Zoom.extract_meeting_id("Conference Room B", "Regular team sync") == nil
  end

  test "parses MapQuest Search Ahead predictions and round-trips locationUrl in ICal" do
    raw_results = [
      %{
        "displayString" => "1600 Pennsylvania Ave, Charleston, WV 25302, United States",
        "name" => "1600 Pennsylvania Ave",
        "recordType" => "address",
        "slug" => "/us/wv/charleston/25302-3932/1600-pennsylvania-ave-38.36025,-81.62115"
      }
    ]

    assert [
             %{
               display: "1600 Pennsylvania Ave, Charleston, WV 25302, United States",
               type: "address",
               url:
                 "https://www.mapquest.com/us/wv/charleston/25302-3932/1600-pennsylvania-ave-38.36025,-81.62115"
             }
           ] = MapQuest.parse_prediction_results(raw_results)

    ics =
      ICal.build_ics(%{
        uid: "mq-evt-1",
        title: "Coffee Meetup",
        start: "2026-11-12T18:00:00Z",
        end: "2026-11-12T19:00:00Z",
        location: "1600 Pennsylvania Ave, Charleston, WV 25302",
        location_url:
          "https://www.mapquest.com/us/wv/charleston/25302-3932/1600-pennsylvania-ave-38.36025,-81.62115"
      })

    assert [event] = ICal.parse_vevents(ics)
    assert event.location == "1600 Pennsylvania Ave, Charleston, WV 25302"

    assert event.locationUrl ==
             "https://www.mapquest.com/us/wv/charleston/25302-3932/1600-pennsylvania-ave-38.36025,-81.62115"

    # CalDAV servers (like Stalwart) re-serialize default TEXT X-* properties with escaped commas (\,).
    # Verify that escaped commas and previously browser-normalized `/,` coordinate paths heal cleanly.
    stalwart_escaped_ics = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:mq-evt-escaped
    DTSTART:20261112T180000Z
    DTEND:20261112T190000Z
    SUMMARY:Montebello Event
    LOCATION:509 Work St\\, Montebello\\, CA 90640-4948
    X-UKKO-LOCATION-URL:https://www.mapquest.com/us/ca/montebello/90640-4948/509-work-st-34.00752\\,-118.12667
    END:VEVENT
    END:VCALENDAR
    """

    assert [escaped_ev] = ICal.parse_vevents(stalwart_escaped_ics)

    assert escaped_ev.locationUrl ==
             "https://www.mapquest.com/us/ca/montebello/90640-4948/509-work-st-34.00752,-118.12667"

    corrupted_slash_ics = """
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:mq-evt-slash
    DTSTART:20261112T180000Z
    DTEND:20261112T190000Z
    SUMMARY:Montebello Event
    LOCATION:509 Work St\\, Montebello\\, CA 90640-4948
    X-UKKO-LOCATION-URL:https://www.mapquest.com/us/ca/montebello/90640-4948/509-work-st-34.00752/,-118.12667
    END:VEVENT
    END:VCALENDAR
    """

    assert [healed_ev] = ICal.parse_vevents(corrupted_slash_ics)

    assert healed_ev.locationUrl ==
             "https://www.mapquest.com/us/ca/montebello/90640-4948/509-work-st-34.00752,-118.12667"
  end
end
