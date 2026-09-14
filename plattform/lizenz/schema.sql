-- =====================================================================
-- Finanzbuchhaltung Plattform · Lizenz, Zugang, Fortschritt
-- Supabase SQL Editor: komplett einfügen und ausführen.
-- Mehrfach ausführbar (idempotent).
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- Tabellen
-- ---------------------------------------------------------------------

-- Ein Profil pro Auth Benutzer. Rolle steuert Admin und Lehrpersonen.
create table if not exists public.profil (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text not null,
  rolle        text not null default 'lernende'
               check (rolle in ('lernende', 'lehrperson', 'admin')),
  erstellt_am  timestamptz not null default now()
);

-- Eine Lizenz ist eine Charge Codes, z.B. eine Schule, eine Klasse, ein Jahr.
create table if not exists public.lizenz (
  id           uuid primary key default gen_random_uuid(),
  bezeichnung  text not null unique,          -- z.B. KVOST-2026-01
  kunde        text,                          -- z.B. KV Ostschweiz
  gueltig_bis  date,                          -- null = unbefristet
  gesperrt     boolean not null default false,
  notiz        text,
  erstellt_am  timestamptz not null default now(),
  erstellt_von uuid references public.profil(id) on delete set null
);

-- Ein Code = ein Sitz. Wird beim ersten Login an ein Konto gebunden.
create table if not exists public.code (
  code           text primary key,            -- Format ABCD-EFGH-JKLM
  lizenz_id      uuid not null references public.lizenz(id) on delete cascade,
  eingeloest_von uuid references public.profil(id) on delete set null,
  eingeloest_am  timestamptz,
  gesperrt       boolean not null default false,
  erstellt_am    timestamptz not null default now()
);
create index if not exists code_lizenz_idx on public.code (lizenz_id);
create index if not exists code_benutzer_idx on public.code (eingeloest_von);

-- Fortschritt pro Benutzer und Schlüssel (z.B. 'uebung-3'), Inhalt frei als JSON.
create table if not exists public.fortschritt (
  user_id         uuid not null references public.profil(id) on delete cascade,
  schluessel      text not null,
  daten           jsonb not null default '{}'::jsonb,
  aktualisiert_am timestamptz not null default now(),
  primary key (user_id, schluessel)
);

-- ---------------------------------------------------------------------
-- Profil automatisch anlegen, wenn ein Auth Benutzer entsteht
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profil (id, email)
  values (new.id, lower(new.email))
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- Hilfsfunktionen
-- ---------------------------------------------------------------------
create or replace function public.ist_admin()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profil where id = auth.uid() and rolle = 'admin'
  );
$$;

create or replace function public.ist_lehrperson()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.profil
    where id = auth.uid() and rolle in ('lehrperson', 'admin')
  );
$$;

-- Hat der angemeldete Benutzer aktuell Zugang?
-- Lehrpersonen und Admins immer. Lernende nur mit gültigem, nicht gesperrtem Code.
create or replace function public.hat_zugang()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select public.ist_lehrperson()
      or exists (
        select 1
        from public.code c
        join public.lizenz l on l.id = c.lizenz_id
        where c.eingeloest_von = auth.uid()
          and not c.gesperrt
          and not l.gesperrt
          and (l.gueltig_bis is null or l.gueltig_bis >= current_date)
      );
$$;

-- Eingabe säubern: Grossbuchstaben, nur erlaubte Zeichen, Bindestriche setzen.
create or replace function public.code_normalisieren(p_code text)
returns text
language sql immutable
as $$
  select case
           when length(s) = 12
             then substr(s, 1, 4) || '-' || substr(s, 5, 4) || '-' || substr(s, 9, 4)
           else s
         end
  from (
    select regexp_replace(upper(coalesce(p_code, '')), '[^A-Z2-9]', '', 'g') as s
  ) t;
$$;

-- Zufälliger Code ohne I, O, 0 und 1, damit sich beim Abtippen niemand vertut.
create or replace function public.code_generieren()
returns text
language plpgsql volatile
set search_path = public, extensions
as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';  -- 32 Zeichen
  b bytea := gen_random_bytes(12);
  s text := '';
  i int;
begin
  for i in 0..11 loop
    s := s || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  return substr(s, 1, 4) || '-' || substr(s, 5, 4) || '-' || substr(s, 9, 4);
end;
$$;

-- ---------------------------------------------------------------------
-- Admin: Codes erzeugen
-- Beispiel im SQL Editor:  select * from public.codes_erzeugen(300, 'KVOST-2026-01', 'KV Ostschweiz', '2027-07-31');
-- ---------------------------------------------------------------------
create or replace function public.codes_erzeugen(
  p_anzahl       int,
  p_bezeichnung  text,
  p_kunde        text default null,
  p_gueltig_bis  date default null
)
returns setof text
language plpgsql volatile security definer
set search_path = public, extensions
as $$
declare
  v_lizenz uuid;
  v_code   text;
  i        int;
begin
  if not public.ist_admin() then
    raise exception 'Nur Admins dürfen Codes erzeugen.';
  end if;
  if p_anzahl < 1 or p_anzahl > 5000 then
    raise exception 'Anzahl muss zwischen 1 und 5000 liegen.';
  end if;
  if coalesce(trim(p_bezeichnung), '') = '' then
    raise exception 'Bezeichnung fehlt.';
  end if;

  insert into public.lizenz (bezeichnung, kunde, gueltig_bis, erstellt_von)
  values (trim(p_bezeichnung), nullif(trim(p_kunde), ''), p_gueltig_bis, auth.uid())
  on conflict (bezeichnung) do update
    set kunde       = coalesce(excluded.kunde, public.lizenz.kunde),
        gueltig_bis = coalesce(excluded.gueltig_bis, public.lizenz.gueltig_bis)
  returning id into v_lizenz;

  for i in 1..p_anzahl loop
    loop
      v_code := public.code_generieren();
      begin
        insert into public.code (code, lizenz_id) values (v_code, v_lizenz);
        exit;
      exception when unique_violation then
        -- praktisch unmöglich, aber sauber abgefangen
        null;
      end;
    end loop;
    return next v_code;
  end loop;
end;
$$;

revoke execute on function public.codes_erzeugen(int, text, text, date) from anon;

-- ---------------------------------------------------------------------
-- Öffentlich: Code prüfen, bevor ein Konto angelegt wird
-- Antwort: status = frei | eigener | vergeben | ungueltig | gesperrt | abgelaufen
-- ---------------------------------------------------------------------
create or replace function public.code_pruefen(p_code text, p_email text)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  v_code   text := public.code_normalisieren(p_code);
  v_email  text := lower(trim(coalesce(p_email, '')));
  r        record;
  v_status text;
begin
  select c.code, c.gesperrt as code_gesperrt, c.eingeloest_von,
         l.bezeichnung, l.gueltig_bis, l.gesperrt as lizenz_gesperrt,
         p.email as inhaber_email
    into r
    from public.code c
    join public.lizenz l on l.id = c.lizenz_id
    left join public.profil p on p.id = c.eingeloest_von
   where c.code = v_code;

  if not found then
    return jsonb_build_object('status', 'ungueltig');
  end if;

  if r.code_gesperrt or r.lizenz_gesperrt then
    v_status := 'gesperrt';
  elsif r.gueltig_bis is not null and r.gueltig_bis < current_date then
    v_status := 'abgelaufen';
  elsif r.eingeloest_von is null then
    v_status := 'frei';
  elsif r.inhaber_email = v_email then
    v_status := 'eigener';
  else
    v_status := 'vergeben';
  end if;

  return jsonb_build_object(
    'status', v_status,
    'lizenz', r.bezeichnung,
    'gueltig_bis', r.gueltig_bis
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Angemeldet: Zugangsstatus abfragen
-- ---------------------------------------------------------------------
create or replace function public.zugang_status()
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  p  record;
  lz record;
begin
  if auth.uid() is null then
    return jsonb_build_object('angemeldet', false, 'aktiv', false, 'grund', 'nicht_angemeldet');
  end if;

  select * into p from public.profil where id = auth.uid();
  if not found then
    return jsonb_build_object('angemeldet', true, 'aktiv', false, 'grund', 'kein_profil');
  end if;

  select l.bezeichnung, l.kunde, l.gueltig_bis, c.code,
         (c.gesperrt or l.gesperrt) as gesperrt
    into lz
    from public.code c
    join public.lizenz l on l.id = c.lizenz_id
   where c.eingeloest_von = auth.uid()
   order by (not c.gesperrt and not l.gesperrt
             and (l.gueltig_bis is null or l.gueltig_bis >= current_date)) desc,
            c.eingeloest_am desc
   limit 1;

  return jsonb_build_object(
    'angemeldet',  true,
    'aktiv',       public.hat_zugang(),
    'rolle',       p.rolle,
    'email',       p.email,
    'user_id',     p.id,
    'lizenz',      lz.bezeichnung,
    'kunde',       lz.kunde,
    'code',        lz.code,
    'gueltig_bis', lz.gueltig_bis,
    'grund',       case
                     when public.hat_zugang() then null
                     when lz.code is null then 'kein_code'
                     when lz.gesperrt then 'gesperrt'
                     else 'abgelaufen'
                   end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Angemeldet: Code einlösen (bindet den Code an das eigene Konto)
-- ---------------------------------------------------------------------
create or replace function public.code_einloesen(p_code text)
returns jsonb
language plpgsql volatile security definer
set search_path = public
as $$
declare
  v_code text := public.code_normalisieren(p_code);
  r      record;
begin
  if auth.uid() is null then
    raise exception 'Nicht angemeldet.';
  end if;

  select c.code, c.gesperrt as code_gesperrt, c.eingeloest_von,
         l.gueltig_bis, l.gesperrt as lizenz_gesperrt
    into r
    from public.code c
    join public.lizenz l on l.id = c.lizenz_id
   where c.code = v_code
   for update of c;

  if not found then
    raise exception 'Diesen Code gibt es nicht.';
  end if;
  if r.code_gesperrt or r.lizenz_gesperrt then
    raise exception 'Dieser Code ist gesperrt.';
  end if;
  if r.gueltig_bis is not null and r.gueltig_bis < current_date then
    raise exception 'Die Lizenz zu diesem Code ist abgelaufen.';
  end if;
  if r.eingeloest_von is not null and r.eingeloest_von <> auth.uid() then
    raise exception 'Dieser Code ist bereits vergeben.';
  end if;

  if r.eingeloest_von is null then
    update public.code
       set eingeloest_von = auth.uid(), eingeloest_am = now()
     where code = v_code;
  end if;

  return public.zugang_status();
end;
$$;

revoke execute on function public.code_einloesen(text) from anon;

-- ---------------------------------------------------------------------
-- Angemeldet: Fortschritt speichern (mehrere Schlüssel auf einmal)
-- Ein älterer Stand überschreibt nie einen neueren (Mehrgerätebetrieb).
-- Eingabe: [{"schluessel":"uebung-1","daten":{...},"aktualisiert_am":"2026-..."}]
-- ---------------------------------------------------------------------
create or replace function public.fortschritt_speichern(p_eintraege jsonb)
returns int
language plpgsql volatile security definer
set search_path = public
as $$
declare
  n int := 0;
  e jsonb;
begin
  if auth.uid() is null then
    raise exception 'Nicht angemeldet.';
  end if;
  if not public.hat_zugang() then
    raise exception 'Kein gültiger Zugang.';
  end if;

  for e in select * from jsonb_array_elements(coalesce(p_eintraege, '[]'::jsonb)) loop
    insert into public.fortschritt (user_id, schluessel, daten, aktualisiert_am)
    values (
      auth.uid(),
      e->>'schluessel',
      coalesce(e->'daten', '{}'::jsonb),
      coalesce((e->>'aktualisiert_am')::timestamptz, now())
    )
    on conflict (user_id, schluessel) do update
      set daten           = excluded.daten,
          aktualisiert_am = excluded.aktualisiert_am
      where public.fortschritt.aktualisiert_am <= excluded.aktualisiert_am;
    n := n + 1;
  end loop;
  return n;
end;
$$;

revoke execute on function public.fortschritt_speichern(jsonb) from anon;

-- ---------------------------------------------------------------------
-- Admin: Übersicht pro Lizenz
-- ---------------------------------------------------------------------
create or replace view public.lizenz_uebersicht
with (security_invoker = true)
as
select l.id, l.bezeichnung, l.kunde, l.gueltig_bis, l.gesperrt, l.notiz, l.erstellt_am,
       count(c.code)                         as codes_total,
       count(c.eingeloest_von)               as codes_eingeloest,
       count(c.code) filter (where c.gesperrt) as codes_gesperrt
  from public.lizenz l
  left join public.code c on c.lizenz_id = l.id
 group by l.id;

-- ---------------------------------------------------------------------
-- Row Level Security
-- ---------------------------------------------------------------------
alter table public.profil      enable row level security;
alter table public.lizenz      enable row level security;
alter table public.code        enable row level security;
alter table public.fortschritt enable row level security;

-- profil
drop policy if exists profil_eigenes_lesen on public.profil;
create policy profil_eigenes_lesen on public.profil
  for select using (id = auth.uid() or public.ist_lehrperson());

drop policy if exists profil_admin_aendern on public.profil;
create policy profil_admin_aendern on public.profil
  for update using (public.ist_admin()) with check (public.ist_admin());

-- lizenz
drop policy if exists lizenz_admin_alles on public.lizenz;
create policy lizenz_admin_alles on public.lizenz
  for all using (public.ist_admin()) with check (public.ist_admin());

-- code
drop policy if exists code_admin_alles on public.code;
create policy code_admin_alles on public.code
  for all using (public.ist_admin()) with check (public.ist_admin());

drop policy if exists code_eigene_lesen on public.code;
create policy code_eigene_lesen on public.code
  for select using (eingeloest_von = auth.uid());

-- fortschritt
drop policy if exists fortschritt_eigener_lesen on public.fortschritt;
create policy fortschritt_eigener_lesen on public.fortschritt
  for select using (user_id = auth.uid() or public.ist_lehrperson());

drop policy if exists fortschritt_eigener_schreiben on public.fortschritt;
create policy fortschritt_eigener_schreiben on public.fortschritt
  for insert with check (user_id = auth.uid() and public.hat_zugang());

drop policy if exists fortschritt_eigener_aendern on public.fortschritt;
create policy fortschritt_eigener_aendern on public.fortschritt
  for update using (user_id = auth.uid()) with check (user_id = auth.uid() and public.hat_zugang());

drop policy if exists fortschritt_eigener_loeschen on public.fortschritt;
create policy fortschritt_eigener_loeschen on public.fortschritt
  for delete using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
grant usage on schema public to anon, authenticated;
grant select on public.profil, public.code, public.fortschritt, public.lizenz, public.lizenz_uebersicht to authenticated;
grant insert, update, delete on public.fortschritt to authenticated;
grant insert, update, delete on public.lizenz, public.code to authenticated;   -- RLS erlaubt das nur Admins
grant update on public.profil to authenticated;                                -- RLS erlaubt das nur Admins
grant execute on function public.code_pruefen(text, text) to anon, authenticated;
grant execute on function public.zugang_status() to authenticated;
grant execute on function public.code_einloesen(text) to authenticated;
grant execute on function public.fortschritt_speichern(jsonb) to authenticated;
grant execute on function public.codes_erzeugen(int, text, text, date) to authenticated;

-- =====================================================================
-- Nach dem ersten eigenen Login (mit irgendeinem Code) einmalig ausführen:
--   update public.profil set rolle = 'admin' where email = 'davide@finanzunterricht.ch';
-- =====================================================================
