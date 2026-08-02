# App Store listing — English (UK/US)

Goes verbatim into App Store Connect → *Version → English*. Character counts
are Apple's limits; measured values via `scripts/appstore-check-lengths.sh`.

## Name (max 30)

```
Schreibwerkstatt Focuseditor
```

## Subtitle (max 30)

```
Focused writing, offline
```

## Promotional text (max 170, editable without review)

```
One page, one writing line, nothing else. Your text is saved on your Mac first and syncs to your Schreibwerkstatt account whenever a connection is there.
```

## Keywords (max 100, comma separated, no spaces after commas)

```
writing,focus,distraction free,novel,manuscript,author,offline,proofreading,thesaurus,writer
```

## Description (max 4000)

```
Focuseditor is Schreibwerkstatt's distraction-free writing mode as a native Mac app: one page, one writing line, nothing else. No book organiser, no analysis cards, no wall of toolbars — just the text you are working on.

COMPANION APP — PLEASE READ BEFORE DOWNLOADING
Focuseditor belongs to Schreibwerkstatt (schreibwerkstatt.app) and requires an account on a Schreibwerkstatt server. There is no standalone mode without a server. A demo account is built in so you can try it: one click in the sign-in window, no account of your own needed.

LOCAL FIRST, THEN SYNC
Every keystroke goes into local storage on your Mac first — not onto the network. The app never waits for a connection. It syncs in the background as soon as one is available; after the first launch you can keep working fully offline, on a train just as well as at your desk. If the same page changes here and elsewhere, the app merges the paragraphs instead of overwriting one version.

FOCUS
• Typewriter mode: the active line stays calmly on the writing line
• Dim the surroundings — either everything but the current line, or a window of three paragraphs
• Full screen with a toolbar that gets out of the way on its own
• Open pages from a picker with a "Recently opened" section (⌘O)

TYPOGRAPHY YOU SET YOURSELF
Typeface and size, line height, column width and paper tone — from bright paper to a dark desk. Light, dark, or following the system.

HELP WHILE WRITING
• Spelling and grammar checking, with your own dictionary
• Synonyms with ⌘⇧S: thesaurus and AI suggestions that fit the sentence
• Pull quotation marks into your book's style — «Swiss», „German“ or “English”
• Word count, reading time, daily goal and writing time at a glance
• Start an editorial review of the open page, running on your server

AT HOME ON THE MAC
German and English, a keyboard shortcut overview with ⌘?, dark mode, full screen, context menu — a real Mac app, not a browser window in a suit.

YOUR TEXT, YOUR SERVER
The app talks only to the server you enter yourself. The device token lives in the macOS keychain and never leaves your Mac in plain text. No ads, no tracking, no third-party analytics. The AI-assisted features (synonyms, editorial review) run through your server; which AI service is used there is up to whoever operates it — see the privacy policy.
```

## What's New in This Version (max 4000) — 3.15

```
First release on the Mac App Store.

• Distraction-free writing mode for exactly one page, fully offline-capable
• Local storage with background sync to your Schreibwerkstatt account
• Typewriter mode, focus dimming and adjustable typography
• Spell checking, synonyms (⌘⇧S) and quotation-mark normalisation
• Word count, daily goal and writing time
• German and English
```

## URLs

| Field | Value |
|---|---|
| Support URL | `https://schreibwerkstatt.app` |
| Marketing URL | `https://schreibwerkstatt.app` |
| Privacy Policy URL | `https://schreibwerkstatt.app/privacy` |

`/privacy` is the English alias of the same page (`routes/public.js` in the main
repo serves one template, language via `_bodyLang`).
