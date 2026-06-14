#!/usr/bin/env node
//
// bundle-editor.mjs — Build-Step: bündelt den UNVERÄNDERTEN Focus-Editor aus dem
// Hauptrepo (Single Source of Truth) ins App-Paket nach Resources/web/.
//
// Es gibt KEINEN Bundler im Hauptrepo — der Editor läuft als native ES-Module.
// Dieses Skript kopiert daher die transitive Import-Closure ab den Entry-Modulen
// strukturerhaltend (relative Import-Pfade bleiben gültig) plus das benötigte CSS
// und generiert ein index.html, das die Module nativ lädt.
//
// HARTE REGEL (CLAUDE.md): Editor-Code wird NICHT geforkt. Hier wird nur kopiert.
// Bei Editor-Bugs/-Features: Fix im Hauptrepo, danach neu bündeln. Den
// gebündelten Output NIE von Hand patchen.
//
// Aufruf:
//   node scripts/bundle-editor.mjs [--source <pfad-zum-hauptrepo>] [--verbose]
//   (Default-Source: /Users/bd/ClaudeProjects/schreibwerkstatt oder $SW_SOURCE)
//
// HINWEIS: Wegen ENABLE_USER_SCRIPT_SANDBOXING ist dies (noch) KEINE Xcode-
// Run-Script-Phase — sie dürfte das Hauptrepo (ausserhalb der Sandbox) nicht
// lesen. Vor dem Xcode-Build manuell ausführen.
//

import { readFile, writeFile, mkdir, rm, copyFile, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname, resolve, relative, join, posix } from 'node:path';
import { fileURLToPath } from 'node:url';
import { execFileSync } from 'node:child_process';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '..');

// ── Konfiguration ──────────────────────────────────────────────────────────

const args = process.argv.slice(2);
const VERBOSE = args.includes('--verbose');
const sourceArgIdx = args.indexOf('--source');
const SOURCE = resolve(
  sourceArgIdx >= 0 ? args[sourceArgIdx + 1]
    : process.env.SW_SOURCE || '/Users/bd/ClaudeProjects/schreibwerkstatt'
);

const SRC_PUBLIC = join(SOURCE, 'public');               // Wurzel der Web-Assets im Hauptrepo
// Ziel liegt BEWUSST ausserhalb des App-Sources-Ordners (= synchronized root
// group). Läge es darin, würde Xcode jede Datei einzeln + flach als Resource
// einschleusen (Struktur kaputt, Doppel-Inklusion). Stattdessen ist <repo>/web/
// als Folder-Reference (blauer Ordner) eingebunden → verbatim nach
// Contents/Resources/web/ kopiert, Struktur erhalten.
const DEST = join(REPO_ROOT, 'web');

// Entry-Module der Import-Closure (relativ zu public/). focus.js zieht den
// gesamten focus/-Kern + benötigte shared/-Helfer; editor-host + block-merge
// explizit, weil der spätere Bridge-Host bzw. die 409-Auflösung sie braucht
// (CLAUDE.md), auch wenn sie focus.js nicht zwingend erreicht.
const ENTRY_MODULES = [
  'js/editor/focus.js',
  'js/editor/shared/editor-host.js',
  'js/editor/shared/block-merge.js',
];

// CSS-Closure: Tokens (var(--…)-Quellen, im SPA separat geladen) + die vom
// Focus-Editor genutzten Stylesheets. Reihenfolge = Link-Reihenfolge im SPA.
const CSS_FILES = [
  'css/tokens/colors.css',
  'css/tokens/typography.css',
  'css/tokens/spacing.css',
  'css/tokens/scale.css',
  'css/tokens/motion.css',
  'css/editor/shared/editor-chrome.css',
  'css/editor/shared/conflict-resolution.css',
  'css/editor/focus/focus-mode.css',
];

// ── Import-Closure auflösen ──────────────────────────────────────────────────

// Findet statische + dynamische Specifier in einer JS-Quelle.
const IMPORT_RE = /(?:\bimport\b|\bexport\b)[^'"]*?from\s*['"]([^'"]+)['"]|\bimport\s*\(\s*['"]([^'"]+)['"]\s*\)/g;

function specifiersOf(code) {
  const out = new Set();
  let m;
  while ((m = IMPORT_RE.exec(code)) !== null) {
    out.add(m[1] || m[2]);
  }
  return [...out];
}

// Löst einen Specifier relativ zum importierenden Modul (innerhalb public/) auf.
// Liefert einen public-relativen POSIX-Pfad oder null (extern/bare → Warnung).
function resolveSpecifier(spec, fromPublicRel) {
  if (spec.startsWith('./') || spec.startsWith('../')) {
    const abs = posix.normalize(posix.join(posix.dirname(fromPublicRel), spec));
    return abs;
  }
  if (spec.startsWith('/')) {
    return posix.normalize(spec.slice(1)); // absolut ab public-Wurzel
  }
  return null; // bare specifier (npm o.ä.) — im Editor-Kern nicht erwartet
}

async function buildClosure(entries) {
  const visited = new Set();
  const queue = [...entries];
  const warnings = [];

  while (queue.length) {
    const rel = queue.shift();
    if (visited.has(rel)) continue;
    const abs = join(SRC_PUBLIC, rel);
    if (!existsSync(abs)) {
      warnings.push(`Modul fehlt in Quelle: ${rel}`);
      continue;
    }
    visited.add(rel);
    const code = await readFile(abs, 'utf8');
    for (const spec of specifiersOf(code)) {
      const target = resolveSpecifier(spec, rel);
      if (target === null) {
        warnings.push(`Bare/externer Import in ${rel}: '${spec}' — nicht gebündelt`);
        continue;
      }
      if (!visited.has(target)) queue.push(target);
    }
  }
  return { files: [...visited].sort(), warnings };
}

// ── Kopieren ─────────────────────────────────────────────────────────────────

async function copyRel(rel) {
  const src = join(SRC_PUBLIC, rel);
  const dst = join(DEST, rel);
  await mkdir(dirname(dst), { recursive: true });
  await copyFile(src, dst);
  if (VERBOSE) console.log('  +', rel);
}

function sourceCommit() {
  try {
    return execFileSync('git', ['rev-parse', '--short', 'HEAD'], { cwd: SOURCE }).toString().trim();
  } catch { return 'unbekannt'; }
}

// ── index.html (Lade-Scaffold / Verifikations-Harness) ───────────────────────

function indexHtml(cssFiles, commit) {
  const links = cssFiles.map((f) => `  <link rel="stylesheet" href="${f}">`).join('\n');
  return `<!doctype html>
<html lang="de">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Schreibwerkstatt — Focus-Editor</title>
  <!-- GENERIERT von scripts/bundle-editor.mjs aus Hauptrepo @${commit}. Nicht von Hand editieren. -->
${links}
  <style>
    html, body { margin: 0; height: 100%; background: var(--color-bg, #faf7f2); color: var(--color-text, #1f1c18); }
    #boot-status { font: 13px/1.5 -apple-system, system-ui, sans-serif; padding: 24px; }
    .ok { color: #2e7d32; } .err { color: #c62828; }
  </style>
</head>
<body>
  <!-- Mount-Punkt für den späteren Standalone-Bootstrap (focus/standalone.js,
       noch nicht vorhanden). Bis dahin verifiziert das Modul-Probe-Script unten
       nur, dass der Editor-Modulgraph nativ in der WKWebView lädt. -->
  <div id="editor-root"></div>
  <div id="boot-status">Lade Editor-Module…</div>

  <script type="module">
    const status = document.getElementById('boot-status');
    try {
      const focus = await import('./js/editor/focus.js');
      const host  = await import('./js/editor/shared/editor-host.js');
      const exportNames = Object.keys(focus).join(', ');
      status.className = 'ok';
      status.textContent = 'Editor-Modulgraph geladen ✓  (focus.js exportiert: ' + exportNames + ')';
      window.__focusBridge?.log?.('Editor-Module geladen: ' + exportNames);
      // Anbaupunkt: sobald focus/standalone.js existiert, hier mounten und via
      // host.setEditorHost(bridgeHost) den Bridge-Host injizieren.
      window.__editorModules = { focus, host };
    } catch (e) {
      status.className = 'err';
      status.textContent = 'Modul-Ladefehler: ' + (e && e.message ? e.message : e);
      window.__focusBridge?.log?.('Modul-Ladefehler: ' + e, 'error');
      console.error(e);
    }
  </script>
</body>
</html>
`;
}

// ── Main ──────────────────────────────────────────────────────────────────────

async function main() {
  if (!existsSync(SRC_PUBLIC)) {
    console.error(`✗ Quelle nicht gefunden: ${SRC_PUBLIC}\n  --source <pfad> oder $SW_SOURCE setzen.`);
    process.exit(1);
  }

  console.log(`Bündle Focus-Editor`);
  console.log(`  Quelle: ${SOURCE} @${sourceCommit()}`);
  console.log(`  Ziel:   ${relative(REPO_ROOT, DEST)}/`);

  // Sauberer Stand: js/ und css/ verwerfen, index.html wird neu generiert.
  await rm(join(DEST, 'js'), { recursive: true, force: true });
  await rm(join(DEST, 'css'), { recursive: true, force: true });
  await mkdir(DEST, { recursive: true });

  const { files: jsFiles, warnings } = await buildClosure(ENTRY_MODULES);
  for (const f of jsFiles) await copyRel(f);
  for (const f of CSS_FILES) {
    if (existsSync(join(SRC_PUBLIC, f))) await copyRel(f);
    else warnings.push(`CSS fehlt in Quelle: ${f}`);
  }

  const commit = sourceCommit();
  await writeFile(join(DEST, 'index.html'), indexHtml(CSS_FILES, commit), 'utf8');

  const manifest = {
    generatedFrom: SOURCE,
    sourceCommit: commit,
    entryModules: ENTRY_MODULES,
    jsFiles,
    cssFiles: CSS_FILES,
    note: 'Generiert von scripts/bundle-editor.mjs — nicht von Hand editieren.',
  };
  await writeFile(join(DEST, 'bundle-manifest.json'), JSON.stringify(manifest, null, 2), 'utf8');

  console.log(`\n✓ ${jsFiles.length} JS-Module + ${CSS_FILES.length} CSS-Dateien + index.html`);
  if (warnings.length) {
    console.log(`\n⚠ ${warnings.length} Warnung(en):`);
    for (const w of warnings) console.log('  -', w);
  }
}

main().catch((e) => { console.error(e); process.exit(1); });
