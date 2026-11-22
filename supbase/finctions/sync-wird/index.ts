// يبني daily/<date>.json من ملفات الصوت في days/<date>/
// ارفع يومياً إلى bucket "wird" (Public) داخل days/YYYY-MM-DD/ :
//   ayat.mp3  (الآيات)   tafsir.mp3  (التفسير)   hadith.mp3  (الحديث)
// الامتدادات المدعومة: mp3 m4a ogg wav aac
import { createClient } from "npm:@supabase/supabase-js@2";

const TRACKS = [
  { key: "ayat", title: "الآيات" },
  { key: "tafsir", title: "التفسير" },
  { key: "hadith", title: "الحديث الشريف" },
];

Deno.serve(async (req) => {
  const sb = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );
  const date = new URL(req.url).searchParams.get("date") ??
    new Date(Date.now() + 2 * 3600e3).toISOString().slice(0, 10);
  const folder = `days/${date}`;
  const { data: files } = await sb.storage.from("wird").list(folder);
  const tracks = [];
  for (const t of TRACKS) {
    const f = files?.find((x) =>
      new RegExp(`^${t.key}\\.(mp3|m4a|ogg|wav|aac)$`, "i").test(x.name)
    );
    if (f) {
      const url = sb.storage.from("wird").getPublicUrl(`${folder}/${f.name}`).data.publicUrl;
      tracks.push({ ...t, url });
    }
  }
  if (tracks.length === 0) {
    return new Response(JSON.stringify({ error: "no audio files for " + date }), { status: 404 });
  }
  const body = JSON.stringify({ date, tracks });
  const { error } = await sb.storage.from("wird").upload(`daily/${date}.json`, body, {
    contentType: "application/json",
    upsert: true,
  });
  if (error) return new Response(error.message, { status: 500 });
  return new Response(body, { headers: { "content-type": "application/json" } });
});
