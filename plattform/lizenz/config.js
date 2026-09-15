// Supabase Projekt: Settings → API
// Beide Werte sind öffentlich (Anon Key), die Sicherheit liegt in den RLS Regeln der Datenbank.
window.ZUGANG_CONFIG = {
  url: 'https://yhdfgtwjjfpzywjybpsi.supabase.co',
  anonKey: 'sb_publishable_RViaIRbvkrU3CRlsWDLIgg_CN4v0Yza',
  produkt: 'fibu',
  titel: 'Finanzbuchhaltung Übungsplattform',
  untertitel: 'finanzunterricht.ch',
  // localStorage Schlüssel der bisherigen Plattform, die beim ersten Login einmalig übernommen werden.
  // Genaue Namen oder ein Präfix. Leer lassen, wenn es nichts zu übernehmen gibt.
  alteSchluessel: ['finanzbuchhaltung-plattform-v2'],
  alteSchluesselPraefix: ''
};
