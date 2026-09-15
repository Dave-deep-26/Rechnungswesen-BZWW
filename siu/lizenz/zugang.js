/* =====================================================================
   zugang.js · Lizenz, Login und Fortschritt für die Finanzbuchhaltung Plattform
   Benötigt: supabase-js v2 (UMD) und config.js vor dieser Datei.

   <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"></script>
   <script src="lizenz/config.js"></script>
   <script src="lizenz/zugang.js"></script>
   <script>
     Zugang.zugangPruefen().then(function (status) {
       // ab hier hat der Benutzer Zugang, Plattform starten
     });
   </script>

   API
     Zugang.zugangPruefen()                 → Promise<status>, zeigt bei Bedarf die Anmeldemaske und wartet
     Zugang.anmelden(email, code)           → Promise<status>
     Zugang.abmelden()                      → Promise
     Zugang.benutzer()                      → letzter bekannter Status (auch offline)
     Zugang.codeEinloesen(code)             → Promise<status>, zusätzlicher Code für ein bestehendes Konto
     Zugang.fortschrittSpeichern(key, daten)→ Promise, lokal sofort, Server sobald online
     Zugang.fortschrittLaden(key, standard) → Promise<daten>, nimmt den neueren Stand (lokal oder Server)
     Zugang.fortschrittAlle()               → Promise<{key: daten}>
     Zugang.synchronisieren()               → Promise<bool>, Puffer an den Server senden
     Zugang.client                          → der Supabase Client

   config.js: produkt ('fibu', 'siu-m4', ...) bindet Codes an dieses Angebot.
   ===================================================================== */
(function (global) {
  'use strict';

  var PRAEFIX = 'zugang:';
  var K = {
    status: PRAEFIX + 'status',
    outbox: PRAEFIX + 'outbox',
    migriert: PRAEFIX + 'migriert',
    daten: function (k) { return PRAEFIX + 'f:' + k; }
  };

  var cfg = null;
  var client = null;
  var statusCache = null;
  var sendetGerade = false;
  var maskeEl = null;
  var maskeResolve = null;

  // ------------------------------------------------------------ Hilfen
  function lsGet(key) {
    try { var v = global.localStorage.getItem(key); return v ? JSON.parse(v) : null; } catch (e) { return null; }
  }
  function lsSet(key, wert) {
    try { global.localStorage.setItem(key, JSON.stringify(wert)); } catch (e) { /* voll oder gesperrt */ }
  }
  function lsDel(key) {
    try { global.localStorage.removeItem(key); } catch (e) { /* egal */ }
  }
  function online() { return typeof navigator === 'undefined' || navigator.onLine !== false; }

  function codeNormalisieren(code) {
    var s = String(code || '').toUpperCase().replace(/[^A-Z2-9]/g, '');
    if (s.length === 12) return s.slice(0, 4) + '-' + s.slice(4, 8) + '-' + s.slice(8, 12);
    return s;
  }
  function codeFormatierenBeimTippen(wert) {
    var s = String(wert || '').toUpperCase().replace(/[^A-Z2-9]/g, '').slice(0, 12);
    return s.replace(/(.{4})(?=.)/g, '$1-');
  }
  function emailGueltig(email) { return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(email); }

  function ensureInit() {
    if (client) return;
    if (!global.supabase || !global.supabase.createClient) {
      throw new Error('supabase-js fehlt. Script vor zugang.js einbinden.');
    }
    cfg = Object.assign({
      titel: 'Finanzbuchhaltung Plattform',
      untertitel: '',
      produkt: null,
      alteSchluessel: [],
      alteSchluesselPraefix: ''
    }, global.ZUGANG_CONFIG || {}, cfg || {});
    if (!cfg.url || !cfg.anonKey || /DEIN-/.test(cfg.url + cfg.anonKey)) {
      throw new Error('config.js: Supabase URL und Anon Key eintragen.');
    }
    client = global.supabase.createClient(cfg.url, cfg.anonKey, {
      auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
    });
    global.addEventListener('online', function () { synchronisieren(); });
    setInterval(function () { synchronisieren(); }, 30000);
  }

  function init(optionen) { cfg = Object.assign({}, cfg || {}, optionen || {}); ensureInit(); return api; }

  function netzfehler(err) {
    var m = (err && err.message) || '';
    if (/fetch|network|Failed|load/i.test(m) || !online()) {
      return new Error('Keine Verbindung. Bitte Internet prüfen und nochmals versuchen.');
    }
    return new Error(m || 'Unbekannter Fehler.');
  }

  function produkt() { return (cfg && cfg.produkt) || null; }

  function grundText(status) {
    if (!status) return '';
    switch (status.grund) {
      case 'anderes_produkt': return 'Dein Code gilt für ein anderes Angebot. Für diese Plattform brauchst du einen eigenen Code.';
      case 'gesperrt': return 'Dein Zugang wurde gesperrt. Bitte melde dich bei deiner Lehrperson.';
      case 'abgelaufen': return 'Deine Lizenz ist abgelaufen. Mit einem neuen Code geht es weiter.';
      case 'kein_code': return 'Für dieses Konto ist noch kein Code hinterlegt.';
      default: return '';
    }
  }

  // ------------------------------------------------------------ Status
  async function statusLaden() {
    var r = await client.rpc('zugang_status', { p_produkt: produkt() });
    if (r.error) throw netzfehler(r.error);
    return r.data;
  }
  function statusMerken(s) {
    statusCache = s;
    lsSet(K.status, { status: s, zeit: new Date().toISOString() });
  }
  function statusGepuffert() {
    if (statusCache) return statusCache;
    var p = lsGet(K.status);
    return p ? p.status : null;
  }
  async function session() {
    var r = await client.auth.getSession();
    return r && r.data ? r.data.session : null;
  }

  // ------------------------------------------------------------ Zugang prüfen
  async function zugangPruefen() {
    ensureInit();
    var s = await session();
    if (s) {
      if (online()) {
        try {
          var st = await statusLaden();
          statusMerken(st);
          if (st.aktiv) { await nachLogin(); return st; }
          return maskeZeigen({ email: st.email || s.user.email, hinweis: grundText(st) });
        } catch (e) {
          var puffer = statusGepuffert();
          if (puffer && puffer.aktiv) return puffer;
        }
      } else {
        var offline = statusGepuffert();
        if (offline && offline.aktiv) return offline;
      }
    }
    return maskeZeigen({});
  }

  async function nachLogin() {
    await alteDatenUebernehmen();
    synchronisieren();
  }

  // ------------------------------------------------------------ Anmelden
  async function anmelden(email, code) {
    ensureInit();
    email = String(email || '').trim().toLowerCase();
    code = codeNormalisieren(code);
    if (!emailGueltig(email)) throw new Error('Bitte eine gültige E-Mail Adresse eingeben.');
    if (code.length !== 14) throw new Error('Der Code hat das Format ABCD-EFGH-JKLM.');
    if (!online()) throw new Error('Für die erste Anmeldung brauchst du eine Internetverbindung.');

    var pruef = await client.rpc('code_pruefen', { p_code: code, p_email: email, p_produkt: produkt() });
    if (pruef.error) throw netzfehler(pruef.error);
    var status = pruef.data && pruef.data.status;

    if (status === 'ungueltig') throw new Error('Diesen Code gibt es nicht. Bitte prüfe die Schreibweise.');
    if (status === 'falsches_produkt') throw new Error('Dieser Code gilt für ein anderes Angebot, nicht für diese Plattform.');
    if (status === 'vergeben') throw new Error('Dieser Code ist bereits mit einer anderen E-Mail verknüpft.');
    if (status === 'gesperrt') throw new Error('Dieser Code wurde gesperrt. Bitte melde dich bei deiner Lehrperson.');
    if (status === 'abgelaufen') throw new Error('Die Lizenz zu diesem Code ist abgelaufen.');

    var s0 = await session();
    if (status === 'eigener') {
      var login = await client.auth.signInWithPassword({ email: email, password: code });
      if (login.error) throw new Error('Anmeldung fehlgeschlagen. Stimmen E-Mail und Code?');
    } else if (status === 'frei' && s0 && s0.user && String(s0.user.email || '').toLowerCase() === email) {
      // Bereits angemeldetes Konto löst einen weiteren Code ein (z.B. zweites Produkt)
      var zus = await client.rpc('code_einloesen', { p_code: code, p_produkt: produkt() });
      if (zus.error) throw new Error(zus.error.message || 'Code konnte nicht eingelöst werden.');
      await client.auth.updateUser({ password: code });
    } else if (status === 'frei') {
      var reg = await client.auth.signUp({ email: email, password: code });
      if (reg.error) {
        if (/already|registered|exists/i.test(reg.error.message)) {
          throw new Error('Diese E-Mail ist schon registriert. Melde dich zuerst mit deinem bisherigen Code an, danach kannst du den neuen Code eingeben.');
        }
        throw netzfehler(reg.error);
      }
      if (!reg.data || !reg.data.session) {
        throw new Error('Konto angelegt, aber keine Sitzung erhalten. In Supabase muss unter Authentication → Email die Option „Confirm email“ ausgeschaltet sein.');
      }
      var einl = await client.rpc('code_einloesen', { p_code: code, p_produkt: produkt() });
      if (einl.error) throw new Error(einl.error.message || 'Code konnte nicht eingelöst werden.');
    } else {
      throw new Error('Unerwartete Antwort vom Server.');
    }

    var st = await statusLaden();
    statusMerken(st);
    if (!st.aktiv) throw new Error(grundText(st) || 'Kein gültiger Zugang.');
    await nachLogin();
    if (maskeResolve) { var r = maskeResolve; maskeResolve = null; maskeSchliessen(); r(st); }
    return st;
  }

  async function codeEinloesen(code) {
    ensureInit();
    code = codeNormalisieren(code);
    if (code.length !== 14) throw new Error('Der Code hat das Format ABCD-EFGH-JKLM.');
    var einl = await client.rpc('code_einloesen', { p_code: code, p_produkt: produkt() });
    if (einl.error) throw new Error(einl.error.message || 'Code konnte nicht eingelöst werden.');
    // Der Code ist gleichzeitig das Passwort, damit die Anmeldung mit dem neuen Code klappt.
    await client.auth.updateUser({ password: code });
    var st = await statusLaden();
    statusMerken(st);
    return st;
  }

  async function abmelden() {
    ensureInit();
    await synchronisieren();
    try { await client.auth.signOut(); } catch (e) { /* offline */ }
    statusCache = null;
    lsDel(K.status);
    lsDel(K.migriert);
    try {
      Object.keys(global.localStorage).forEach(function (k) {
        if (k.indexOf(PRAEFIX + 'f:') === 0) lsDel(k);
      });
    } catch (e) { /* egal */ }
    lsDel(K.outbox);
  }

  function benutzer() { return statusGepuffert(); }

  // ------------------------------------------------------------ Fortschritt
  async function fortschrittSpeichern(schluessel, daten) {
    ensureInit();
    var stempel = new Date().toISOString();
    lsSet(K.daten(schluessel), { daten: daten, aktualisiert_am: stempel });
    var box = lsGet(K.outbox) || [];
    box = box.filter(function (e) { return e.schluessel !== schluessel; });
    box.push({ schluessel: schluessel, daten: daten, aktualisiert_am: stempel });
    lsSet(K.outbox, box);
    return synchronisieren();
  }

  async function synchronisieren() {
    if (!client || sendetGerade || !online()) return false;
    var box = lsGet(K.outbox) || [];
    if (!box.length) return true;
    var s = await session();
    if (!s) return false;
    sendetGerade = true;
    try {
      var r = await client.rpc('fortschritt_speichern', { p_eintraege: box });
      if (r.error) throw r.error;
      // nur entfernen, was gesendet wurde
      var gesendet = {};
      box.forEach(function (e) { gesendet[e.schluessel] = e.aktualisiert_am; });
      var rest = (lsGet(K.outbox) || []).filter(function (e) { return gesendet[e.schluessel] !== e.aktualisiert_am; });
      lsSet(K.outbox, rest);
      return rest.length === 0;
    } catch (e) {
      return false;
    } finally {
      sendetGerade = false;
    }
  }

  function neuer(a, b) { return Date.parse(a) > Date.parse(b); }

  async function fortschrittLaden(schluessel, standard) {
    ensureInit();
    var lokal = lsGet(K.daten(schluessel));
    if (online()) {
      try {
        var s = await session();
        if (s) {
          var r = await client.from('fortschritt').select('daten, aktualisiert_am')
            .eq('schluessel', schluessel).eq('user_id', s.user.id).maybeSingle();
          if (!r.error && r.data && (!lokal || neuer(r.data.aktualisiert_am, lokal.aktualisiert_am))) {
            lsSet(K.daten(schluessel), r.data);
            return r.data.daten;
          }
        }
      } catch (e) { /* offline, lokal nehmen */ }
    }
    return lokal ? lokal.daten : (standard === undefined ? null : standard);
  }

  async function fortschrittAlle() {
    ensureInit();
    var alle = {};
    try {
      Object.keys(global.localStorage).forEach(function (k) {
        if (k.indexOf(PRAEFIX + 'f:') === 0) {
          var v = lsGet(k);
          if (v) alle[k.slice((PRAEFIX + 'f:').length)] = v;
        }
      });
    } catch (e) { /* egal */ }
    if (online()) {
      try {
        var s = await session();
        if (s) {
          var r = await client.from('fortschritt').select('schluessel, daten, aktualisiert_am').eq('user_id', s.user.id);
          if (!r.error && r.data) {
            r.data.forEach(function (z) {
              if (!alle[z.schluessel] || neuer(z.aktualisiert_am, alle[z.schluessel].aktualisiert_am)) {
                alle[z.schluessel] = { daten: z.daten, aktualisiert_am: z.aktualisiert_am };
                lsSet(K.daten(z.schluessel), alle[z.schluessel]);
              }
            });
          }
        }
      } catch (e) { /* offline */ }
    }
    var ergebnis = {};
    Object.keys(alle).forEach(function (k) { ergebnis[k] = alle[k].daten; });
    return ergebnis;
  }

  // Einmalige Übernahme des alten localStorage Fortschritts beim ersten Login
  async function alteDatenUebernehmen() {
    if (lsGet(K.migriert)) return;
    var kandidaten = [];
    try {
      var schluessel = Object.keys(global.localStorage);
      schluessel.forEach(function (k) {
        if (k.indexOf(PRAEFIX) === 0) return;
        var passt = (cfg.alteSchluessel || []).indexOf(k) >= 0 ||
                    (cfg.alteSchluesselPraefix && k.indexOf(cfg.alteSchluesselPraefix) === 0);
        if (passt) kandidaten.push(k);
      });
    } catch (e) { /* egal */ }
    for (var i = 0; i < kandidaten.length; i++) {
      var roh = null;
      try { roh = global.localStorage.getItem(kandidaten[i]); } catch (e) { continue; }
      var daten;
      try { daten = JSON.parse(roh); } catch (e) { daten = roh; }
      var vorhanden = lsGet(K.daten(kandidaten[i]));
      if (vorhanden) continue;   // schon im neuen Puffer
      var server = await fortschrittLaden(kandidaten[i], null);
      if (server !== null) continue;   // Server hat schon Daten, alte lokale nicht darüber schreiben
      await fortschrittSpeichern(kandidaten[i], daten);
    }
    lsSet(K.migriert, { zeit: new Date().toISOString(), uebernommen: kandidaten });
  }

  // ------------------------------------------------------------ Anmeldemaske
  var CSS = ''
    + '.zg-hintergrund{position:fixed;inset:0;z-index:99999;background:#14213D;display:flex;align-items:center;justify-content:center;padding:24px;font-family:Inter,system-ui,-apple-system,"Segoe UI",sans-serif;color:#F4EFEA}'
    + '.zg-karte{width:100%;max-width:420px;background:#1B2B45;border:1px solid rgba(244,239,234,.12);border-radius:20px;padding:32px 28px;box-shadow:0 30px 80px rgba(0,0,0,.45)}'
    + '.zg-kopf{display:flex;align-items:center;gap:14px;margin-bottom:24px}'
    + '.zg-logo{width:52px;height:52px;flex:none}'
    + '.zg-titel{font-size:20px;font-weight:700;line-height:1.15;margin:0}'
    + '.zg-unter{font-size:13px;opacity:.65;margin:2px 0 0}'
    + '.zg-feld{display:block;margin-bottom:14px}'
    + '.zg-feld span{display:block;font-size:12px;font-weight:600;letter-spacing:.04em;text-transform:uppercase;opacity:.7;margin-bottom:6px}'
    + '.zg-feld input{width:100%;box-sizing:border-box;background:#14213D;border:1px solid rgba(244,239,234,.18);border-radius:12px;color:#F4EFEA;font-size:17px;padding:13px 14px;outline:none;font-family:inherit}'
    + '.zg-feld input:focus{border-color:#C2185B;box-shadow:0 0 0 3px rgba(194,24,91,.25)}'
    + '.zg-feld input.zg-code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;letter-spacing:.12em;text-transform:uppercase}'
    + '.zg-knopf{width:100%;margin-top:6px;background:#C2185B;color:#fff;border:0;border-radius:12px;font-size:16px;font-weight:700;padding:14px;cursor:pointer;font-family:inherit}'
    + '.zg-knopf:hover{background:#A9144F}.zg-knopf:disabled{opacity:.6;cursor:wait}'
    + '.zg-fehler{background:rgba(194,24,91,.15);border:1px solid rgba(194,24,91,.5);border-radius:10px;padding:10px 12px;font-size:14px;margin-bottom:14px;line-height:1.4}'
    + '.zg-hinweis{background:rgba(244,239,234,.08);border-radius:10px;padding:10px 12px;font-size:14px;margin-bottom:14px;line-height:1.4}'
    + '.zg-fuss{font-size:12.5px;opacity:.6;margin:18px 0 0;line-height:1.5;text-align:center}'
    + '@media (max-width:480px){.zg-hintergrund{padding:16px}.zg-karte{padding:26px 20px;border-radius:16px}}';

  var LOGO = '<svg class="zg-logo" viewBox="0 0 100 100" aria-hidden="true">'
    + '<rect width="100" height="100" rx="22" fill="#14213D"/>'
    + '<rect x="18" y="20" width="64" height="9" rx="1.5" fill="#F4EFEA"/>'
    + '<rect x="45.5" y="20" width="9" height="60" rx="1.5" fill="#F4EFEA"/>'
    + '<rect x="21" y="42" width="17" height="6" rx="1" fill="#F3D4DC"/>'
    + '<rect x="21" y="54" width="13" height="6" rx="1" fill="#F3D4DC"/>'
    + '<rect x="58" y="42" width="23" height="6" rx="1" fill="#C2185B"/>'
    + '</svg>';

  function esc(s) { return String(s || '').replace(/[&<>"]/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]; }); }

  function maskeZeigen(opt) {
    ensureInit();
    return new Promise(function (resolve) {
      maskeResolve = resolve;
      if (!document.getElementById('zg-style')) {
        var st = document.createElement('style'); st.id = 'zg-style'; st.textContent = CSS; document.head.appendChild(st);
      }
      maskeSchliessen();
      maskeEl = document.createElement('div');
      maskeEl.className = 'zg-hintergrund';
      maskeEl.innerHTML = ''
        + '<form class="zg-karte" novalidate>'
        + '  <div class="zg-kopf">' + LOGO + '<div><h1 class="zg-titel">' + esc(cfg.titel) + '</h1>'
        + (cfg.untertitel ? '<p class="zg-unter">' + esc(cfg.untertitel) + '</p>' : '') + '</div></div>'
        + (opt.hinweis ? '<div class="zg-hinweis">' + esc(opt.hinweis) + '</div>' : '')
        + '  <div class="zg-fehler" hidden></div>'
        + '  <label class="zg-feld"><span>E-Mail</span><input type="email" name="email" autocomplete="email" inputmode="email" value="' + esc(opt.email || '') + '" placeholder="vorname.name@schule.ch"></label>'
        + '  <label class="zg-feld"><span>Zugangscode</span><input type="text" name="code" class="zg-code" autocomplete="one-time-code" autocapitalize="characters" spellcheck="false" maxlength="14" placeholder="ABCD-EFGH-JKLM"></label>'
        + '  <button type="submit" class="zg-knopf">Anmelden</button>'
        + '  <p class="zg-fuss">Den Code erhältst du von deiner Lehrperson oder Schule.<br>Beim ersten Mal wird dein Konto automatisch angelegt.</p>'
        + '</form>';
      document.body.appendChild(maskeEl);

      var form = maskeEl.querySelector('form');
      var fehler = maskeEl.querySelector('.zg-fehler');
      var emailIn = form.elements.email;
      var codeIn = form.elements.code;
      var knopf = form.querySelector('button');

      codeIn.addEventListener('input', function () {
        var pos = codeIn.selectionStart;
        var vorher = codeIn.value.length;
        codeIn.value = codeFormatierenBeimTippen(codeIn.value);
        var diff = codeIn.value.length - vorher;
        try { codeIn.setSelectionRange(pos + diff, pos + diff); } catch (e) { /* egal */ }
      });

      form.addEventListener('submit', async function (ev) {
        ev.preventDefault();
        fehler.hidden = true;
        knopf.disabled = true; knopf.textContent = 'Wird geprüft…';
        try {
          await anmelden(emailIn.value, codeIn.value);
        } catch (e) {
          fehler.textContent = e.message; fehler.hidden = false;
          knopf.disabled = false; knopf.textContent = 'Anmelden';
        }
      });
      (opt.email ? codeIn : emailIn).focus();
    });
  }

  function maskeSchliessen() {
    if (maskeEl && maskeEl.parentNode) maskeEl.parentNode.removeChild(maskeEl);
    maskeEl = null;
  }

  // ------------------------------------------------------------ Export
  var api = {
    init: init,
    zugangPruefen: zugangPruefen,
    anmelden: anmelden,
    abmelden: abmelden,
    benutzer: benutzer,
    codeEinloesen: codeEinloesen,
    fortschrittSpeichern: fortschrittSpeichern,
    fortschrittLaden: fortschrittLaden,
    fortschrittAlle: fortschrittAlle,
    synchronisieren: synchronisieren,
    codeNormalisieren: codeNormalisieren,
    get client() { ensureInit(); return client; }
  };
  global.Zugang = api;
})(window);
