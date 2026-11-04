// Gera GmailCleanerBuddy/Translations.swift a partir de TRANSLATIONS em
// src/app.ts do projeto Android — os textos ficam num lugar só.
// Uso: node scripts/gen-l10n.mjs ../gmailcleanerbuddyapp/src/app.ts GmailCleanerBuddy/Translations.swift
import fs from 'node:fs';

const [src, dest] = process.argv.slice(2);
const code = fs.readFileSync(src, 'utf8');
const start = code.indexOf('const TRANSLATIONS');
const end = code.indexOf('\nfunction t(');
const T = new Function(code.slice(start, end).replace(/^const TRANSLATIONS[^=]*=/, 'return '))();

// Só o iOS precisa: o confirm() do navegador traz o "Cancelar" pronto.
const cancel = { pt: 'Cancelar', en: 'Cancel', es: 'Cancelar', fr: 'Annuler', it: 'Annulla', ru: 'Отмена', zh: '取消' };

const BS = String.fromCharCode(92);
const esc = (s) =>
  s.split('<br>').join('\n')
    .split(BS).join(BS + BS)
    .split('"').join(BS + '"')
    .split('\n').join(BS + 'n');

let out = '// GERADO por scripts/gen-l10n.mjs a partir de src/app.ts do projeto Android.\n' +
  '// Não edite à mão: mude lá e rode o script de novo.\n\n' +
  'let TRANSLATIONS: [Lang: [String: String]] = [\n';
for (const [lang, dict] of Object.entries(T)) {
  dict['btn.cancel'] = cancel[lang];
  out += `  .${lang}: [\n`;
  for (const [k, v] of Object.entries(dict)) out += `    "${k}": "${esc(v)}",\n`;
  out += '  ],\n';
}
out += ']\n';
fs.writeFileSync(dest, out);
console.log(`ok: ${Object.keys(T).length} idiomas, ${Object.keys(T.pt).length} chaves`);
