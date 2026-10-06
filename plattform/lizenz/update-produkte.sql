-- =====================================================================
-- Update: Lizenzen pro Produkt (fibu, siu-m4, bilanza, ...)
-- Passt die Datenbank an die aktuelle zugang.js / admin.html an,
-- die überall p_produkt mitschicken.
-- Supabase SQL Editor: komplett einfügen und ausführen.
-- Mehrfach ausführbar (idempotent). Bestehende Daten bleiben unverändert.
-- Lizenzen ohne Produkt (produkt = null) gelten weiterhin für alle Plattformen.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Spalte Produkt
-- ---------------------------------------------------------------------
alter table public.lizenz add column if not exists produkt text;

-- ---------------------------------------------------------------------
-- Alte Funktionen ohne p_produkt entfernen (sonst Konflikt beim Aufruf)
-- ---------------------------------------------------------------------
drop function if exists public.code_einloesen(text);
drop function if exists public.code_pruefen(text, text);
drop function if exists public.zugang_status();
drop function if exists public.codes_erzeugen(int, text, text, date);

-- Gilt eine Lizenz für dieses Produkt?
create or replace function public.lizenz_passt(p_lizenz_produkt text, p_produkt text)
returns boolean
language sql immutable
as $$
  select p_lizenz_produkt is null or p_produkt is null or p_lizenz_produkt = p_produkt;
$$;

-- ---------------------------------------------------------------------
-- Admin: Codes erzeugen
-- ---------------------------------------------------------------------
create or replace function public.codes_erzeugen(
  p_anzahl       int,
  p_bezeichnung  text,
  p_kunde        text default null,
  p_gueltig_bis  date default null,
  p_produkt      text default null
)
returns setof text
language plpgsql volatile security definer
set search_path = public
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

  insert into public.lizenz (bezeichnung, kunde, gueltig_bis, produkt, erstellt_von)
  values (trim(p_bezeichnung), nullif(trim(p_kunde), ''), p_gueltig_bis, nullif(trim(p_produkt), ''), auth.uid())
  on conflict (bezeichnung) do update
    set kunde       = coalesce(excluded.kunde, public.lizenz.kunde),
        gueltig_bis = coalesce(excluded.gueltig_bis, public.lizenz.gueltig_bis),
        produkt     = coalesce(excluded.produkt, public.lizenz.produkt)
  returning id into v_lizenz;

  for i in 1..p_anzahl loop
    loop
      v_code := public.code_generieren();
      begin
        insert into public.code (code, lizenz_id) values (v_code, v_lizenz);
        exit;
      exception when unique_violation then
        null;
      end;
    end loop;
    return next v_code;
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- Öffentlich: Code prüfen
-- status = frei | eigener | vergeben | ungueltig | gesperrt | abgelaufen | falsches_produkt
-- ---------------------------------------------------------------------
create or replace function public.code_pruefen(p_code text, p_email text, p_produkt text default null)
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
         l.bezeichnung, l.gueltig_bis, l.gesperrt as lizenz_gesperrt, l.produkt,
         p.email as inhaber_email
    into r
    from public.code c
    join public.lizenz l on l.id = c.lizenz_id
    left join public.profil p on p.id = c.eingeloest_von
   where c.code = v_code;

  if not found then
    return jsonb_build_object('status', 'ungueltig');
  end if;

  if not public.lizenz_passt(r.produkt, p_produkt) then
    v_status := 'falsches_produkt';
  elsif r.code_gesperrt or r.lizenz_gesperrt then
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
    'produkt', r.produkt,
    'gueltig_bis', r.gueltig_bis
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Angemeldet: Zugangsstatus für ein Produkt
-- ---------------------------------------------------------------------
create or replace function public.zugang_status(p_produkt text default null)
returns jsonb
language plpgsql stable security definer
set search_path = public
as $$
declare
  p       record;
  lz      record;
  v_aktiv boolean;
  v_andere boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('angemeldet', false, 'aktiv', false, 'grund', 'nicht_angemeldet');
  end if;

  select * into p from public.profil where id = auth.uid();
  if not found then
    return jsonb_build_object('angemeldet', true, 'aktiv', false, 'grund', 'kein_profil');
  end if;

  select l.bezeichnung, l.kunde, l.gueltig_bis, l.produkt, c.code,
         (c.gesperrt or l.gesperrt) as gesperrt,
         (not c.gesperrt and not l.gesperrt
          and (l.gueltig_bis is null or l.gueltig_bis >= current_date)) as gueltig
    into lz
    from public.code c
    join public.lizenz l on l.id = c.lizenz_id
   where c.eingeloest_von = auth.uid()
     and public.lizenz_passt(l.produkt, p_produkt)
   order by (not c.gesperrt and not l.gesperrt
             and (l.gueltig_bis is null or l.gueltig_bis >= current_date)) desc,
            c.eingeloest_am desc
   limit 1;

  v_aktiv := public.ist_lehrperson() or coalesce(lz.gueltig, false);

  select exists (
    select 1 from public.code c
    join public.lizenz l on l.id = c.lizenz_id
    where c.eingeloest_von = auth.uid()
  ) into v_andere;

  return jsonb_build_object(
    'angemeldet',  true,
    'aktiv',       v_aktiv,
    'rolle',       p.rolle,
    'email',       p.email,
    'user_id',     p.id,
    'lizenz',      lz.bezeichnung,
    'kunde',       lz.kunde,
    'produkt',     lz.produkt,
    'code',        lz.code,
    'gueltig_bis', lz.gueltig_bis,
    'grund',       case
                     when v_aktiv then null
                     when lz.code is null and v_andere then 'anderes_produkt'
                     when lz.code is null then 'kein_code'
                     when lz.gesperrt then 'gesperrt'
                     else 'abgelaufen'
                   end
  );
end;
$$;

-- ---------------------------------------------------------------------
-- Angemeldet: Code einlösen
-- ---------------------------------------------------------------------
create or replace function public.code_einloesen(p_code text, p_produkt text default null)
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
         l.gueltig_bis, l.gesperrt as lizenz_gesperrt, l.produkt
    into r
    from public.code c
    join public.lizenz l on l.id = c.lizenz_id
   where c.code = v_code
   for update of c;

  if not found then
    raise exception 'Diesen Code gibt es nicht.';
  end if;
  if not public.lizenz_passt(r.produkt, p_produkt) then
    raise exception 'Dieser Code gilt für ein anderes Angebot.';
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

  return public.zugang_status(p_produkt);
end;
$$;

-- ---------------------------------------------------------------------
-- Admin: Übersicht pro Lizenz (Produkt am Ende ergänzt)
-- ---------------------------------------------------------------------
create or replace view public.lizenz_uebersicht
with (security_invoker = true)
as
select l.id, l.bezeichnung, l.kunde, l.gueltig_bis, l.gesperrt, l.notiz, l.erstellt_am,
       count(c.code)                           as codes_total,
       count(c.eingeloest_von)                 as codes_eingeloest,
       count(c.code) filter (where c.gesperrt) as codes_gesperrt,
       l.produkt
  from public.lizenz l
  left join public.code c on c.lizenz_id = l.id
 group by l.id;

-- ---------------------------------------------------------------------
-- Rechte
-- ---------------------------------------------------------------------
grant select on public.lizenz_uebersicht to authenticated;
revoke execute on function public.codes_erzeugen(int, text, text, date, text) from anon, public;
revoke execute on function public.code_einloesen(text, text) from anon, public;
revoke execute on function public.zugang_status(text) from anon, public;
grant execute on function public.lizenz_passt(text, text) to anon, authenticated;
grant execute on function public.code_pruefen(text, text, text) to anon, authenticated;
grant execute on function public.zugang_status(text) to authenticated;
grant execute on function public.code_einloesen(text, text) to authenticated;
grant execute on function public.codes_erzeugen(int, text, text, date, text) to authenticated;

-- Supabase API sofort über die neuen Funktionen informieren
notify pgrst, 'reload schema';
