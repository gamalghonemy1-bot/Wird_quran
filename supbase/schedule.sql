-- 1) أنشئ bucket اسمه wird واجعله Public من لوحة Supabase.
-- 2) فعّل pg_cron و pg_net من Database > Extensions، ثم شغّل:
select cron.schedule(
  'sync-wird-daily',
  '30 21 * * *', -- 21:30 UTC = قبل منتصف الليل بتوقيت القاهرة، يبني ورد اليوم التالي
  $$
  select net.http_post(
    url := 'https://YOUR-PROJECT.supabase.co/functions/v1/sync-wird?date=' ||
           to_char((now() at time zone 'Africa/Cairo') + interval '1 day', 'YYYY-MM-DD'),
    headers := jsonb_build_object('Authorization', 'Bearer YOUR_SERVICE_ROLE_KEY')
  );
  $$
);
