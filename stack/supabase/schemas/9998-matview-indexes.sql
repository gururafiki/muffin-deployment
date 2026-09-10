-- Re-issued because DROPPING A MATVIEW LOSES ITS INDEXES. The unique one is not optional:
-- without it `refresh materialized view concurrently` is REJECTED, and every refresh then
-- takes ACCESS EXCLUSIVE on the relation every aggregate reads.
CREATE INDEX security_facets_app_reg_idx ON market.security_facets USING btree (app_region_id);
CREATE INDEX security_facets_cap_band_idx ON market.security_facets USING btree (cap_band);
CREATE INDEX security_facets_cap_usd_idx ON market.security_facets USING btree (market_cap_usd);
CREATE INDEX security_facets_country_idx ON market.security_facets USING btree (country_iso2);
CREATE INDEX security_facets_ftse_tier_idx ON market.security_facets USING btree (ftse_tier);
CREATE INDEX security_facets_income_idx ON market.security_facets USING btree (income_group);
CREATE INDEX security_facets_ind_code_idx ON market.security_facets USING btree (industry_code);
CREATE INDEX security_facets_industry_idx ON market.security_facets USING btree (industry);
CREATE INDEX security_facets_msci_reg_idx ON market.security_facets USING btree (msci_region);
CREATE INDEX security_facets_msci_tier_idx ON market.security_facets USING btree (msci_tier);
CREATE INDEX security_facets_sector_cap_idx ON market.security_facets USING btree (sector_id, market_cap_usd) WHERE (market_cap_usd > (0)::numeric);
CREATE INDEX security_facets_sector_idx ON market.security_facets USING btree (sector_id);
CREATE INDEX security_facets_style_idx ON market.security_facets USING btree (style);
CREATE INDEX security_facets_symbol_idx ON market.security_facets USING btree (symbol);
CREATE INDEX security_facets_type_idx ON market.security_facets USING btree (security_type_code);
CREATE INDEX security_facets_wb_region_idx ON market.security_facets USING btree (wb_region);
CREATE INDEX security_segment_spine_concept_idx ON market.security_segment_spine USING btree (concept_code) WHERE (concept_code IS NOT NULL);
CREATE INDEX security_segment_spine_kind_idx ON market.security_segment_spine USING btree (kind);
CREATE INDEX symbol_security_symbol_idx ON market.symbol_security USING btree (symbol);
CREATE UNIQUE INDEX security_facets_pk ON market.security_facets USING btree (security_id);
CREATE UNIQUE INDEX security_segment_spine_key_idx ON market.security_segment_spine USING btree (security_id, axis, member_code);
CREATE UNIQUE INDEX symbol_security_id_idx ON market.symbol_security USING btree (security_id);
