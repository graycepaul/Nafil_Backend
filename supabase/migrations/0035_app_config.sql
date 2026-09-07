-- Remote app-version gate. A single config row the client reads on every
-- launch (before requiring sign-in - an outdated app should be caught even
-- for someone who isn't logged in yet), so a forced update or a "there's a
-- newer version" nudge can go out without shipping a new build. Public read
-- (no auth) since it has to be checkable pre-login; there's nothing here
-- worth restricting anyway.

create table app_config (
  id boolean primary key default true check (id),
  min_supported_version text not null,
  latest_version text not null,
  update_message text,
  ios_store_url text,
  android_store_url text,
  updated_at timestamptz not null default now()
);

alter table app_config enable row level security;

create policy app_config_public_read on app_config for select using (true);

insert into app_config (id, min_supported_version, latest_version, android_store_url)
values (
  true,
  '1.0.1',
  '1.0.1',
  'https://play.google.com/store/apps/details?id=com.graycepaul.nafilestate'
);
