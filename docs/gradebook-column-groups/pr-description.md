This PR adds persistent column groups to the instructor gradebook. A migration creates course-scoped groups, backfills existing columns from their current display, and stores membership on each column. The instructor gradebook now reads that data for its headers, collapse controls, and drag helpers. The column editor can assign a column to an existing group or leave it ungrouped.

## Claimed band

**High Distinction.** Part two proposes a topic-and-attempt data model that the current columns cannot express, a topic evidence view alongside the flat gradebook, the migration and 500-student query costs, instructor setup effort, and the domain questions that need validation. The implementation also meets Pass: it adds the scoped schema and RLS, backfills existing columns, and reads persisted groups in the instructor gradebook.

## Part one: the design built

**What groups are for.** Groups let instructors scan related assessments and hide detail while comparing students. I treat a group as a named display unit within one gradebook. Each column belongs to one group or stays ungrouped. Separate groups can share a name, such as two “Quiz” groups.

**Who should validate it.** I would show the CS 4535 instructor the expanded and collapsed gradebook, including both Quiz groups and the expectation columns, then ask them to move a column. A TA could try to find one student's lab grades without knowing the slug rules. I have not interviewed them yet.

**Qualities I prioritized.** I kept the current display and made cross-course mistakes hard to express. A foreign key ties each group and column to the same course and gradebook. Instructors manage groups; course members can read their group names, while column policies still control grades. The UI loads groups once per gradebook and uses IDs so groups with the same name collapse separately.

**Tradeoffs.** I chose to preserve the old display instead of guessing what instructors intended. Sort-order gaps still split groups; `assignment-final` stays under “Assignment”; the three expectation columns stay separate. Empty slugs become “Other,” and ties use column ID. Groups appear where their first column appears, and dragging does not change membership. New columns start ungrouped and can be assigned to an existing group in the editor. There is no group creation or rename UI, and populated groups must be emptied before deletion.

## Part two: design for topic attempts

CS 2100 needs to show which attempts assess each topic. Some columns are also calculated from other columns. Display groups alone cannot capture those relationships, especially when one assessment covers several topics.

I would add course-scoped topics and attempts with stable IDs, dates, and optional assignment links. If each score measures one topic, a column can link directly to its topic and attempt. If a score can measure several topics, use a link table instead. Keep these links optional so other courses can keep using ordinary display groups.

Show a student-by-topic summary with the latest non-excused attempt and an attempt count. Expand a topic to see its attempts in order, and keep the flat gradebook for grading one assessment across students. Make the summary rule visible and configurable; latest, best, and consistency rules mean different things. Mark calculated columns as summaries and show their `dependencies`. That could display the skill columns beside the expectation aggregates, even though their slugs differ. Dependencies show what a formula uses, not which topic a column measures.

The migration should keep existing columns and scores, and leave uncertain topic mappings unset for instructors to review. A 500-student, 40-topic view has 20,000 summaries, so load details only when a topic is expanded and avoid a query per cell. Any cached summary must preserve overrides, release rules, and pending calculations. Index observations by topic and student. Measure the real query count and load time before adding cached summaries.

Setup should be per topic and assessment, not per student. A bulk import could suggest links for instructors to review; courses without repeated topic assessments would need no setup. I would ask the CS 2100 instructor and graders to check the topic mapping and summary rule, and ask students whether the summary explains their result. I would also check with a maintainer how dependencies, recalculation, and unreleased grades behave. Real course examples would help choose between direct links and a link table.

## Scope

This changes the instructor gradebook and its header/drag helpers. The student what-if view still uses its heuristic. The service-role-only bootstrap function is for the migration and seed/import conversion; it does nothing when groups already exist and is not attached to normal column writes. Run it after populating an otherwise ungrouped gradebook. Imports into an initialized gradebook must set membership explicitly.

## Validation

- A fresh local Supabase start applied migrations through `20260924120000`. `npm run client-local` regenerated both type files; this also repaired pre-existing metrics and Discord membership type drift.
- `npm run seed -- --template cs4535` created course 2 with 40 columns and 24 students. I checked the seeded labs, assignments, exams, Quiz runs, skills, expectation aggregates, attendance, AI logs, and singleton columns.
- `tests/sql/gradebook-column-groups.sql`: 20 database assertions passed for backfill, reruns, legacy gaps and assignment subtypes, course-scope constraints, populated-group deletion, and instructor/student/grader RLS. Its fixture changes roll back.
- I tested the down SQL and full migration against populated courses 1 and 2 in a rolled-back transaction. Column IDs, slugs, sort orders, scores, and overrides were preserved, and all existing columns were grouped.
- Production build passed. Both tests in `tests/e2e/gradebook-column-groups.spec.ts` passed in Chromium. I reviewed the expanded and collapsed screenshots; the second test checks independent collapse for duplicate group labels and live label updates.
- `npm run test:functions`: 350 tests passed. `npm run format` and `npm run lint` passed with existing lint warnings.
- `npx tsc --noEmit` reports eight errors in two unchanged test files. An untouched archive of the fork's HEAD reports the same errors; this change adds none.
- I did not run the full application E2E suite, WebKit, or a 500-student performance test.

## Down path

Export `gradebook_column_groups` and column memberships first if custom groupings need to be recovered. Deploy the previous instructor UI, then run [`rollback.sql`](./rollback.sql) during a maintenance window. It removes the bootstrap function, membership column and constraint, groups, and added gradebook uniqueness constraint; scores, formulas, sort orders, and grade columns remain. The old UI infers groups from slugs, so custom labels and memberships are lost unless exported. To undo a deployed migration, record this as a new forward migration. Regenerate both Supabase type files after rollback.
