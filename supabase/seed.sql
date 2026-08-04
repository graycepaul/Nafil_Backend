-- ══════════════════════════════════════════════════════════════════════════
-- Nafil Estates — test seed data
--
-- Two estates, nine accounts covering every role plus every onboarding
-- state, and sample passes/issues/announcements so no screen opens empty.
--
-- Password for every account: NafilTest123!
--
-- Applied to project itfepppqjtodmizbglze. Safe to re-run — the cleanup
-- block below removes only the seeded rows (@nafil.test users and the two
-- fixed estate UUIDs), nothing else.
--
-- NOTE: this inserts into auth.users directly, which is fine for test data
-- but is not how you should create real accounts. Real signups go through
-- the app or the Supabase Admin API.
-- ══════════════════════════════════════════════════════════════════════════

-- ── Cleanup (idempotent re-run) ──────────────────────────────────────────
-- Estates first, deliberately: visitor_logs.security_id has no ON DELETE
-- action (plain RESTRICT), so deleting auth.users first — which cascades to
-- profiles — fails once a security profile has any visitor_logs row against
-- it. Deleting estates first cascades away visitor_passes/visitor_logs/
-- issues/announcements/estate_join_requests via their estate_id FKs, so by
-- the time auth.users is deleted there's nothing left to restrict it.
delete from estates where id in (
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222'
);
delete from auth.users where email like '%@nafil.test';

-- ── Estates ──────────────────────────────────────────────────────────────
insert into estates (id, name, address) values
  ('11111111-1111-1111-1111-111111111111', 'Nafil Gardens', '14 Adeola Odeku Street, Victoria Island, Lagos'),
  ('22222222-2222-2222-2222-222222222222', 'Nafil Heights', '7 Gana Street, Maitama, Abuja');

-- ── Auth users ───────────────────────────────────────────────────────────
-- bcrypt via pgcrypto; email pre-confirmed so login works immediately.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
  created_at, updated_at,
  confirmation_token, recovery_token, email_change_token_new, email_change
) values
  ('00000000-0000-0000-0000-000000000000','a0000000-0000-4000-8000-000000000001','authenticated','authenticated',
   'resident@nafil.test', crypt('NafilTest123!', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}','{"full_name":"Amaka Obi"}', now(), now(), '','','',''),

  ('00000000-0000-0000-0000-000000000000','a0000000-0000-4000-8000-000000000002','authenticated','authenticated',
   'resident2@nafil.test', crypt('NafilTest123!', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}','{"full_name":"Tunde Bakare"}', now(), now(), '','','',''),

  ('00000000-0000-0000-0000-000000000000','a0000000-0000-4000-8000-000000000003','authenticated','authenticated',
   'security@nafil.test', crypt('NafilTest123!', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}','{"full_name":"Musa Danjuma"}', now(), now(), '','','',''),

  ('00000000-0000-0000-0000-000000000000','a0000000-0000-4000-8000-000000000004','authenticated','authenticated',
   'admin@nafil.test', crypt('NafilTest123!', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}','{"full_name":"Chidinma Eze"}', now(), now(), '','','',''),

  ('00000000-0000-0000-0000-000000000000','a0000000-0000-4000-8000-000000000005','authenticated','authenticated',
   'superadmin@nafil.test', crypt('NafilTest123!', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}','{"full_name":"Ibrahim Yusuf"}', now(), now(), '','','',''),

  ('00000000-0000-0000-0000-000000000000','a0000000-0000-4000-8000-000000000006','authenticated','authenticated',
   'pending@nafil.test', crypt('NafilTest123!', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}','{"full_name":"Ngozi Okafor"}', now(), now(), '','','',''),

  ('00000000-0000-0000-0000-000000000000','b0000000-0000-4000-8000-000000000001','authenticated','authenticated',
   'heights@nafil.test', crypt('NafilTest123!', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}','{"full_name":"Fatima Bello"}', now(), now(), '','','',''),

  -- Brand-new signup: no phone, no join request. Should land on profile-setup.
  ('00000000-0000-0000-0000-000000000000','a0000000-0000-4000-8000-000000000007','authenticated','authenticated',
   'newresident@nafil.test', crypt('NafilTest123!', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}','{"full_name":"Blessing Chukwu"}', now(), now(), '','','',''),

  -- Profile complete, but their last join request was declined. Should land
  -- on the "request declined" state within pending-approval.
  ('00000000-0000-0000-0000-000000000000','a0000000-0000-4000-8000-000000000008','authenticated','authenticated',
   'rejected@nafil.test', crypt('NafilTest123!', gen_salt('bf')), now(),
   '{"provider":"email","providers":["email"]}','{"full_name":"Kelechi Uba"}', now(), now(), '','','','');

-- GoTrue expects one identity row per email user
insert into auth.identities (id, user_id, identity_data, provider, provider_id, last_sign_in_at, created_at, updated_at)
select
  gen_random_uuid(), u.id,
  jsonb_build_object('sub', u.id::text, 'email', u.email, 'email_verified', true, 'phone_verified', false),
  'email', u.id::text, now(), now(), now()
from auth.users u
where u.email like '%@nafil.test';

-- ── Profiles (rows auto-created by the signup trigger) ───────────────────
-- avatar_url points at i.pravatar.cc — a placeholder-avatar service made for
-- exactly this (stable per-seed photo, no real person's image or usage-rights
-- question). ?img=N pins a specific face rather than the random default.
update profiles set estate_id='11111111-1111-1111-1111-111111111111', role='resident', unit_no='B12', phone='+2348031234567', approved=true, avatar_url='https://i.pravatar.cc/300?img=47' where id='a0000000-0000-4000-8000-000000000001';
update profiles set estate_id='11111111-1111-1111-1111-111111111111', role='resident', unit_no='A04', phone='+2348039876543', approved=true, avatar_url='https://i.pravatar.cc/300?img=12' where id='a0000000-0000-4000-8000-000000000002';
update profiles set estate_id='11111111-1111-1111-1111-111111111111', role='security', phone='+2348051112222', approved=true, avatar_url='https://i.pravatar.cc/300?img=53' where id='a0000000-0000-4000-8000-000000000003';
update profiles set estate_id='11111111-1111-1111-1111-111111111111', role='admin',    phone='+2348064445555', approved=true, avatar_url='https://i.pravatar.cc/300?img=32' where id='a0000000-0000-4000-8000-000000000004';
update profiles set estate_id='11111111-1111-1111-1111-111111111111', role='super_admin', phone='+2348077778888', approved=true, avatar_url='https://i.pravatar.cc/300?img=68' where id='a0000000-0000-4000-8000-000000000005';
-- profile-complete, awaiting admin review — see the join request below
update profiles set phone='+2348099990000', approved=false, avatar_url='https://i.pravatar.cc/300?img=29' where id='a0000000-0000-4000-8000-000000000006';
update profiles set estate_id='22222222-2222-2222-2222-222222222222', role='resident', unit_no='H21', phone='+2348012223333', approved=true, avatar_url='https://i.pravatar.cc/300?img=44' where id='b0000000-0000-4000-8000-000000000001';
-- newresident@nafil.test: left untouched — no phone, no estate, unapproved, no avatar.
-- rejected@nafil.test: profile complete, but no estate — see the rejected request below.
update profiles set phone='+2348088889999', approved=false, avatar_url='https://i.pravatar.cc/300?img=15' where id='a0000000-0000-4000-8000-000000000008';

-- ── Estate join requests (the new onboarding model) ──────────────────────
insert into estate_join_requests (profile_id, estate_id, unit_no, status, created_at) values
  ('a0000000-0000-4000-8000-000000000006', '11111111-1111-1111-1111-111111111111', 'C09', 'pending', now() - interval '6 hours');

insert into estate_join_requests (profile_id, estate_id, unit_no, status, created_at, reviewed_at, reviewed_by) values
  ('a0000000-0000-4000-8000-000000000008', '22222222-2222-2222-2222-222222222222', 'H99', 'rejected', now() - interval '3 days', now() - interval '2 days', 'a0000000-0000-4000-8000-000000000004');

-- ── Visitor passes ───────────────────────────────────────────────────────
insert into visitor_passes (estate_id, resident_id, visitor_name, visitor_phone, vehicle_plate, code, status, valid_until) values
  ('11111111-1111-1111-1111-111111111111','a0000000-0000-4000-8000-000000000001','Emeka Nwosu','+2348023334444','LAG-234-KJA','NAF001','pending', now() + interval '2 days'),
  ('11111111-1111-1111-1111-111111111111','a0000000-0000-4000-8000-000000000001','DSTV Technician','+2348145556666', null, 'NAF002','pending', now() + interval '8 hours'),
  ('11111111-1111-1111-1111-111111111111','a0000000-0000-4000-8000-000000000002','Blessing Adeyemi','+2348067778888', null, 'NAF003','used',    now() + interval '1 day'),
  ('11111111-1111-1111-1111-111111111111','a0000000-0000-4000-8000-000000000002','Old Delivery','+2348011112222', null, 'NAF004','expired', now() - interval '1 day'),
  ('22222222-2222-2222-2222-222222222222','b0000000-0000-4000-8000-000000000001','Abuja Visitor','+2348033332222', null, 'NAF005','pending', now() + interval '1 day');

-- ── Visitor logs (one still on-site, one checked out) ────────────────────
insert into visitor_logs (estate_id, pass_id, security_id, visitor_name, vehicle_plate, method, checked_in_at, checked_out_at)
select '11111111-1111-1111-1111-111111111111', vp.id, 'a0000000-0000-4000-8000-000000000003',
       vp.visitor_name, vp.vehicle_plate, 'qr', now() - interval '3 hours', null
from visitor_passes vp where vp.code = 'NAF003';

insert into visitor_logs (estate_id, pass_id, security_id, visitor_name, vehicle_plate, method, checked_in_at, checked_out_at)
values ('11111111-1111-1111-1111-111111111111', null, 'a0000000-0000-4000-8000-000000000003',
        'Walk-in Contractor', 'LAG-887-ABC', 'manual', now() - interval '2 days', now() - interval '2 days' + interval '4 hours');

-- ── Issues (one per status) ──────────────────────────────────────────────
insert into issues (estate_id, resident_id, category, description, status, created_at, resolved_at) values
  ('11111111-1111-1111-1111-111111111111','a0000000-0000-4000-8000-000000000001','Plumbing','Persistent leak under the kitchen sink in B12.','open', now() - interval '2 days', null),
  ('11111111-1111-1111-1111-111111111111','a0000000-0000-4000-8000-000000000002','Electrical','Streetlight outside A04 has been out for a week.','in_progress', now() - interval '5 days', null),
  ('11111111-1111-1111-1111-111111111111','a0000000-0000-4000-8000-000000000001','Security','Back gate latch does not close properly.','resolved', now() - interval '14 days', now() - interval '10 days'),
  ('22222222-2222-2222-2222-222222222222','b0000000-0000-4000-8000-000000000001','Waste','Refuse collection missed this week.','open', now() - interval '1 day', null);

-- ── Announcements (incl. one emergency) ──────────────────────────────────
insert into announcements (estate_id, author_id, title, body, severity, created_at) values
  ('11111111-1111-1111-1111-111111111111','a0000000-0000-4000-8000-000000000004','Service charge due 5th August','Kindly settle Q3 service charge before the 5th to avoid late fees.','info', now() - interval '3 days'),
  ('11111111-1111-1111-1111-111111111111','a0000000-0000-4000-8000-000000000004','Estate AGM — Saturday 10am','Annual general meeting holds at the clubhouse. All owners are encouraged to attend.','info', now() - interval '1 day'),
  ('11111111-1111-1111-1111-111111111111','a0000000-0000-4000-8000-000000000003','Water supply interruption','Mains repair on Block B today between 2pm and 6pm. Please store water.','emergency', now() - interval '4 hours'),
  ('22222222-2222-2222-2222-222222222222','a0000000-0000-4000-8000-000000000005','Heights notice','Visible only to Nafil Heights residents.','info', now());
