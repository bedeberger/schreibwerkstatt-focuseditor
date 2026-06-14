// sw-e2e-seed.mjs — Seed + Token-Mint für den Integrationstest (SyncIntegrationTests).
//
// Legt im Dev-Server (LOCAL_DEV_MODE, User dev@local) ein Buch + eine Seite an
// und mintet ein Device-Token. Läuft gegen dieselbe SQLite-DB wie der laufende
// Server (WAL → concurrent ok). Voraussetzung: Server läuft (node server.js, :3737).
//
// Aufruf:   node scripts/sw-e2e-seed.mjs
// Ausgabe:  JSON { bookId, pageId, token } + fertige Scheme-Env-Zeilen.
//
// Danach die ausgegebenen Werte in das Test-Scheme eintragen (TestAction →
// Environment Variables SW_E2E_BASE/TOKEN/BOOK/PAGE) bzw. die Datei
// schreibwerkstatt-focuseditor.xcodeproj/.../schreibwerkstatt-focuseditor.xcscheme
// aktualisieren, dann: xcodebuild test -scheme schreibwerkstatt-focuseditor.

import { createRequire } from 'node:module';

const SOURCE = process.env.SW_SOURCE || '/Users/bd/ClaudeProjects/schreibwerkstatt';
const require = createRequire(SOURCE + '/');

const contentStore = require(SOURCE + '/lib/content-store');
const bookAccess = require(SOURCE + '/db/book-access');
const deviceTokens = require(SOURCE + '/db/device-tokens');

const EMAIL = 'dev@local';
const ctx = { session: { user: { email: EMAIL, role: 'admin' } } };

const book = await contentStore.createBook(
  { name: 'E2E Testbuch', description: 'Sync-Smoke', owner_email: EMAIL }, ctx);
bookAccess.grantAccess(book.id, EMAIL, 'owner', EMAIL);

const page = await contentStore.createPage({
  book_id: book.id,
  chapter_id: null,
  name: 'E2E Seite 1',
  html: '<p data-bid="b1">Erster Absatz aus dem Seed.</p><p data-bid="b2">Zweiter Absatz.</p>',
}, ctx);

const tok = deviceTokens.createDeviceToken({ userEmail: EMAIL, deviceName: 'mac-e2e', platform: 'macos' });

console.log(JSON.stringify({ bookId: book.id, pageId: page.id, token: tok.plain_token }, null, 2));
console.log('\n# Scheme-Env (TestAction):');
console.log(`SW_E2E_BASE=http://localhost:3737`);
console.log(`SW_E2E_TOKEN=${tok.plain_token}`);
console.log(`SW_E2E_BOOK=${book.id}`);
console.log(`SW_E2E_PAGE=${page.id}`);
