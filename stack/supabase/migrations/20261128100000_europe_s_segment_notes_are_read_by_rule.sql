-- EUROPE'S SEGMENT NOTES ARE READ BY RULE (Phase 6c step 7, docs/specs/2026-11-26-more-segment-sources.md).
--
-- WHY. ESEF mandates detailed tagging of the primary statements only, so an annual financial
-- report carries no segment axis: the IFRS 8 note is one text block of HTML
-- (`ifrs-full:DisclosureOfEntitysReportableSegmentsExplanatory`). filings.xbrl.org serves every
-- indexed report as xBRL-JSON, and muffin-ingest's `segment_note` reads the note's tables against
-- the report's own tagged revenue, as it reads Japan's. Measured 2026-11-28 on nine reports in six
-- languages: L'Oréal's divisions, zones and product lines each add up to the 44,052.0 €m it tags,
-- LVMH, Schneider, Iberdrola, Inditex, Atlas Copco, Enel and ASML place a split, and Airbus
-- files a note with no table. Every pattern below changed a result on that gate.
--
-- THE REGULATOR AND THE PROVIDER ARE TWO CODES. `esef` is the regulator (`disclosure_source`,
-- `security_filer`, `filing_form`, `segment_parser`); `xbrl-org` is the provider every filing and
-- segment row names (`data_source`), below the national regulators in priority.
--
-- COVERAGE IS WHAT THE INDEX HOLDS, MEASURED 2026-11-26: the ten countries below. Germany and
-- Switzerland are not indexed, so no row names them: a German company is `none`, not `resolvable`.
--
-- Nothing here is enabled: `disclosure_source.esef` stays disabled until the lane has read a tiny
-- subset live, and a coverage row counts only for an enabled source (`security_disclosure`).
-- Idempotent. Guarded by tests/europe-s-segment-notes-are-read-by-rule.sql.

insert into market.data_source (code, name, priority)
values ('xbrl-org', 'filings.xbrl.org (ESEF annual financial reports)', 210)
on conflict (code) do nothing;

insert into market.filing_form (source_code, form_code, is_annual, carries_segments, kind)
values ('esef', 'AFR', true, true, 'accounts')
on conflict (source_code, form_code) do nothing;

insert into market.segment_axis (taxonomy, axis, kind, priority)
values ('esef', 'esef:segments', 'business', 90),
       ('esef', 'esef:products', 'product', 100),
       ('esef', 'esef:geography', 'geography', 50)
on conflict do nothing;

insert into market.segment_parser (regulator, version)
values ('esef', 1)
on conflict (regulator) do nothing;

insert into market.disclosure_coverage (source_code, country_iso2)
select 'esef', c from unnest(array['SE','GB','DK','NO','FI','FR','IT','BE','NL','ES']) c
on conflict do nothing;

update market.disclosure_source
   set note = 'Measured VIABLE 2026-11-28 through the segment note, not axes: ESEF tags the primary '
              'statements only and block-tags the IFRS 8 note, whose HTML tables filings.xbrl.org '
              'serves inside each report''s xBRL-JSON. Read against the report''s own tagged '
              'revenue: L''Oréal''s divisions, zones and product lines each add up to its '
              '44,052.0 €m; 8 of 9 sampled reports place a split. Germany and Switzerland are not '
              'indexed. Enabled once the lane is live.'
 where code = 'esef';

-- The vocabulary (muffin-ingest `tests/unit/esef_rules.py` mirrors these rows, and generated them).
insert into market.segment_note_rule (regulator, rule, pattern, role, priority) values
  ('esef', 'block', '^DisclosureOfEntitysReportableSegmentsExplanatory$', 'consolidated', 100),
  ('esef', 'block', '^DisclosureOfOperatingSegmentsExplanatory$', 'consolidated', 90),
  ('esef', 'heading', '(?i)(principaux|grands|importants|major|main|significant|largest|key|principales|importantes|större|stora|viktiga|principali)\s+(clients?|customers?|clientes|kunder|clienti)|clients? (principaux|importants)|single (external )?customer|un seul client|un único cliente|réconciliation|rapprochement|reconcil|conciliaci|avstämning|riconciliaz', 'skip', 60),
  ('esef', 'heading', '(?i)géograph|geograph|geográf|geografi|par zone|par région|by region|area geogr|áreas? geogr|områden|per area', 'geography', 40),
  ('esef', 'heading', '(?i)par métiers?\b|par produits?|par catégories? de produits?|by product|by category|product (line|categor)|por productos?|per prodotto|per categoria', 'product', 35),
  ('esef', 'heading', '(?i)sectori|secteur|segment|division|activit|negocio|settor|business line', 'business', 30),
  ('esef', 'concept', '^(Revenue|RevenueFromContractsWithCustomers)$', 'revenue', 100),
  ('esef', 'label', '(?i)^(ventes|chiffre d.affaires|revenus?|ingresos|ventas|intäkter|ricavi|omsætning|omsättning) (internes?|intra|inter|interna|interni|intersegment|entre)|^(internal|intersegment|inter-segment|interne|interna|interni|interna intäkter) |intragroupe|intra-groupe|entre segments|entre secteurs|mellan segment|(transactions with|from) other segments|inter-?segment (revenue|sales)', 'skip', 120),
  ('esef', 'label', '(?i)^[–-]?\s*(dont|of which|varav|de los cuales|de las cuales|di cui|heraf|hiervan)\b', 'subset', 125),
  ('esef', 'label', '(?i)^total (des |de los )?(divisions|secteurs|segments|segmentos|activités)|^total (reporting|reportable|operating) segments?|^sous-total|^subtotal|^summa segment', 'subtotal', 115),
  ('esef', 'label', '(?i)^(total|totaux|totales|total general|total groupe|total du groupe|groupe|gruppen|koncernen|total grupo|totale|totale gruppo|gruppo|consolidated|group|total group|konsolideret|koncern|summa|total consolidado|consolidado)$', 'total', 110),
  ('esef', 'label', '(?i)^(éliminations?|elimineringar|eliminaciones|eliminazioni|eliminations?|eliminering)\b|^(ajustes y eliminaciones|consolidation adjustments|inter-?seg ?mentos|intersegment(o|os)?|coûts des fonctions centrales.*|gruppgemensamma funktioner|other,? (eliminations?|adjustments?).*|operaci[oó]n(es)? discontinuadas?|discontinued operations?|activités abandonnées)$', 'adjustment', 105),
  ('esef', 'label', '(?i)^(chiffre d.affaires|ventes|ventes nettes|revenue|revenues|net sales|total net sales|sales|total revenue|total revenues|net revenue|ingresos|importe neto de la cifra de negocios|cifra de negocios|ventas|ventas a terceros|ingresos ordinarios|intäkter|intäkter från externa kunder|nettoomsättning|omsättning|ricavi|totale ricavi|omsætning|nettoomsætning|revenue from external customers|external revenue|external sales|ventes externes|ventes hors groupe|chiffre d.affaires (externe|hors groupe)|revenue and other income from third parties)$', 'revenue', 100),
  ('esef', 'label', '(?i)^(résultat d.exploitation|résultat opérationnel|operating (income|profit|result)|resultado de explotación|resultado operativo|rörelseresultat|risultato operativo|ebit|resultat af primær drift)$', 'operating_income', 90),
  ('esef', 'member', '(?i)^(europe|europa|amérique|america|americas|amériques|américa|nordamerika|asie|asia|asien|afrique|africa|afrika|moyen.orient|middle east|oceania|océanie|norden|nordic|nordics|emea|apac|latam)\b', 'geography', 100),
  ('esef', 'member', '(?i)^(france|españa|spain|espagne|italia|italy|sverige|sweden|united states|etats.unis|états.unis|estados unidos|usa|u\.s\.|chine|china|kina|japon|japan|reino unido|united kingdom|royaume.uni|brasil|brazil|brésil|méxico|mexico|deutschland|germany|allemagne|alemania|danmark|denmark|norge|norway|finland|suomi|nederland|netherlands|pays.bas|países bajos|portugal|india|inde)\b', 'geography', 100),
  ('esef', 'member', '(?i)rest of (the )?world|reste du monde|resto del mundo|övriga världen|resto del mondo|autres pays|other countries|^(rest|reste|resto|övriga|resten)\s+(of\s+|de\s+|du\s+|del\s+|av\s+)?(the\s+)?(europe|europa|asia|asie|world|monde|mundo|america|amérique|américa|norden|countries)', 'geography', 100),
  ('esef', 'member', '(?i)^(iberia|argentina|argentine|chile|chili|colombia|colombie|peru|pérou|canada|korea|south korea|corée|singapore|singapour|taiwan|taïwan|hong kong|australia|australie|switzerland|suisse|belgium|belgique|poland|pologne|turkey|turquie|russia|russie|central america|north america|south america|latin america|amérique (du nord|du sud|latine)|asie.pacifique|asia.pacific|western europe|europe de l.ouest|eastern europe|europe de l.est)\b', 'geography', 100)

on conflict (regulator, rule, pattern) do update
   set role = excluded.role, priority = excluded.priority;
