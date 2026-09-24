-- Run after `npm run seed -- --template cs4535` with psql -v ON_ERROR_STOP=1.
-- Everything, including fixture data and DDL used to construct legacy edge cases, rolls back.
BEGIN;
CREATE EXTENSION IF NOT EXISTS pgtap WITH SCHEMA extensions;
SET search_path = public, extensions;
SELECT plan(20);

CREATE TEMP TABLE group_test_context AS
SELECT c.id AS class_id, c.gradebook_id,
    (SELECT user_id FROM user_roles WHERE class_id = c.id AND role = 'instructor' LIMIT 1) AS instructor,
    (SELECT user_id FROM user_roles WHERE class_id = c.id AND role = 'student' LIMIT 1) AS student,
    (SELECT user_id FROM user_roles WHERE class_id = c.id AND role = 'grader' LIMIT 1) AS grader
FROM classes c WHERE c.name = 'CS 4535: Software Design & Delivery'
ORDER BY c.id DESC LIMIT 1;
GRANT SELECT ON group_test_context TO authenticated;
SELECT is((SELECT count(*)::int FROM group_test_context), 1, 'CS 4535 fixture exists');
SELECT ok(NOT EXISTS (
    SELECT 1 FROM gradebook_columns c JOIN group_test_context t USING (gradebook_id)
    WHERE c.group_id IS NULL
), 'every existing seeded column was backfilled');
CREATE TEMP TABLE original_memberships AS
SELECT id, group_id FROM gradebook_columns WHERE gradebook_id = (SELECT gradebook_id FROM group_test_context);
SELECT initialize_gradebook_column_groups((SELECT gradebook_id FROM group_test_context));
SELECT results_eq('SELECT id, group_id FROM gradebook_columns WHERE id IN (SELECT id FROM original_memberships) ORDER BY id',
                  'SELECT id, group_id FROM original_memberships ORDER BY id', 'bootstrap rerun preserves membership');

-- A separate gradebook has no users; it also tests isolation from a second course.
INSERT INTO classes (name, slug, term, time_zone) VALUES ('Group SQL fixture', 'group-sql-fixture', '202610', 'America/New_York');
CREATE TEMP TABLE other_context AS SELECT id AS class_id, gradebook_id FROM classes WHERE slug = 'group-sql-fixture';
GRANT SELECT ON other_context TO authenticated;
-- The class trigger creates a final column. Put the test sequence well after it.
INSERT INTO gradebook_columns (class_id, gradebook_id, name, slug, sort_order)
SELECT class_id, gradebook_id, slug, slug, pos FROM other_context CROSS JOIN
    (VALUES ('quiz-1', 100), ('quiz-2', 101), ('quiz-4', 103), ('attendance', 104),
            ('quiz-5', 105), ('assignment-lab-1', 106), ('assignment-lab-2', 107),
            ('assignment-final', 108)) AS fixtures(slug, pos);
-- Construct the missing-position legacy case without the existing reorder trigger closing it.
ALTER TABLE gradebook_columns DISABLE TRIGGER gradebook_columns_enforce_sort_order_tr;
UPDATE gradebook_columns c SET sort_order = f.pos FROM
    (VALUES ('quiz-1', 100), ('quiz-2', 101), ('quiz-4', 103), ('attendance', 104),
            ('quiz-5', 105), ('assignment-lab-1', 106), ('assignment-lab-2', 107),
            ('assignment-final', 108)) AS f(slug, pos), other_context t
WHERE c.gradebook_id = t.gradebook_id AND c.slug = f.slug;
ALTER TABLE gradebook_columns ENABLE TRIGGER gradebook_columns_enforce_sort_order_tr;
SELECT initialize_gradebook_column_groups((SELECT gradebook_id FROM other_context));
SELECT is((SELECT count(DISTINCT group_id)::int FROM gradebook_columns WHERE class_id = (SELECT class_id FROM other_context) AND slug IN ('quiz-1', 'quiz-2')), 1, 'adjacent quizzes share a group');
SELECT is((SELECT count(DISTINCT group_id)::int FROM gradebook_columns WHERE class_id = (SELECT class_id FROM other_context) AND slug LIKE 'quiz-%'), 3, 'gap and intervening family create separate Quiz groups');
SELECT is((SELECT count(DISTINCT group_id)::int FROM gradebook_columns WHERE class_id = (SELECT class_id FROM other_context) AND slug LIKE 'assignment-lab-%'), 1, 'assignment subtype is preserved');
SELECT is((SELECT g.name FROM gradebook_column_groups g JOIN gradebook_columns c ON c.group_id = g.id WHERE c.class_id = (SELECT class_id FROM other_context) AND c.slug = 'assignment-final'), 'Assignment', 'two-part assignment slug retains its legacy label');
SELECT throws_ok($$UPDATE gradebook_columns SET group_id = (SELECT min(id) FROM gradebook_column_groups WHERE gradebook_id = (SELECT gradebook_id FROM other_context)) WHERE id = (SELECT min(id) FROM original_memberships)$$,
    '23503', NULL, 'cross-course membership is rejected');
SELECT throws_ok($$INSERT INTO gradebook_column_groups (class_id, gradebook_id, name) SELECT a.class_id, b.gradebook_id, 'Invalid' FROM group_test_context a CROSS JOIN other_context b$$,
    '23503', NULL, 'group course must match its gradebook');
SELECT throws_ok($$DELETE FROM gradebook_column_groups WHERE id = (SELECT min(group_id) FROM original_memberships)$$,
    '23503', NULL, 'deleting a populated group cannot delete or orphan grades');
SELECT throws_ok($$INSERT INTO gradebook_column_groups (class_id, gradebook_id, name) SELECT class_id, gradebook_id, '  ' FROM group_test_context$$,
    '23514', NULL, 'blank group names are rejected');

-- Test real authenticated roles rather than service-role queries that bypass RLS.
SELECT set_config('request.jwt.claim.sub', (SELECT instructor::text FROM group_test_context), true);
SET LOCAL ROLE authenticated;
SELECT lives_ok($$INSERT INTO gradebook_column_groups (class_id, gradebook_id, name) SELECT class_id, gradebook_id, 'Instructor group' FROM group_test_context$$, 'instructor can create a group');
SELECT is((SELECT count(*)::int FROM gradebook_column_groups WHERE gradebook_id = (SELECT gradebook_id FROM other_context)), 0, 'instructor cannot read another course');
SELECT throws_ok($$INSERT INTO gradebook_column_groups (class_id, gradebook_id, name) SELECT class_id, gradebook_id, 'Forbidden' FROM other_context$$,
    '42501', NULL, 'instructor cannot write another course');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', (SELECT student::text FROM group_test_context), true);
SET LOCAL ROLE authenticated;
SELECT ok(EXISTS (SELECT 1 FROM gradebook_column_groups WHERE gradebook_id = (SELECT gradebook_id FROM group_test_context)), 'student can read their course groups');
SELECT throws_ok($$INSERT INTO gradebook_column_groups (class_id, gradebook_id, name) SELECT class_id, gradebook_id, 'Forbidden' FROM group_test_context$$,
    '42501', NULL, 'student cannot create groups');
WITH changed AS (UPDATE gradebook_column_groups SET name = 'Forbidden' WHERE gradebook_id = (SELECT gradebook_id FROM group_test_context) RETURNING id) SELECT is(count(*)::int, 0, 'student cannot update groups') FROM changed;
SELECT throws_ok($$SELECT initialize_gradebook_column_groups((SELECT gradebook_id FROM group_test_context))$$,
    '42501', NULL, 'course users cannot invoke bootstrap');
RESET ROLE;
SELECT set_config('request.jwt.claim.sub', (SELECT grader::text FROM group_test_context), true);
SET LOCAL ROLE authenticated;
SELECT ok(EXISTS (SELECT 1 FROM gradebook_column_groups WHERE gradebook_id = (SELECT gradebook_id FROM group_test_context)), 'grader can read course groups');
SELECT throws_ok($$INSERT INTO gradebook_column_groups (class_id, gradebook_id, name) SELECT class_id, gradebook_id, 'Forbidden' FROM group_test_context$$,
    '42501', NULL, 'grader cannot create groups');
RESET ROLE;
SELECT * FROM finish();
ROLLBACK;
