-- Deploy the previous instructor UI first. Export group rows and column memberships
-- before running: this intentionally discards presentation metadata, not scores.
BEGIN;
DROP FUNCTION public.initialize_gradebook_column_groups(bigint);
ALTER TABLE public.gradebook_columns DROP CONSTRAINT gradebook_columns_group_fkey;
ALTER TABLE public.gradebook_columns DROP COLUMN group_id;
DROP TABLE public.gradebook_column_groups;
ALTER TABLE public.gradebooks DROP CONSTRAINT gradebooks_id_class_id_key;
COMMIT;
