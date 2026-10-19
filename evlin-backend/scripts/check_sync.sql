-- What the phones sync, read straight from Supabase (SQL editor). Read-only.
-- Change the email (and the child's name where asked) in the first lines of
-- each query. "Today" is the child's day, from children.timezone (UTC when
-- it's not set yet), the same way the server decides it.
--
-- What a sync reads, and from where:
--   parent's profile      GET /auth/me                    app.parents
--   the children          GET /children                   app.children, app.parent_children
--   rules                 GET /children/{id}/rules        app.child_rules
--   lock state            GET /children/{id}/state        app.child_state
--   tasks                 GET /children/{id}/tasks        app.tasks
--   today's tasks         GET /children/{id}/occurrences  app.occurrences (made on read, one per task per day)
--   photos                GET /occurrences/{id}/submissions  app.submissions (files in R2)
--   time left today       GET /children/{id}/time-grants  app.time_grants + child_rules
--   app blocks            GET /children/{id}/app-blocks   app.app_blocks, app.apps
--   the lock, all in one  GET /children/{id}/policy       all of the above
--   calendar              GET /children/{id}/events       app.events
-- Tomorrow isn't stored anywhere: the phone works it out from the tasks'
-- repeat rules, as query 4 does.


-- 1. The family: the parent, each child, their timezone, their paired devices.
select p.email, c.name as child, c.id as child_id, c.timezone,
       (now() at time zone coalesce(c.timezone, 'UTC'))::date as childs_today,
       count(d.id) filter (where d.revoked_at is null) as paired_devices
from app.parents p
join app.parent_children pc on pc.parent_id = p.id
join app.children c on c.id = pc.child_id
left join app.devices d on d.child_id = c.id
where p.email = 'dashnyamesen@gmail.com'
group by p.email, c.name, c.id, c.timezone;


-- 2. Each child's rules and lock state (what the header and the kid's lock read).
select c.name as child, r.daily_limit_minutes, r.daily_limit_enabled,
       r.downtime_enabled, r.downtime_start, r.downtime_end,
       s.manual_lock, s.task_gate_override, s.updated_at as state_changed
from app.parents p
join app.parent_children pc on pc.parent_id = p.id
join app.children c on c.id = pc.child_id
left join app.child_rules r on r.child_id = c.id
left join app.child_state s on s.child_id = c.id
where p.email = 'dashnyamesen@gmail.com';


-- 3. TODAY's list, as the phone shows it: every task that falls on the
--    child's today, with today's occurrence (its status) if one exists yet.
--    occurrence_id empty = no device has asked for today yet.
with kid as (
  select c.id, c.name, (now() at time zone coalesce(c.timezone, 'UTC'))::date as day
  from app.parents p
  join app.parent_children pc on pc.parent_id = p.id
  join app.children c on c.id = pc.child_id
  where p.email = 'dashnyamesen@gmail.com'
), t as (
  select kid.name as child, kid.day, task.*,
         coalesce(task.due_date, (task.created_at at time zone 'UTC')::date) as start_day,
         coalesce(nullif(lower(trim(task.recurrence)), ''), 'none') as rec
  from kid join app.tasks task on task.child_id = kid.id
  where task.active
)
select t.child, t.day, t.title, t.due_time, t.rec as repeats, t.created_by,
       o.status, o.id as occurrence_id,
       (select count(*) from app.submissions s where s.occurrence_id = o.id) as photos
from t
left join app.occurrences o on o.task_id = t.id and o.due_date = t.day
where case
  when t.rec = 'none' then t.day = t.start_day
  when t.day < t.start_day - (case when t.due_date is null then 1 else 0 end) then false
  when t.rec = 'daily' then true
  when t.rec = 'weekly' then extract(isodow from t.day) = extract(isodow from t.start_day)
  else to_char(t.day, 'dy') = any(string_to_array(replace(t.rec, ' ', ''), ','))
end
order by t.child, t.due_time nulls first, t.created_at desc;


-- 4. TOMORROW's list: the same rule one day on. No occurrences yet (they're
--    made on the day), so this is just which tasks fall on it.
with kid as (
  select c.id, c.name, (now() at time zone coalesce(c.timezone, 'UTC'))::date + 1 as day
  from app.parents p
  join app.parent_children pc on pc.parent_id = p.id
  join app.children c on c.id = pc.child_id
  where p.email = 'dashnyamesen@gmail.com'
), t as (
  select kid.name as child, kid.day, task.*,
         coalesce(task.due_date, (task.created_at at time zone 'UTC')::date) as start_day,
         coalesce(nullif(lower(trim(task.recurrence)), ''), 'none') as rec
  from kid join app.tasks task on task.child_id = kid.id
  where task.active
)
select t.child, t.day, t.title, t.due_time, t.rec as repeats, t.created_by
from t
where case
  when t.rec = 'none' then t.day = t.start_day
  when t.day < t.start_day - (case when t.due_date is null then 1 else 0 end) then false
  when t.rec = 'daily' then true
  when t.rec = 'weekly' then extract(isodow from t.day) = extract(isodow from t.start_day)
  else to_char(t.day, 'dy') = any(string_to_array(replace(t.rec, ' ', ''), ','))
end
order by t.child, t.due_time nulls first, t.created_at desc;


-- 5. Every task the children have (all days), newest first: check a task
--    the phone just made arrived, with the id the phone gave it.
select c.name as child, task.id, task.title, task.recurrence, task.due_date, task.due_time,
       task.active, task.created_by, task.created_at
from app.parents p
join app.parent_children pc on pc.parent_id = p.id
join app.children c on c.id = pc.child_id
join app.tasks task on task.child_id = c.id
where p.email = 'dashnyamesen@gmail.com'
order by task.created_at desc
limit 50;


-- 6. Occurrences over the last week, by day and status: what approving,
--    sending back and the kid sending in did.
select c.name as child, o.due_date, task.title, o.status, o.completed_at, o.approved_at,
       o.rejection_note, o.bypass_requested
from app.parents p
join app.parent_children pc on pc.parent_id = p.id
join app.children c on c.id = pc.child_id
join app.occurrences o on o.child_id = c.id
join app.tasks task on task.id = o.task_id
where p.email = 'dashnyamesen@gmail.com'
  and o.due_date >= current_date - 7
order by o.due_date desc, task.title;


-- 7. Duplicates check: must return no rows (one occurrence per task per day).
select task_id, due_date, count(*), array_agg(status)
from app.occurrences
group by task_id, due_date
having count(*) > 1;


-- 8. Photos sent in, newest first (the file itself is in R2 under r2_key).
select c.name as child, task.title, o.due_date, s.kind, s.status, s.r2_key, s.created_at, s.uploaded_at
from app.parents p
join app.parent_children pc on pc.parent_id = p.id
join app.children c on c.id = pc.child_id
join app.occurrences o on o.child_id = c.id
join app.submissions s on s.occurrence_id = o.id
join app.tasks task on task.id = o.task_id
where p.email = 'dashnyamesen@gmail.com'
order by s.created_at desc
limit 30;


-- 9. Screen time today: the daily limit plus every grant and deduction
--    credited to the child's today.
with kid as (
  select c.id, c.name, (now() at time zone coalesce(c.timezone, 'UTC'))::date as day
  from app.parents p
  join app.parent_children pc on pc.parent_id = p.id
  join app.children c on c.id = pc.child_id
  where p.email = 'dashnyamesen@gmail.com'
)
select kid.name as child, kid.day, r.daily_limit_minutes,
       coalesce(sum(g.minutes), 0) as granted_today,
       r.daily_limit_minutes + coalesce(sum(g.minutes), 0) as available_today,
       string_agg(g.source || ' ' || g.minutes, ', ' order by g.created_at) as grants
from kid
left join app.child_rules r on r.child_id = kid.id
left join app.time_grants g on g.child_id = kid.id and g.credited_date = kid.day
group by kid.name, kid.day, r.daily_limit_minutes;


-- 10. App blocks still in force.
select c.name as child, b.app_name, b.block_type, b.duration_minutes, b.ends_at,
       b.schedule_days, b.schedule_start, b.schedule_end, b.created_at
from app.parents p
join app.parent_children pc on pc.parent_id = p.id
join app.children c on c.id = pc.child_id
join app.app_blocks b on b.child_id = c.id
where p.email = 'dashnyamesen@gmail.com' and not b.resolved
order by b.created_at desc;


-- 11. Calendar: events today and tomorrow (repeating ones that started
--     earlier are listed too, with their repeat rule), and kids' plans
--     waiting for an answer.
with kid as (
  select c.id, c.name, coalesce(c.timezone, 'UTC') as tz,
         (now() at time zone coalesce(c.timezone, 'UTC'))::date as day
  from app.parents p
  join app.parent_children pc on pc.parent_id = p.id
  join app.children c on c.id = pc.child_id
  where p.email = 'dashnyamesen@gmail.com'
)
select kid.name as child, e.title,
       (e.start_at at time zone kid.tz) as starts, (e.end_at at time zone kid.tz) as ends,
       e.recurrence, e.created_by, e.status, e.category
from kid
join app.events e on e.child_id = kid.id
where (e.start_at at time zone kid.tz)::date in (kid.day, kid.day + 1)
   or (coalesce(nullif(lower(e.recurrence), ''), 'none') <> 'none'
       and (e.start_at at time zone kid.tz)::date <= kid.day + 1)
   or e.status = 'proposed'
order by starts;
