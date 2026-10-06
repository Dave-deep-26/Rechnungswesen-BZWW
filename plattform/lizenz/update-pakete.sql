-- =====================================================================
-- Update: Pakete (eine Lizenz, mehrere Produkte)
-- Voraussetzung: update-produkte.sql wurde schon ausgeführt.
-- Supabase SQL Editor: komplett einfügen und ausführen.
-- Mehrfach ausführbar (idempotent).
--
-- lizenz.produkt darf jetzt eine Liste sein, z.B. 'fibu,bilanza'.
-- Ein Code aus so einer Lizenz gilt für alle aufgeführten Produkte,
-- mit derselben E-Mail und demselben Code.
-- Bestehende Lizenzen mit einem Produkt oder ohne Produkt (= alle) bleiben gleich.
-- =====================================================================

create or replace function public.lizenz_passt(p_lizenz_produkt text, p_produkt text)
returns boolean
language sql immutable
as $$
  select p_lizenz_produkt is null
      or p_produkt is null
      or p_produkt = any (string_to_array(replace(p_lizenz_produkt, ' ', ''), ','));
$$;

grant execute on function public.lizenz_passt(text, text) to anon, authenticated;

-- BZWW bekommt zusätzlich Zugang zur Bilanza App
update public.lizenz
   set produkt = 'fibu,bilanza'
 where bezeichnung = 'BZWW-HFW-2026';

-- Kontrolle
select bezeichnung, kunde, produkt, gueltig_bis from public.lizenz order by erstellt_am;

notify pgrst, 'reload schema';
