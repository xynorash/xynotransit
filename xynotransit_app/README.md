# Xynotransit Logistics Report Builder

A Flutter web app that replaces the monthly logistics report chase. It does three jobs:

1. **Form.** Each person (employee) fills in their monthly counts, target answers and notes in their own words, and sends the report.
2. **Overview and live table.** The manager (API role value `controller`) sees a summary dashboard with graphs, and a live table of which reports have arrived.
3. **Slide preview and generator.** The manager turns submitted reports into a 1920x1080 slide deck, scrolls through it as one vertical stream and exports it as PDF, PPTX or a ZIP of PNGs.
4. **Slide text.** The manager chooses the words on the slides (meeting title, date line, organisation name and more). The preview and every export show exactly those words.
5. **People.** The manager builds the catalog in the app: teams, people, seats, and per seat the counts and targets. Nothing is a fixed list.

The UI is split by role. An employee sees only the report form. A manager sees Overview, Reports, Deck text, People and the form.

Stack: Flutter (Dart 3), Riverpod 3, go_router (path URLs, no `#`), package:http. The backend is a separate Rust axum service, see `../xynotransit-api/README.md`. The database and the Docker stack are in `../xynotransit-db/README.md`.

## Roles, screens and routes

| Role (API value) | Home route | What they see |
| --- | --- | --- |
| Employee (`contributor`) | `/report` | Only the report form. No overview, slides, table, People or exports. |
| Manager (`controller`) | `/manager` | Overview, Reports, Deck text, People, and the form (`/report`). |

Routes:

| Route | Who | Screen |
| --- | --- | --- |
| `/signin`, `/auth/verify?token=...` | anyone | Sign in with a username and password, or with a link; the emailed link opens `/auth/verify`. |
| `/account/password` | everyone signed in | Choose a password, change it, or (after a manager's reset) choose a new one. |
| `/report` | everyone signed in | The report form. |
| `/manager` | manager | Overview: the summary dashboard. |
| `/manager/reports` | manager | Reports: slides on one side, "Reports received" table on the other, Generate and Export. |
| `/manager/deck` | manager | Deck text: the words on the slides, with a draft preview. |
| `/manager/people` | manager | People: teams, people, seats, counts and targets. |
| `/gallery` | anyone | Design gallery. |

Redirects (`lib/app/app.dart`):

- `/` and `/signin` go to `/manager` for a manager and to `/report` for everyone else. When signed out, the app shows `/signin`; `/auth/verify` always opens.
- While the person has a temporary password (`must_change_password`), every route redirects to `/account/password`. Nothing else opens until they have chosen their own.
- A non-manager who opens any `/manager...` path (also an unknown sub-path) is sent to `/report`.
- In demo mode, switching the **Demo:** user re-evaluates the redirects.

The top bar shows Overview, Reports, Deck text, People and "Fill in a report" to a manager and marks the current one. A manager gets the compact menu below 900 px; others keep 640 px.

### Employee screen (`/report`)

One column, up to 720 px wide: the form header and the form cards. A manager who arrives from the table sees a "Back to the dashboard" link above the form. The form shows exactly the counts and targets of that seat, 1 to 8 counts, each with a colour dot that matches the bars on the slides.

### Notes and target comments: their own words

There are no suggestion chips. The form has free text only.

- **Notes:** three boxes (the kinds shown on the slides). Each box has 3 point fields. A point is 1 to 70 characters, with a live counter. Empty fields are ignored, order is kept. The 70 character limit keeps every slide from overflowing.
- **Target comment:** under Met, Partly and Missed each target has an optional comment, up to 200 characters, with a counter. A comment typed before a status is picked is kept and joins the status once one is chosen.
- Comments are not on the slides. The manager reads them on the Overview ("What people wrote").

### Overview (`/manager`)

A period picker and four tiles. When reports are missing, a card right under the tiles names who (up to 12 names, then "and N more"). Then the charts. Everything counts submitted reports of expected seats only (see "Who counts" below). Two columns from 1100 px, one below. Every chart has a text alternative with its numbers.

| Section | What it shows | Where the numbers come from |
| --- | --- | --- |
| Tiles | Reports in ("N of M"), Targets met (percent of answered targets), Volume (all counts added), People missing | `expected` is the seats where seat and person are both active, `submitted` the submitted reports of those seats in the period (so `submitted` is never above `expected`). |
| Who has reported | Per team, sent against still missing | `teams[].submitted` and `expected`. |
| How targets went | Per team, met, partly met, missed | The status of every target answer in submitted reports. |
| Volume by month | Per team, the three months of the period | The sum of all counts of a team per month. |
| Biggest counts | The 8 counts with the highest totals (one colour, each bar is named), with a dropdown to look at one count by month and by team | Counts with the same name (ignoring case) are added across seats. |
| Trend over periods | Reports sent and targets met for the shown period and up to 5 earlier ones | `trend`, oldest first. Expected for older periods is the active seats now. |
| People | Table, sortable by header click, people who have not sent first. A search box (name, role, team) and a "Missing only" filter; 100 rows show first, then "Show N more" | `people`, one row per seat. |
| What people wrote | Notes and target comments, 5 shown, "Show all N" for the rest | The free text of submitted reports. |

With no reports in the period the page explains it and shows only "Who has reported" and the People table. The summary reloads when the period changes, and shortly after a report is sent or the catalog changes. Data comes from `GET /api/summary` (see the API README); demo mode computes the same numbers in memory (`lib/domain/summary_compute.dart`).

### Who counts (expected and submitted)

One rule for the API summary, the Dart compute, the tiles, the donut, the team rows, the Reports header and the Generate hint:

- **expected** = active seats of active people.
- **submitted** (tiles, donut, team rows, header) = sent reports of those expected seats only, so submitted is never above expected.
- Sent reports of switched-off seats or people are still real. They are listed in the Reports table, exported in the CSV, included in generated decks, and shown in the Overview people table as rows tagged **Inactive**. They are never expected and never counted as missing.

### Reports (`/manager/reports`)

- At 1100 px wide or more, the slides are on the left and the table column on the right.
  - Left: a pinned header card with the title, **Generate** / **Regenerate**, **Export** (once a deck exists), the meeting date and a jump menu. Below it is one continuous vertical list of every slide in deck order: the cover, then for each team a divider and two slides per person, then one Suggestions page at the very end. A deck of 14 reports and 4 teams has 1 + 4 + 28 + 1 = 34 slides.
  - Right: the Period card and the "Reports received" table, in a column that scrolls on its own.
- The "Reports received" card says "N of M": M is the seats that are expected (the seat and its person are both active, same rule as the Overview tiles and the API) and N the sent reports of those seats, so N is never above M. Reports of switched-off people are real: they stay in the table (tagged **Inactive**, no Edit button), in the CSV and in every generated deck; a line under the progress bar says how many there are ("Not counted above"), and the Generate hint reads "1 of 1 reports in for Feb to Apr 2026, plus 1 from a switched-off person". They are never counted as missing. Who is still missing is listed first, above the table. When one person has two seats the row says "Name · Seat title". When the words a person typed on the form (name, country, role) differ from the profile, a muted line "On the slides: ..." shows them, and the Notes column shows the number of points plus the first note (also as a tooltip). A search box appears from 7 reports. On a phone (under 500 px) each report is a stacked block with all its columns, with no sideways scrolling.
- **Export data (CSV)** (above the table) downloads the sent reports of the shown period as one long table, ready for Excel: columns Period, Team, Person, Role, Seat, Type, Item, Month, Value, Status, Text, Sent at, then Reported name, Reported country, Reported role (the words the person typed on the form, which the slides use; empty on reports sent before those fields existed). Switched-off seats with a sent report are included; they are never listed as Missing. Types: Count (one row per count and month), Target (status and comment), Note, and Missing (a seat with no sent report). UTF-8 with a byte order mark, CRLF lines, quoted cells, a leading apostrophe on text that starts with = + - @ or a tab. File name: `Xynotransit_reports_Feb_to_Apr_2026.csv`.
- Below 1100 px everything is one column: the table column first, then the preview header, then the slides.
- The jump menu is a dropdown plus Previous slide and Next slide buttons.
- The slide list is lazy: only the slides near the screen are built.
- Slide A (counts) lays out 1 to 8 counts: the totals sit 3 to a row up to 6 counts and 4 to a row for 7 and 8 counts, and bars, numbers and labels shrink as the count grows, but no text goes below 20 px (18 px for the value labels of the bars). 1 to 3 counts look as before.
- Slide B (targets): up to 6 targets sit in one column; 7 to 10 targets, and 6 long ones that do not fit, switch to a two-column grid of compact cards. A text that still does not fit ends with an ellipsis (the full text stays in the alt text and notes).
- A cover or divider with more team pills than fit ends with one last pill, "+N more".

### Deck text (`/manager/deck`)

The "Slide text" screen is where the manager writes the words of the deck. Every text a manager may want to change is a field here.

- A period picker at the top. Words are kept **per period**.
- Fields sit in cards by group. Each field has a label, help, a character counter, placeholder chips (press one to insert it), a plain-words error and **Reset** (back to the built-in default). Save is disabled while a field is invalid or nothing changed. **Reset all to defaults** resets every field after a confirmation ("This resets every wording to the built-in text. You can still cancel by not saving." with Reset and Cancel).
- A banner says where the words come from: "These words were carried over from Feb to Apr 2026." or "Built-in words. Nobody has changed them yet."
- On a wide screen a **draft preview** sits beside the form, below it on a narrow one. It renders five slides (cover, one divider, KPI, results, suggestions) with the unsaved words. A field that has an error keeps its saved words in the preview. Without a deck it uses a sample person, labelled "Sample data".
- After Save: "Saved. Regenerate the slides to use these words."

Fields (key, label, limit in characters, allowed placeholders). All are required except where noted.

| Group | Key | Label | Max | Placeholders |
| --- | --- | --- | --- | --- |
| Cover | `title` | Meeting title (also in footer and dividers) | 80 | `{period}` |
| Cover | `subtitle` | Subtitle | 120 | `{period}` |
| Cover | `dateText` | Date line (may be empty) | 60 | none |
| Cover | `orgName` | Organisation name | 40 | none |
| Cover | `coverPill` | Team label on the cover | 60 | `{team}` `{count}` |
| Person slides | `kpiEyebrow` | KPI slide, small line | 120 | `{org}` `{title}` `{period}` `{name}` `{role}` `{team}` |
| Person slides | `kpiTitle` | KPI slide, title | 120 | same six |
| Person slides | `kpiBadge` | KPI slide, badge | 40 | `{met}` `{total}` |
| Person slides | `resultsEyebrow` | Results slide, small line | 120 | same six as KPI |
| Person slides | `resultsTitle` | Results slide, title | 120 | same six |
| Person slides | `highlightsTitle`, `lowlightsTitle`, `nextTitle` | Column titles | 30 | none |
| Person slides | `emptyNote` | Text for an empty column | 40 | none |
| Person slides | `footer` | Footer | 120 | `{title}` `{org}` `{period}` `{team}` |
| Dividers | `dividerEyebrow` | Divider, small line | 120 | `{title}` `{period}` `{i}` `{n}` |
| Dividers | `dividerTitle` | Divider, title | 60 | `{team}` |
| Dividers | `dividerSubtitle` | Divider, line under the title | 120 | `{k}` `{reports}` `{team}` |
| Suggestions | `suggestionsTitle` | Page title | 60 | none |
| Suggestions | `suggestionsBody` | Page text (may be empty, may have line breaks) | 400 | none |

Placeholders are a closed list, all lowercase in braces. A field accepts only the ones in its row; any other is refused with a message such as "{name} cannot be used in Meeting title. It allows {period}." (or "It allows no placeholders.").

| Placeholder | Meaning |
| --- | --- |
| `{org}` | The organisation name field. |
| `{title}` | The meeting title, with its own `{period}` filled in. |
| `{period}` | Period label, for example "Feb to Apr 2026". |
| `{name}` | The person's name. |
| `{role}` | The seat's role title. |
| `{team}` | The team name. |
| `{met}` | Number of targets met on that report. |
| `{total}` | Number of targets of that seat. |
| `{count}` | Number of reports in the team (cover label). |
| `{i}` | Position of the team in the deck, starting at 1. |
| `{n}` | Number of teams. |
| `{k}` | Number of reports in the team (divider). |
| `{reports}` | "report" when `{k}` is 1, else "reports". |

Details:

- **Date line.** When `dateText` is empty the cover shows the meeting date of the period, like `TUESDAY 09 JUNE 2026`, or nothing when the period has no meeting date. When it has words, those words replace the date. The slide shows it in capitals.
- **Carry forward.** A period with no words of its own uses the words of the latest earlier period, else the built-in defaults. Saving in a period gives that period its own words.
- **Defaults.** `docs/reference/deck_text_defaults.json` is the single source of the keys, defaults, placeholders and limits. `DeckTexts.defaults` (`lib/domain/deck_text.dart`) must equal it; a test checks that. The API keeps a byte-identical copy.
- A seat with no targets still shows "KPI · no targets" in the badge, whatever `kpiBadge` says.
- Long words shrink to fit, then end with an ellipsis, so nothing runs out of the 1920x1080 slide.

### Suggestions page

The last slide of every deck is one Suggestions page, after the last team. It is a placeholder: a navy page with the period label, the title, a dashed box with the page text (default "Suggestions will be added here.") and the footer. Real suggestions are future work, not in scope yet. The page is in the preview, the jump menu and all exports (PDF page, PPTX slide, PNG).

### The preview is faithful

What the manager sees is what the exports contain, by construction and by test.

1. **Frozen words and data.** Generate freezes the report data and the effective words (`DeckRun.texts`) into the deck run. The preview and exports read only that frozen deck.
2. **One function draws slides.** `slideFor` (`lib/features/slides/slide_view.dart`) turns a slide spec (which carries the words) into a widget. The preview stream, the draft preview, the PNG and PDF export and the PPTX pictures all call it. Alt text and notes come from `slideAltText` of the same specs.
3. **Tests.** `test/faithful_test.dart` compares preview and export pixels for all 34 slides (a few anti-aliased edge pixels may differ; the test allows at most 1000 pixels and 24 of 255 levels), PPTX alt text and notes, the PNG zip, the PDF (34 pages of 1920x1080), and that changing words later does not change a built deck. `test/deck_text_test.dart` covers rendering, validation and the defaults file. `test/deck_text_ui_test.dart` covers the screen. Goldens in `test/goldens` cover long words and the Suggestions page.

### Stale notice and Regenerate

Editing words never changes a deck that already exists. When the saved words differ from the words frozen in the latest deck, the manager sees "Slide text changed after this deck was generated. Regenerate to apply it." above the **Regenerate slides** button on the Reports page. Press Regenerate to freeze the new words (and the latest reports) into a new deck. Old decks keep their words forever.

### Fixing someone's report (manager)

In the "Reports received" table press **Edit** on the row. The report is loaded into the form and the app opens `/report`. Change it and send; the manager may write for any seat, and also into a closed period. Then press "Back to the dashboard". Regenerate the deck to pick up the change.

### People (`/manager/people`)

This is where the catalog is built and kept.

- **Teams:** add, rename, delete. A team that still has seats cannot be deleted ("Move or remove the seats of this team first.").
- **People:** add a person (name, optional email, Employee or Manager). With no email the server makes an internal address from the name (see "Sign in without an email") and the dialog shows it. Deactivate a person with the Active switch: they can no longer sign in and every token of theirs stops working at once. Their old reports stay. Inactive people and seats are hidden until you turn on the inactive switch; a team's "(N seats)" counts the same seats its section lists (active ones, or all when the switch is on). The dialog explains what saving an inactive person does and how to undo it (turn Active on and save). The page has a search (name, email, role), a team filter and a sort (order set up, name, role), and builds only the rows near the screen, so a catalog of 300 people stays fast. Deleting a team asks first; a team that still has seats is refused with a message.
- **Sign-in link:** every person has a **Sign-in link** action (also in the person dialog). It opens a dialog to choose how long the link works (1 hour, 24 hours, 7 days), then shows the link in a read-only field with **Copy link** (the screen reader hears "Copied"), a QR code, the time it stops working in your own time zone, a sentence ready to paste into a chat, and the warning that anyone with the link can sign in as that person. For a person who has a password the first step also shows an unchecked box, **Recovery link: lets them choose a new password without knowing the old one**, with the sentence "Use it when they forgot their password and you are sure the link reaches only them. Otherwise use Reset password." The request carries `"recovery": true` only when it is ticked; the answer echoes `recovery`, and the result then says it is a recovery link and the warning adds that the person can choose a new password with it. A person without a password gets no box (their first password never needs the old one). The box is a `CheckboxListTile` (one control with its words for a screen reader). Making another link does not turn the first off. The action is disabled for a person who is switched off, with the reason next to it. In demo mode the links are only displayed (`https://demo.invalid/auth/verify?token=demo-...`); they open nothing.
- **Seats:** a seat is a person in a team with a role title. A person can have several seats. A deactivated seat is no longer expected in any period; its old reports stay.
- **Counts and targets:** "What they count" on a seat opens the definitions editor.
  - Counts: up to 8 (a seat with none has nothing to count on its form), each named by you (a seat can have just "Sea", or "Sea", "Air", "Road" and so on), name 1 to 60 characters, unique ignoring case. The order is the order on the form and the slides; use the up and down buttons.
  - Targets: up to 10, text 1 to 200 characters.
  - Removing a count or target, or changing the wording of a target, **retires** the old one instead of deleting it. Old reports keep the counts and the wording they were answered against. New forms and new periods use the new list.
- **Last manager guard:** you cannot demote or deactivate the last active manager ("There must be at least one manager.").

## First run on an empty database

A fresh database has no catalog. Only the manager from the environment exists.

1. In `xynotransit-db/.env` set `BOOTSTRAP_CONTROLLER_EMAIL` and, if you like, `BOOTSTRAP_CONTROLLER_NAME`. Without a name the app uses the part of the email before the `@`, capitalised.
2. Build the web app and start the stack (see Quick start). At API start the manager is created (or promoted and activated when already there).
3. Open http://127.0.0.1:8080, sign in with that email, read the link in Mailpit (http://127.0.0.1:8025). You land on Overview, which says nobody is expected yet.
4. Open **People**. Add a team, then a person, then a seat (team and role title). Open the definitions editor and name the counts and write the targets.
5. Tell the person to sign in with their email. They land on their form.

## Sign in without an email

People who have no real email can still sign in. This is for people who work without a mailbox of their own.

- **Internal address.** Leave the email empty when you add a person. The server makes `name@xynotransit.internal` from the full name: lower case letters and digits, accents folded to plain letters (`é` becomes `e`), words joined by one dot, other characters dropped, at most 40 characters before the `@`. If it is taken it gets a number (`rosa.rakoto`, `rosa.rakoto2`, `rosa.rakoto3`). Addresses at a domain listed in the API setting `INTERNAL_EMAIL_DOMAINS` never receive mail. The demo follows the same rules (`internalLocalOf` and `internalEmailOf` in `lib/domain/text_rules.dart`, the same table as `xynotransit-api/src/signin.rs`).
- **Sign-in link.** A manager makes a one-time link in People and shares it privately (chat, in person, or by QR code). It signs the person in once, through the same `/auth/verify` page as an emailed link. A manager can make 30 links an hour. Every link is written to an audit table (never the link itself). A manager's link does NOT let the person skip the current password unless the manager ticked **Recovery link** (only possible for a person who has a password); a link from the person's own mailbox does. See the API README.
- **First manager, no mail.** On the server: `docker compose exec api xynotransit-api sign-in-link manager@xynotransit.internal --hours 24` prints the link and nothing else.
- **Sign-in page.** Under the form: "No email address? Ask your manager for a sign-in link."

The QR code is drawn in the app with the pure Dart `qr` package (error correction M, a quiet zone of 4 modules, black on white also in dark mode). `test/signin/qr_test.dart` draws it to a PNG and reads the modules back.

## Usernames and passwords

Passwords are added next to the links. Links stay the way to get started and to recover.

- **Sign-in screen** (`lib/features/sign_in_screen.dart`). The main form is Username and Password (show/hide button, Enter signs in, autofill hints `username` and `password` inside one `AutofillGroup`, `TextInput.finishAutofillContext()` after a good sign-in so the browser offers to save). Every failure reads "Username or password is wrong."; a 429 adds when to try again from `Retry-After` ("Try again in 14 minutes."). Under it a calm "Sign in with a link instead" section holds the email form and the lines "No email address? Ask your manager for a sign-in link." and "Forgot your password? Send yourself a link by email above, then choose a new password. No email? Ask your manager to reset it." After a safety sign-out (see Account menu) a calm banner at the top of the card says "You were signed out for safety after too many wrong passwords. Sign in again." (`signInNoticeProvider`, cleared by the next good sign-in).
- **Choose a password after a link.** If the person has no password, `/auth/verify` shows "Choose a password" (new and repeat, live hints, a strength meter, Skip for now). The meter only looks at length and at common passwords, never at "letters and symbols". Skipping is allowed.
- **Account menu** (person icon in the top bar, or the phone menu): "Change password" (or "Choose a password"), "Sign out". The change screen asks for the current password, then new and repeat. After a sign-in by a link that allows recovery (a link from the person's mailbox, or a manager's link made with **Recovery link** ticked) the server says `recent_link_session: true` in `/api/me` for 15 minutes (a manager's plain link, or a command line link without `--recovery`, gives a session that asks for the current password like any other); the screen then hides "Current password" and says "You signed in with a link, so you can choose a new password without the old one." The fresh token the change returns is a password session, so the next change asks for the current password again. If the 15 minutes ran out while the screen was open, the server asks for it, the screen shows the box and the person types it. Wrong current passwords are counted per person over every address: 10 in 15 minutes. The 10th ends every session of that person (the server answers 401 with the safety words; a thief's token dies), and the app signs out (`SignedOutForSafety`) and shows "You were signed out for safety after too many wrong passwords. Sign in again." on the sign-in screen. The person signs in again with the password, a link or the command line. Until the 15 minutes pass, a change answers 429 "Too many password attempts. Try again in 12 minutes." (from `Retry-After`) and the person stays signed in. These failures never count toward sign-in locks, and failed sign-ins never block a signed-in person's change. After it the app swaps in the fresh token the server returns; every other session of that person ends. The public demo has the menu entry too (the demo user is a demo account with no real sign-in).
- **Manager actions** (People): each person shows their Username and a Password line (Set or Not set). **Reset password** explains, asks to confirm, then shows a 16 character temporary password once (Copy, and "Tell them to sign in with this and choose their own password. It is shown only once."). Making another replaces it. **Remove password** makes the person link-only again. The username is edited in Edit person (optional on Add a person: the start of the email is used).
- **Temporary password.** The person signs in with it and lands on a blocking "Choose a new password" screen (`/account/password`, router redirect, no navigation). The screen asks for the temporary password once more because the API needs it as the current one.
- **Rules.** Usernames: lower case letters, digits, dot, dash, underscore, 3 to 40 characters, unique ignoring case. Passwords: 10 to 128 characters (counted as Unicode characters, spaces kept as typed, no trimming), no control characters, not the username, email, the part of the email before the @ or the full name, not one repeated character, not a simple run (1234567890, abcdefghij), not on the list of common passwords. The Dart port is `lib/domain/password_rules.dart`; the list is `lib/domain/common_passwords.dart`, a copy of `xynotransit-api/src/common_passwords.txt` (a test keeps them equal). `test/password/password_parity_test.dart` holds every number and message against `xynotransit-api/tests/fixtures/rules.json`.
- **Live hints are approximate.** The server normalises passwords to Unicode NFKC before it checks and hashes them. The app does not (Dart has none built in), so the live length and common-password hints use the raw text as typed; a decomposed accent can count differently from the server, which is authoritative. This is on purpose and there is no change planned.
- **Demo.** The in-memory backend implements the same rules, messages, lockout and session ending. Lockout follows the API design: 5 wrong tries per pair of username and address in 15 minutes lock that pair only (the demo has one address, the constant `unknown`, unless a test passes one); 100 wrong tries for a username from anywhere lock it for every address that has no successful sign-in (password or link) for it in the last 30 days; 30 wrong tries from one known address lock that address (never for `unknown`); wrong current passwords in the signed-in change are counted apart, per person over all addresses (`PasswordRules.changeFailuresPerPerson` = 10 in the 15 minute window; the 10th bumps the session epoch and writes audit kind `change-lock`, later tries get the 429). The link recovery rule (no current password within 15 minutes of a link sign-in, only when the link allows recovery) is in `changePasswordOf`; `createSignInLink(..., recovery:)` keeps the flag only for a person who has a password, `redeemSignInLink` makes a `viaLink` session only then, and `emailLinkSession` stands for a link from the mailbox. The numbers are in `PasswordRules`, held against `rules.json`. Session ending (`MemoryRepository.loginWithPassword`, `changePasswordOf`, `resetPassword`, `removePassword`). Passwords are compared as plain text there; nothing is hashed or stored anywhere.

## Loading the optional example catalog

`xynotransit-db/examples/` holds `10-seed.sql` (4 teams, 13 people, seats, counts, targets) and `20-seed-demo.sql` (14 demo reports). They are not loaded automatically. See `xynotransit-db/examples/README.md` for the commands. They create a person for `shalini@xynotransit.example`.

## Architecture

```
Browser (Flutter web)
   |  same origin, http://127.0.0.1:8080
   v
nginx (web container)        serves build/web, falls back to index.html
   |  /api/ proxied (no buffering on /api/events)
   v
axum API (api container, port 8081)    all authorization lives here
   |  sqlx                       |  SMTP
   v                             v
Postgres 18 (db container)    Mailpit (dev mail catcher, UI on 127.0.0.1:8025)
   |
   +-- NOTIFY xt_changes --> API listener --> Server-Sent Events --> browser
```

- Only the API talks to Postgres. There is no row level security.
- Sign-in is an emailed magic link, or a one-time sign-in link a manager makes for a person without a real email (see "Sign in without an email"). Passwords (username and password) sit next to the links; there is no open sign-up.
- Live updates use Server-Sent Events (SSE). If SSE fails, the app polls every 5 seconds.

## Quick start with the Docker stack

Needs Docker with compose, and Flutter (`export PATH="$HOME/projects/flutter/bin:$PATH"`).

```bash
# 1. Build the web app. The stack serves ../xynotransit_app/build/web.
cd ~/projects/xynotransit_app
flutter pub get
flutter build web --release --no-web-resources-cdn --dart-define=API_BASE_URL=/api

# 2. Start db, api, mailpit and web.
cd ~/projects/xynotransit-db
cp .env.example .env        # first time only; set BOOTSTRAP_CONTROLLER_EMAIL
./scripts/up.sh             # same as: docker compose up -d --build
```

Then:

1. Open http://127.0.0.1:8080.
2. Type the manager email (the value of `BOOTSTRAP_CONTROLLER_EMAIL`) and press "Send me a link".
3. Open Mailpit at http://127.0.0.1:8025, open the mail and click the link. A link works once and expires after 15 minutes. You land on `/manager`.
4. Build the catalog in People (see First run below). With the optional example data loaded, pick Feb 2026 in the period dropdown to see 14 submitted reports.

To try an employee, add a person in People and sign in with that email. They land on `/report` and see only their form.

Always build with `--no-web-resources-cdn`: it bundles CanvasKit and fonts so the page works behind the nginx CSP and offline (without it the page stays blank because the engine is fetched from gstatic.com).

After changing Flutter code, run the build again. nginx mounts `build/web` read only, so no image rebuild is needed.

## Demo mode

Without `API_BASE_URL` the app runs on in-memory data: the example catalog and 14 demo reports for Feb to Apr 2026. Nothing is saved after a reload and no server is needed. People, teams, seats, counts and targets can be added and edited in demo mode too, in memory only; a reload brings back the starting data.

```bash
flutter run -d chrome
```

- It is on whenever `API_BASE_URL` is empty. `--dart-define=DEMO_MODE=true` forces it even if a URL is set.
- Use the **Demo:** menu in the app bar to act as any person of the current catalog. Their role comes from their app role: a manager opens `/manager`, an employee opens `/report`. People you add in demo mode appear in the menu. Switching re-evaluates the redirects.

## Configuration

Flutter build time:

| Define | Meaning |
| --- | --- |
| `API_BASE_URL` | Base URL of the API, for the compose stack `/api`. Empty means demo mode. |
| `DEMO_MODE` | `true` forces demo mode. |

API runtime (set in `xynotransit-db/.env`, passed by compose):

| Variable | Default | Meaning |
| --- | --- | --- |
| `DATABASE_URL` | none, required | Postgres connection string. |
| `JWT_SECRET` | none, required | HS256 signing secret, at least 32 characters. |
| `PUBLIC_URL` | `http://127.0.0.1:8080` | Origin used in magic links. |
| `SMTP_HOST` | `mailpit` | SMTP server. |
| `SMTP_PORT` | `1025` | SMTP port. |
| `MAIL_FROM` | `Xynotransit <no-reply@xynotransit.local>` | Sender of magic links. |
| `BIND` | `0.0.0.0:8081` | Listen address. |
| `BOOTSTRAP_CONTROLLER_EMAIL` | empty | At start, this person is created as an active manager when missing, or promoted and activated. |
| `BOOTSTRAP_CONTROLLER_NAME` | empty | Name used when the person is created. Default: the part of the email before the `@`, capitalised. |
| `LOG_MAGIC_LINKS` | `false` | `true` logs the link at info level. Dev only. |
| `RUST_LOG` | `info` | Log level. |
| `POSTGRES_PASSWORD` | `xynotransit` | Used by compose for db and the API URL. |

## Going to production

- Use a real SMTP server: set `SMTP_HOST`, `SMTP_PORT`, `MAIL_FROM`. Remove the Mailpit service.
- Set `JWT_SECRET` to a long random value (for example `openssl rand -hex 32`).
- Put TLS in front (a reverse proxy or load balancer) and set `PUBLIC_URL` to the https origin, so magic links point to it.
- Set `BOOTSTRAP_CONTROLLER_EMAIL` to the real manager.
- Do not load `xynotransit-db/examples/` (placeholder people and demo reports). Add real people in People.
- Set `LOG_MAGIC_LINKS=false`, change `POSTGRES_PASSWORD`, and do not publish the db port.

## The deck snapshot

The deck is not built live. It freezes the slide words as well as the data. **Generate** (and later **Regenerate**) asks the API to freeze the submitted reports of the period into a snapshot, built on the server in deck order (team sort, then assignment sort). The preview and every export read that snapshot, so the deck does not change under you when someone resends a report. Press Regenerate to freeze the latest submitted reports into a new snapshot and pick up newer ones. Only a manager can do this.

## Exports

Every export includes the Suggestions page (34 slides for 14 reports). File names and the PDF and PPTX titles use the rendered meeting title.

- **PDF**: one page per slide.
- **PPTX**: every slide is a full-bleed picture of 3840 x 2160 (twice the slide size), with alt text, and speaker notes that hold the full content of the slide, one fact per line.
- **PNG**: a ZIP with one PNG per slide.

## Offline behaviour

- The form keeps a draft in `shared_preferences`, so a reload or a closed tab loses nothing.
- If sending fails (no network), the report is queued and retried every 15 seconds until it goes through.
- The sign-in token is also kept in `shared_preferences`. If the network is down at start, the last known person is used.

## Who can call what (API)

| Endpoint | Employee | Manager |
| --- | --- | --- |
| `POST /api/auth/magic-link`, `POST /api/auth/verify` | open | open |
| `POST /api/auth/login`, `POST /api/auth/password` (signed in) | open, own password only | same |
| `POST /api/persons/{id}/sign-in-link` | no | yes (30 an hour) |
| `POST /api/persons/{id}/password-reset`, `DELETE /api/persons/{id}/password` | no | yes (resets: 30 an hour) |
| `GET /api/me`, `GET /api/catalog` | yes (active rows only, other people's emails hidden) | yes (all emails; `?include_inactive=true` adds inactive rows) |
| `POST/PATCH/DELETE` teams, `POST/PATCH` persons and assignments, `PUT /api/assignments/{id}/definitions` | no | yes |
| `GET /api/summary` | no | yes |
| `POST /api/periods/ensure` | yes | yes |
| `PATCH /api/periods/{id}` (meeting date) | no | yes |
| `GET /api/periods/{id}/reports` (all reports) | no | yes |
| `GET /api/periods/{id}/reports/{assignment}` | own seat only | any |
| `PUT /api/periods/{id}/reports/{assignment}` (send) | own seat only, not in a closed period | any seat, also closed |
| `GET` and `POST /api/periods/{id}/deck` | no | yes |
| `GET` and `PUT /api/periods/{id}/deck-text` | no | yes |
| `POST /api/events/ticket`, `GET /api/events` | no | yes |

## Security model

- Authorization is in the API, not in the database. The JWT only proves who you are. The role is re-read from the database on every request, so demoting or deactivating someone takes effect at once.
- Only an active person can sign in. A deactivated person gets 401 on every request at once. Unknown addresses get the same answer as known ones, so addresses cannot be probed.
- Magic link tokens are 32 random bytes. Only their SHA-256 is stored. A link is single use and valid 15 minutes.
- Rate limit: at most 5 links per person per hour.
- Passwords are hashed on the server (Argon2id); the app never stores one. Only the sign-in token is kept in `shared_preferences`. The password boxes disable suggestions and autocorrect. A password change, reset or removal ends every older session (the token carries a session epoch).
- An employee (contributor) can read and send only their own report. Only a manager can generate decks, set the meeting date, or write into a closed period.
- The UI split is enforced by the API too: the list of reports, the deck (read and generate), the slide texts (read and save) and live events (ticket and stream) are manager only and return 403 to employees.
- In the catalog, person emails are `null` for an employee, except their own. A manager gets all emails.
- Live updates use a short ticket (60 seconds, single use, bound to the person), because EventSource cannot send headers.
- Errors never show SQL; details are logged on the server.

## Tests

```bash
export PATH="$HOME/projects/flutter/bin:$PATH"
flutter analyze
flutter test
flutter test --update-goldens     # only after an intended visual change
```

`test/password/` covers usernames and passwords (`memory_lockout_test.dart`: the pair, backstop, trusted address, address cap and link recovery rules of the demo; `scenarios_lockout.dart`: the same on both backends, including recovery and plain links, an email link, the first password after any link, the 10 per person cap with 10 addresses, and parallel wrong tries): the policy and its parity with the API, the in-memory demo (lockout, must-change flow, session ending, reset shown once, removal, username conflicts), `ApiAuthService` and `ApiRepository` with a mock server (paths, payloads, `Retry-After`, token swap), and the screens (sign in, choose a password, forced change and router redirect, account menu, People) at 360x800, 800x1100 and 1500x900 with text scale 2. `test/contract/scenarios_passwords.dart` plays the password life on both backends. `test/signin/` covers sign-in without an email: the address rules, the demo repository, the API client, the People screen and dialog, the QR code and the sign-in screen. `test/contract/` runs the same scenarios against the demo repository and, with `--dart-define=CONTRACT_API=http://127.0.0.1:8080`, against the live API.

API tests (need the db container running, see the API README):

```bash
cd ../xynotransit-api && cargo test
```

## Seed generator

`xynotransit-db/examples/10-seed.sql` (catalog) and `20-seed-demo.sql` (14 demo reports) are generated from `lib/data/seed_data.dart` and `lib/data/demo_data.dart`, which also feed demo mode. Do not edit them by hand. After changing the data, run from this folder:

```bash
dart run tool/gen_seed.dart
```

They are not loaded automatically; see `xynotransit-db/examples/README.md`.

## Folder layout

```
xynotransit_app/            this Flutter app
  lib/domain                models (report, period, deck, catalog, snapshot)
  lib/data                  Repository and AuthService interfaces, MemoryRepository (demo), seed data
  lib/data/api              ApiRepository, ApiAuthService, JSON mapping, SSE (web and stub)
  lib/features              employee (report screen), manager (reports, people page), deck_text (Slide text screen and draft preview), summary (overview dashboard and charts), admin (People screen and editors), form, table, preview, slides (1920x1080 widgets), export, shell (top bar), sign-in, verify
  lib/core                  theme tokens, shared widgets, formatting
  lib/app                   bootstrap, config, providers
  assets/fonts              bundled fonts (DM Sans, IBM Plex Mono)
  test                      unit, widget, API and golden tests (test/goldens)
  tool/gen_seed.dart        seed generator
  docs                      ASSUMPTIONS.md, reference/schema.sql, reference/deck_text_defaults.json
  web                       index.html, manifest, icons
xynotransit-api/            Rust axum backend
xynotransit-db/             Postgres image, initdb SQL, compose stack, nginx config, scripts
```

See `docs/ASSUMPTIONS.md` for choices made where the spec was silent.
