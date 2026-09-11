# Lizenzsystem für die Finanzbuchhaltung Plattform

Login mit E-Mail und Zugangscode, Fortschritt in der Datenbank, Offlinebetrieb über localStorage, Admin Konsole für Codes. Alles ohne eigenen Server: Supabase (Datenbank und Auth) plus vier statische Dateien.

| Datei | Zweck |
|---|---|
| `schema.sql` | Datenbank: Tabellen, Funktionen, Zugriffsregeln. Einmal im Supabase SQL Editor ausführen. |
| `config.js` | Projekt URL und Anon Key eintragen. |
| `zugang.js` | Das Modul für die Plattform: Anmeldemaske, Zugangsprüfung, Fortschritt speichern und laden. |
| `admin.html` | Deine Konsole: Lizenzen anlegen, Codes erzeugen, CSV exportieren, sperren, Rollen setzen. |
| `demo.html` | Minimale Beispielseite zum Testen mit zwei Browsern. |

## Einrichtung (einmalig, etwa 20 Minuten)

1. **Supabase Projekt** anlegen auf supabase.com, Region Frankfurt.
2. **SQL Editor** öffnen, den ganzen Inhalt von `schema.sql` einfügen, ausführen. Kann jederzeit nochmals ausgeführt werden.
3. **Authentication → Providers → Email**: „Confirm email“ **ausschalten**. Sonst bekommt niemand nach der Registrierung eine Sitzung. Der Zugangscode ist die Zutrittskontrolle, nicht die Mailbestätigung.
4. **Authentication → Rate Limits**: „Sign ups and sign ins“ auf mindestens 100 pro 5 Minuten stellen. Eine Klasse meldet sich gleichzeitig hinter derselben Schul IP an.
5. **Settings → API**: Projekt URL und `anon` Key in `config.js` eintragen.
6. `demo.html` im Browser öffnen. Du brauchst jetzt einen ersten Code, den erzeugst du einmalig im SQL Editor, weil noch kein Admin existiert:

   ```sql
   -- temporär als Superuser im SQL Editor, danach nie mehr nötig
   insert into public.lizenz (bezeichnung, kunde) values ('INTERN', 'finanzunterricht.ch');
   insert into public.code (code, lizenz_id) select public.code_generieren(), id from public.lizenz where bezeichnung = 'INTERN';
   select code from public.code;
   ```

7. Mit deiner Mail und diesem Code in `demo.html` anmelden. Dann im SQL Editor:

   ```sql
   update public.profil set rolle = 'admin' where email = 'davide@finanzunterricht.ch';
   ```

8. `admin.html` öffnen. Ab jetzt läuft alles über die Konsole, der SQL Editor ist nicht mehr nötig.

## Einbau in die Plattform

In `plattform/index.html` ist der Einbau bereits gemacht. Die Plattform lädt die drei Scripts, zeigt ohne Zugang die Anmeldemaske, holt beim Start den Fortschritt aus dem Konto und meldet jede Änderung gebündelt an den Server. Der bisherige localStorage Schlüssel `finanzbuchhaltung-plattform-v2` bleibt als Puffer, bestehende Nutzer werden beim ersten Login übernommen. In der Infoleiste stehen neu das angemeldete Konto und „Abmelden“. „Fortschritt zurücksetzen“ leert auch das Konto.

**Deployment auf Vercel:** den ganzen Ordner `plattform/` hochladen (index.html plus Ordner `lizenz/`). In `sw.js` die Dateien `./lizenz/config.js` und `./lizenz/zugang.js` sowie die Supabase CDN URL in die Cache Liste aufnehmen, dann läuft die Plattform auch offline mit Login. Ohne diesen Eintrag läuft sie offline trotzdem, aber nur für Nutzer, die sich schon einmal angemeldet haben.

Für eine andere App sieht der Einbau so aus, direkt vor `</body>`:

```html
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"></script>
<script src="lizenz/config.js"></script>
<script src="lizenz/zugang.js"></script>
<script>
  Zugang.zugangPruefen().then(function (status) {
    // Ab hier ist der Zugang gültig. status.email, status.rolle, status.lizenz, status.gueltig_bis
    plattformStarten();
  });
</script>
```

Ohne gültigen Zugang liegt die Anmeldemaske über der Seite und `zugangPruefen()` wartet, bis die Anmeldung geklappt hat. Die Plattform muss nichts weiter tun.

Fortschritt statt direkt in localStorage:

```js
// speichern: lokal sofort, Server sobald online
Zugang.fortschrittSpeichern('uebung-3', { geloest: [1, 2], punkte: 14 });

// laden: nimmt automatisch den neueren Stand (lokal oder Server)
var stand = await Zugang.fortschrittLaden('uebung-3', { geloest: [], punkte: 0 });

// alles auf einmal, z.B. für die Übersicht
var alles = await Zugang.fortschrittAlle();

// abmelden
Zugang.abmelden().then(function () { location.reload(); });
```

**Bestehende Nutzer** verlieren nichts. In `config.js` unter `alteSchluessel` die bisherigen localStorage Schlüssel eintragen (oder ein Präfix unter `alteSchluesselPraefix`). Beim ersten erfolgreichen Login werden diese Daten einmalig in die Datenbank übernommen, ausser der Server hat unter diesem Schlüssel schon Daten.

**Offline:** Sitzung und Zugangsstatus liegen im Browser. Wer sich einmal angemeldet hat, kommt auch ohne Netz in die Plattform. Änderungen landen in einem Puffer und gehen raus, sobald der Browser wieder online ist. Nur die allererste Anmeldung braucht Internet.

## So funktioniert die Lizenzierung

- **Lizenz** = eine Charge Codes, z.B. `KVOST-2026-01` für eine Schule und ein Schuljahr, mit Ablaufdatum.
- **Code** = ein Sitz. Format `ABCD-EFGH-JKLM`, ohne I, O, 0 und 1. Wird beim ersten Login fest an eine E-Mail gebunden. Ein zweites Konto mit demselben Code ist nicht möglich.
- **Login danach**: dieselbe E-Mail plus derselbe Code, auf jedem Gerät. Der Code ist zugleich das Passwort.
- **Sperren**: einzelne Codes oder die ganze Lizenz. Wirkt sofort, auch das Speichern von Fortschritt ist dann serverseitig blockiert. Praktisch bei unbezahlten Rechnungen.
- **Ablauf**: `gueltig_bis` auf der Lizenz. Danach erscheint bei der Anmeldung der Hinweis, mit einem neuen Code geht es weiter, der Fortschritt bleibt erhalten.
- **Rollen**: `lernende` (Standard), `lehrperson` (Zugang ohne Code, sieht später Klassenfortschritt), `admin` (Konsole). Konto entsteht immer über einen Code, Rolle setzt du danach in der Konsole.

Verkaufsablauf: Angebot an die Schule, in der Konsole Lizenz anlegen mit Anzahl Sitzen und Ablaufdatum, CSV an die Schule, Schule verteilt die Codes. Fertig.

## Sicherheit

- Der Anon Key darf öffentlich sein. Jede Tabelle hat Row Level Security, Lernende sehen nur ihre eigenen Daten, nur Admins sehen Lizenzen und Codes.
- Codes haben 60 Bit Zufall, Durchprobieren ist aussichtslos.
- Weil die Mailbestätigung aus ist, kann jemand theoretisch eine fremde Mailadresse mit seinem eigenen Code registrieren. Schaden: null, der Code ist trotzdem verbraucht und die betroffene Person nimmt einfach eine andere Adresse. In der Konsole siehst du, wer welchen Code hat.

## Testen vor dem ersten Verkauf

Zwei Browserprofile (oder normal plus privates Fenster), zwei Codes:

1. Profil A: anmelden mit Code 1, in `demo.html` dreimal klicken.
2. Profil A: Flugmodus, weiterklicken, Seite neu laden. Stand bleibt, keine Anmeldemaske.
3. Profil A: Flugmodus aus, kurz warten. In der Konsole unter Benutzer erscheint eine Übung.
4. Profil B: gleiche Mail, gleicher Code. Stand ist da.
5. Profil B: abmelden, andere Mail mit Code 1. Wird abgelehnt.
6. Konsole: Code 1 sperren. Profil A neu laden: Anmeldemaske mit Hinweis.
