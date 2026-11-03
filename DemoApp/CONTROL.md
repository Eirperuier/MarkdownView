# Driving the demo app from a test (`-flooControl`)

A **test hook**, not a feature: in Debug builds only, launching the app with
`-flooControl <port>` opens a small HTTP/1.1 server on **127.0.0.1:<port>** (Network.framework,
loopback only). There is no auth beyond that: anything running on this Mac while it's on can read
the conversation and answer cards as you. Don't pass the flag outside tests.

Every action goes through the same code the UI does, on the main actor: `/send` through the
composer's `FlooDemo.sendDraft` → `FlooLive.send`; `/answer` through the cards'
`FlooDemo.answerAsk` → `FlooLive.respond` / `decline` / `take` / `turn` / `answer`, which go
through `FlooClient.answer` / `turn` (one signed answer, secrets sealed to the executor). Request bodies are never logged; the app prints only method and path.
The server drives the floo page shown last (`FlooDestination`).

```sh
APP=/tmp/demo-dd-ctl/Build/Products/Debug-maccatalyst/DemoApp.app
# live, against a lab
open -g -n "$APP" --args -flooStage http://localhost:8961 -flooAccount <person id> -flooControl 8977
# offline, a scripted scene (12: decision, step, sign-in; 13: requests made of several controls)
open -g -n "$APP" --args -flooScenario 13 -flooControl 8977
B=http://127.0.0.1:8977
```

## `GET /state`

```sh
curl -s $B/state
```
```json
{"signedIn": true, "live": true, "conversation": "<id, null in a scene>", "title": "本机后端",
 "messages": [{"number": 1, "from": "me", "text": "…"}, {"number": 2, "from": "管家", "text": "…"}],
 "asks": [{"id": "<ask id>", "title": "登录 x.com", "status": "open", "kind": "secret", "answered": false,
            "from": "管家", "device": "MacBook Pro", "line": "…", "origin": "…", "about": ["…"], "why": "…",
            "fields": [{"key": "username", "label": "账号", "kind": "username", "autofill": "username"}],
            "keep": true, "stage": {"working": "提交中…"}, "done": "…", "answer": "…"}]}
```
`messages`: the last 30 shown, text as stored (number null for a scene's). `asks`: every card on
the messages shown; `status` open, answered, withdrawn, expired, closed; `sealedTo` where its
secrets go.

A card is a request: a header and its **controls** in order (floo interaction.md §4), drawn by one
renderer. Each ask has `controls` and `submit`:

```json
{"id": "<ask id>", "title": "确认订单", "status": "open", "submit": "tap",
 "controls": [
   {"id": "total", "type": "view", "sha256": "…", "width": 520, "height": 224, "scale": 2, "required": false},
   {"id": "go", "type": "decision", "required": true,
    "options": [{"key": "order", "label": "确认下单", "standing": false, "danger": true},
                {"key": "no", "label": "不要", "standing": false, "danger": false}]}]}
```
Control types: `choice` (`options: [{key, label}]`, keys are indexes; `multiple`, `own`, `groups`
for the request's variants), `field` (`label`, `kind`, `guess`), `secret` (`label`, `kind`,
`autofill`), `decision` (`options: [{key, label, standing, danger}]`), `step` (`what`), `view` (the
frame shown now: `sha256`, `width` and `height` in pixels, `scale`), `toggle` (`value`, `effect:
"keep-signed-in"`), `say` (`text`), `link` / `image` (`url`); one this build doesn't know has
`unknown: true` (the card says 到 device-N 上答). Every control may have `label`, `group`;
`required` is whether it must be answered. `submit` is how the request is sent (§3.3): `tap` (one
control a tap decides — a pick, a decision, a step — answers on it), `button` (anything to fill: one
提交), `asker` (nothing to answer — a view, a toggle — its asker closes it). A request that grew
midway (§4.5) has `from`, the first control asked now, and `earlier`, what was sent before.

Where the request is exactly one of the forms before controls, the old keys are there too: `kind`
`step` (`what`), `decision` (`options`, `dangerous`), `secret` (`fields: [{key, label, kind,
autofill}]`, `keep`, `ways`), `choose` (`options`), `confirm` (`effect`), `fill` (`fields` with
`guess`) or `view` (`sha256`, `width`, `height`, `scale`, `keep` or null). A card of several items
(an agent's older ask) also has `items`, each a request. Live, ids and keys are the backend's.

## `POST /send`

```sh
curl -s -X POST $B/send -d '{"text":"你好"}'     # {"ok":true,"number":1} once the backend took it
```
A scene takes no messages (409). While a card is being answered in your own words, what's sent is
that answer: `{"ok":true,"answered":true}`.

## `POST /answer`

Per control, one answer for the whole request:

```sh
curl -s -X POST $B/answer -d '{"ask":"<id>","values":{"seat":{"picked":[0]},"n":"2"}}'          # choice + field
curl -s -X POST $B/answer -d '{"ask":"<id>","values":{"1":"K7R4P"}}'                              # view + field
curl -s -X POST $B/answer -d '{"ask":"<id>","values":{"go":"order"}}'                             # view + decision
curl -s -X POST $B/answer -d '{"ask":"<id>","values":{"keep":false},"secrets":{"@12":"…","@14":"…"}}'  # sign-in
curl -s -X POST $B/answer -d '{"ask":"<id>","values":{"keep":false}}'   # nothing to send: turned while open
curl -s -X POST $B/answer -d '{"ask":"<id>","declined":true}'           # 不做了
```
`values` by control id: a choice's `{"picked": [i], "own"?: "…"}` (or `[i]`, `i`), a field's words,
a decision's key (or label), a step's `engaged` (taken on, not an answer), `completed` or
`skipped`, a toggle's true or false. `secrets` by control id (a value given a secret's id in
`values` is taken as that secret); they are sealed to the device the call runs on and never leave
the app in the clear. What isn't given goes as the card holds it — a field's guess, a toggle's
default — except what must be answered in a `button` request. On an `asker` request, toggles alone
are turned without answering it (signed, `FlooClient.turn`). `declined` on a request of one decision
is its no.

The forms' bodies before controls still work:

```sh
curl -s -X POST $B/answer -d '{"ask":"<id>","choice":"<option key or label>"}'          # decision
curl -s -X POST $B/answer -d '{"ask":"<id>","decline":true}'                              # decision or secret
curl -s -X POST $B/answer -d '{"ask":"<id>","step":"engaged"}'       # or completed, skipped
curl -s -X POST $B/answer -d '{"ask":"<id>","values":{"username":"…","password":"…"},"keep":false}'  # secret
curl -s -X POST $B/answer -d '{"ask":"<id>","cancel":true}'          # view: cancelled
curl -s -X POST $B/answer -d '{"ask":"<id>","keep":false}'           # view: keep turned, signed here
curl -s -X POST $B/answer -d '{"ask":"<id>","picked":[0]}'            # choose (a vote too)
curl -s -X POST $B/answer -d '{"ask":"<id>","confirmed":true}'        # confirm
curl -s -X POST $B/answer -d '{"ask":"<id>","filled":["…","…"]}'      # fill; true takes the guesses
```
`item` (default 0) picks an item of a card with several. `{"ok":true}` means the card's answer
path took it, as a tap would; whether it went shows in `/state` (`stage`, `answered`). Errors:
`{"error":"…"}` with 400/404/409 (no such ask, not open, no such control or choice, a missing value).

## `POST /open`

```sh
curl -s -X POST $B/open -d '{"page":"sites"}'   # 网站登录; devices: 设备; chat closes them
```
The account menu's sheets, as its buttons open them; it answers once the sheet is in. Offline (a
scene) the sheets open empty.

## `GET /panel`, `POST /panel` (Mac)

```sh
curl -s $B/panel        # {"steps":[{"ask":"<id>","window":<window number>,"page":"ready"}]}
curl -s -X POST $B/panel -d '{"ask":"<id>","click":[200,120]}'   # a click in the page, in its points
curl -s -X POST $B/panel -d '{"ask":"<id>","type":"floo"}'       # typed, a key per character
curl -s -X POST $B/panel -d '{"ask":"<id>","close":true}'        # the close button: skipped
```
The windows a step's 我来做 opened on this Mac (FlooStepPanel.swift), each showing the engine page
its step is on; `page` is `connecting`, `ready`, `unavailable: …` or `handedBack`. A click and
typing are AppKit events sent to that window, the path a person's take; `window` is its number
for `screencapture -l`. 404: no window for that ask.

## `GET /shot`

```sh
curl -s -o shot.png $B/shot
```
A PNG of the key window with its sheets. On the Mac a sheet is an AppKit sheet, a window of its own
(`_UIBridgedPresentationWindow`) that isn't among the scene's windows, so drawing the key window
alone (`-flooShots`) leaves it out. The shot draws the key window, then each presented controller's
window over it, centred under the window's top bar on the page's background (where the Mac puts a
sheet; UIKit doesn't tell its place). `X-Floo-Windows` says what was drawn where.
