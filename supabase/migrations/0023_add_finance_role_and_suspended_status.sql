-- A finance staff role, and the ability to suspend a listing instead of
-- deleting it. Split into its own migration: a newly added enum value
-- can't be referenced by anything else until it's committed.
alter type user_role add value 'finance';
alter type listing_status add value 'suspended';
