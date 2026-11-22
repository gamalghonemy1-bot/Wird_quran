# الورد اليومي (Flutter / Android)
1. أنشئ مستودع GitHub وارفع هذا المجلد كما هو، ثم أضف Secret باسم SUPABASE_URL (مثال: https://xxxx.supabase.co).
2. على Supabase: أنشئ bucket عام باسم wird، وانشر الدالة: supabase functions deploy sync-wird --no-verify-jwt، ثم شغّل supabase/schedule.sql.
3. ارفع يومياً إلى wird/days/YYYY-MM-DD/ ثلاثة ملفات صوتية: ayat.mp3 و tafsir.mp3 و hadith.mp3.
4. Actions > Build APK > حمّل wird-apk.
