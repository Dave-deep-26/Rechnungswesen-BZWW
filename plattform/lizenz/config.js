// Supabase Projekt: Settings → API
// Beide Werte sind öffentlich (Anon Key), die Sicherheit liegt in den RLS Regeln der Datenbank.
window.ZUGANG_CONFIG = {
  url: 'https://DEIN-PROJEKT.supabase.co',
  anonKey: 'DEIN-ANON-KEY',
  titel: 'Finanzbuchhaltung Plattform',
  untertitel: 'finanzunterricht.ch',
  // localStorage Schlüssel der bisherigen Plattform, die beim ersten Login einmalig übernommen werden.
  // Genaue Namen oder ein Präfix. Leer lassen, wenn es nichts zu übernehmen gibt.
  alteSchluessel: [],
  alteSchluesselPraefix: ''
};
