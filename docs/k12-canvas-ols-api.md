# K12 / Stride — Canvas and OLS API notes

Observed against a live Indiana Digital Learning School (`indls`) student
account on 2026-08-06. Everything here is **structure only** — no student data
is recorded in this file.

Two separate systems back the student experience, and they answer different
questions:

| System | Host | Auth | Answers |
| --- | --- | --- | --- |
| Canvas (Instructure) | `learn2.k12.com` | Canvas API token **or** session cookie | assignments, due dates, grades |
| OLS "Launch Pad" | `home.k12.com` | session cookie only | **class meeting times**, attendance, join links |
| SSO gateway | `security-gateway.k12.com` | — | `/security-gateway/sso-gateway-v2` |

The single most important finding: **class times do not exist in Canvas at this
school.** `/api/v1/calendar_events?type=event` returns zero rows and the planner
never emits `calendar_event`. Anything that answers "what time is my class" or
"is today a day off" has to come from OLS.

## Canvas — `learn2.k12.com`

Standard Canvas REST API. `Authorization: Bearer <token>`, or same-origin
session cookies in a web view.

### `/api/v1/users/self/profile`
```
id, name, short_name, sortable_name, primary_email, login_id, time_zone, ...
```
`login_id` is the **student number, and it is also the OLS `userId`** — this is
the join key between the two systems.

### `/api/v1/courses?enrollment_state=active&include[]=total_scores&per_page=50`
Array of courses. Grades live on the enrollment:
```
enrollments[0]: type, role, enrollment_state,
                computed_current_score        (Double, e.g. 92.4)
                computed_current_grade        (String)
                computed_current_letter_grade (String)   ← prefer this
                computed_final_score, computed_final_grade
```

### `/api/v1/planner/items?start_date=YYYY-MM-DD&end_date=YYYY-MM-DD&per_page=100`
The best single endpoint for "what do I owe".
```
context_type, course_id, plannable_id, plannable_type, plannable_date,
planner_override, new_activity, html_url, context_name, context_image,
submissions: { submitted, excused, graded, posted_at,
               late, missing, needs_grading, has_feedback, redo_request }
plannable (assignment): id, title, created_at, updated_at,
                        points_possible, due_at, lock_at
```
`plannable_type` observed: `assignment`, `quiz`, `announcement`.
**Never `calendar_event`.**

### `/api/v1/users/self/missing_submissions`
Returns **empty** for this school even without filters — it is not populated
here. Derive late/missing from planner `submissions.missing` / `.late` instead.

## OLS — `home.k12.com`

A React app calling its own JSON API with the session cookie. `userId` is the
Canvas `login_id`.

### `/api/canvas/events/classes` — **no parameters**
The best endpoint in the portal: it takes **no query string at all** and
resolves the student from the session cookie, returning *today's* meetings.
```
{ ok, count, events: [ {
    id, title, url,
    startAt (ISO8601, UTC), endAt (ISO8601, UTC),
    localDay ("YYYY-MM-DD", school-local),
    time ("1:30 PM", school-local, preformatted),
    courseId, courseName, teacherName,
    occurrenceId, schoolId, isNative,
    platform ("Engageli"), invitationType ("Classroom"),
    attendance: "required" | "optional" | "do-not-display"
} ] }
```
Verified: returns 5 events for a weekday, all with `localDay` = today.
Because it needs no student id, it is the one call a widget can make.

### `/api/canvas/events?userId={id}&courseIds={csv}`
The full calendar (587 events for one student), for week/month views.
```
{ ok, userId, count, range, events: [ {
    id, title, url,
    startAt (ISO8601), endAt (ISO8601), time (preformatted string), end,
    course, courseId,
    status: "upcoming" | "live" | "ended",
    isToday (Bool), isSoon (Bool),
    attendance: "required" | "optional" | "do-not-display",
    hasJoinLink (Bool), isNativeClassEvent, isNative,
    occurrenceId, schoolId, description, tooltip, kind: "calendar"
} ] }
```
`isToday` answers "classes today vs day off" directly; `status` gives
live/upcoming/ended; `hasJoinLink` + `url` opens the live session.

### `/api/canvas/assignments?coursesIds={csv}&userId={id}`
```
{ ok, userId, count, assignments: [ {
    id, code, courseId, url, tooltip,
    dueAt (ISO8601), primaryDate (ISO8601),
    status (String), submitted (Bool), isQuizAssignment (Bool)
} ] }
```

### `/api/courses/{userId}`
```
{ success, studentId, data: [ Canvas-shaped course + grade, teacherName,
                              teachers[], sections[], enrollment, term ] }
```

### Other endpoints seen
```
/api/profile?userId=
/api/schoolProfile?mainSchoolId=
/api/classconnect/student/recordings?occurrenceId=&schoolId=
/api/canvas/nextbestaction?userId=
/api/widgets
/api/weather?zip=
/api/feature-flags/evaluate
```

## Full OLS route list

Extracted from the portal's own JS bundles (51 assets, ~2 MB):
```
/api/auth                              /api/planner/notes  (+ /{id})
/api/canvas/assignments                /api/profile?userId=
/api/canvas/assignments/completion     /api/quicklinks
/api/canvas/events                     /api/schoolProfile?mainSchoolId=
/api/canvas/events/classes             /api/student/{id}/year-wrapped
/api/canvas/events/{id}/past           /api/weather  /api/weather/forecast
/api/canvas/nextbestaction             /api/widgets
/api/canvas/oauth/start                /api/feature-flags/evaluate
/api/canvas/recommendations/{boost,continue,stay-on-track}
/api/classconnect                      /api/coach/{profile,timezone,weather}
/api/classconnect/student/recordings
/api/courses/{userId}
```
`/api/auth` returns HTML, not JSON. `/api/canvas/assignments/completion`
requires `userId`, `courseId`, **and** `assignmentId` — it's per-assignment,
not a summary.

`/api/schoolProfile?mainSchoolId=` returns `schoolName, schoolAbbr, schoolCity,
schoolState, schoolZip, schoolTimezone, schoolStartDate, schoolEndDate,
nextYearStartDate, school_canvas_id, school_instance_id`.

## How Status Board authenticates

The portal issues no API token, so a web view appears exactly **once**, as a
sign-in sheet (`K12SignInView`) — the same role an OAuth sheet plays. On
completion the `k12.com` cookies are copied out of the web view into
`K12Session`'s own cookie jar, persisted in the **Keychain**, and every request
after that is a native `URLSession` call. Panels never embed a web view, which
is what makes this usable from widgets and background refreshes.

An expired session is detected by the portal answering with `text/html` (its
login page) instead of JSON — the session flips to `.expired` and the panel
says so rather than showing stale or empty data.

## What this means for Status Board

- **Assignments and grades** → Canvas panel with an API token. Fully native, no
  browser needed, works on every platform.
- **Class times / day-off / attendance** → OLS via `K12Session`: sign in once,
  then native `URLSession` calls. Today's schedule is one parameter-free
  request; week views resolve the student id and course ids first.
- Apple TV and Watch can't run the sign-in sheet, so they receive the resulting
  data through iCloud sync or the Mac bridge.
