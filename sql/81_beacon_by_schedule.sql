-- 81. 비콘 알림을 학생별 훈련 시각에 (2026-10-23 사용자: "비콘 알림을 학생별 훈련 시작·종료 시각에 맞춰")
-- 재실행해도 안전(create table if not exists / create or replace / cron 다시 등록).
--
--  전: 평일 09:00(입실)·16:00(퇴실) 한꺼번에(sql/78 send_beacon_reminders). 10월 정규시간은 07:30~13:00 시작, 10:00~18:00 종료로 제각각.
--  후: 10분마다 send_beacon_reminders_due() — 오늘 그 학생 OJT 정규시간(attendance_daily)의 시작 10분 전부터 입실,
--      종료 10분 전부터 퇴실 알림. 그래서 알림은 시작·종료 0~10분 전에 도착.
--      · 대상 조건은 sql/78 과 같음: 오늘 OJT 정규시간 있음 · 이번 달 인정 < 배정 · OJT 단계 · 진행중
--      · 한 사람·하루·종류(in/out)에 한 번 — beacon_reminder_log 로 중복 방지
--      · 시작·종료가 이미 1시간 넘게 지났으면 안 보냄(정규시간을 낮에 늦게 올린 날 아침 알림이 오후에 가지 않게)
--      · 정규시간 행이 하루 여러 개면 가장 이른 시작·가장 늦은 종료, 시각이 비면 09:00·16:00(옛 방식)
--  알림 글: 전에는 매번 센터 비콘 글을 통째로 지웠는데, 이제 학생마다 시각이 달라 '그 학생의 이전 비콘 글'만 지우고 새로 씀
--      (아직 발송 안 된 글은 건드리지 않음). 저녁 20:00 일괄 정리(beacon-clear-nightly, sql/51)는 그대로.
--  옛 09:00·16:00 크론(beacon-in-daily·beacon-out-daily)은 내림. send_beacon_reminders 함수는 남겨 둠(수동 발송용).

create table if not exists public.beacon_reminder_log (
  center_id uuid not null,
  day date not null,
  name text not null,
  kind text not null check (kind in ('in', 'out')),
  sent_at timestamptz not null default now(),
  primary key (center_id, day, name, kind)
);
alter table public.beacon_reminder_log enable row level security;
revoke all on public.beacon_reminder_log from anon, authenticated;

create or replace function public.send_beacon_reminders_due(p_now timestamptz default now())
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare
  v_local timestamp := p_now at time zone 'Asia/Seoul';
  v_today date := v_local::date;
  v_time time := v_local::time;
  v_month date := date_trunc('month', v_local)::date;
  v_notice uuid; total int := 0; k text; r record; c record; v_tok text; v_cnt int;
  v_title text; v_common text; v_body_fmt text;
begin
  -- 오래된 기록 정리(2주)
  delete from beacon_reminder_log where day < v_today - 14;

  foreach k in array array['in', 'out'] loop
    if k = 'out' then
      v_title := '퇴실 비콘 알림';
      v_common := '퇴근 전 퇴실 비콘 꼭 찍어주세요! 오늘도 수고했어요.';
      v_body_fmt := '퇴근 전 퇴실 비콘 꼭 찍어주세요! 이번 달 출석 진도 %s시간 / 배정 %s시간이에요.';
    else
      v_title := '입실 비콘 알림';
      v_common := '좋은 아침이에요! 출근하면 입실 비콘부터 찍어주세요.';
      v_body_fmt := '출근하면 입실 비콘부터 찍어주세요! 이번 달 출석 진도 %s시간 / 배정 %s시간이에요.';
    end if;

    for c in select id from centers where active order by created_at loop
      v_notice := null; v_cnt := 0;
      for r in
        with td as (   -- 오늘 학생별 정규시간(이른 시작·늦은 종료)
          select replace(trim(d.name), ' ', '') nk,
                 coalesce(min(d.start_time), time '09:00') st, coalesce(max(d.end_time), time '16:00') et
            from attendance_daily d
           where d.center_id = c.id and d.track = 'ojt' and d.day = v_today and d.planned_hours > 0
           group by 1
        )
        select a.name, s.phone, a.planned_hours, coalesce(a.actual_hours, 0) as actual_hours,
               case when k = 'in' then td.st else td.et end as at
          from attendance_monthly a
          join td on td.nk = replace(trim(a.name), ' ', '')
          join students s on s.center_id = a.center_id
           and replace(trim(s.name), ' ', '') = replace(trim(a.name), ' ', '')
         where a.center_id = c.id and a.month = v_month and a.track = 'ojt'
           and a.planned_hours > 0
           and coalesce(a.actual_hours, 0) < a.planned_hours
           and coalesce(student_phase(s.cohort, s.type1, s.phase_override, v_today), 'ojt') = 'ojt'
           and coalesce(s.status, '진행중') = '진행중'
           and s.phone is not null
           -- 시각 10분 전부터 ~ 1시간 지난 때까지
           and (case when k = 'in' then td.st else td.et end) - interval '10 minutes' <= v_time
           and v_time < (case when k = 'in' then td.st else td.et end) + interval '60 minutes'
           and not exists (select 1 from beacon_reminder_log l
                            where l.center_id = c.id and l.day = v_today and l.kind = k
                              and l.name = replace(trim(a.name), ' ', ''))
      loop
        v_tok := make_student_token(r.name, r.phone);
        -- 이 학생의 이전 비콘 글(이미 발송된 것)만 지움
        delete from notice_recipients nr
         where nr.student_token = v_tok
           and nr.notice_id in (select id from notices where created_by like 'auto:beacon%' and center_id = c.id and pushed);
        if v_notice is null then
          insert into notices (center_id, title, body, target_scope, published, created_by, pushed)
          values (c.id, v_title, v_common, 'personal', true, 'auto:beacon-' || k, false)
          returning id into v_notice;
        end if;
        insert into notice_recipients (notice_id, student_token, title, body, center_id)
        values (v_notice, v_tok, v_title, format(v_body_fmt, r.actual_hours::int, r.planned_hours::int), c.id);
        insert into beacon_reminder_log (center_id, day, name, kind)
        values (c.id, v_today, replace(trim(r.name), ' ', ''), k) on conflict do nothing;
        v_cnt := v_cnt + 1;
      end loop;
      total := total + v_cnt;
      -- 수신자가 다 빠진 옛 비콘 글 정리
      delete from notices n where n.center_id = c.id and n.created_by like 'auto:beacon%' and n.pushed
        and not exists (select 1 from notice_recipients nr where nr.notice_id = n.id);
    end loop;
  end loop;

  if total > 0 then
    begin
      perform net.http_get('https://ggitgqijycvnhhraxzgn.supabase.co/functions/v1/push-sender');
    exception when others then null;
    end;
  end if;
  return jsonb_build_object('ok', true, 'sent', total, 'at', to_char(v_local, 'YYYY-MM-DD HH24:MI'));
end $$;
revoke all on function public.send_beacon_reminders_due(timestamptz) from public, anon, authenticated;

-- 크론: 옛 09:00·16:00 내리고 10분마다(KST 07:00~20:50 = UTC 22~23, 0~11시)
select cron.unschedule(jobid) from cron.job where jobname in ('beacon-in-daily', 'beacon-out-daily', 'beacon-due');
select cron.schedule('beacon-due', '*/10 22,23,0-11 * * *', $$select public.send_beacon_reminders_due()$$);

-- 적용하는 날: 옛 크론으로 이미 나간 오늘 알림(09:00 입실, 16:00 퇴실)은 보낸 것으로 기록 — 같은 날 두 번 가지 않게
insert into public.beacon_reminder_log (center_id, day, name, kind)
select d.center_id, (now() at time zone 'Asia/Seoul')::date, replace(trim(d.name), ' ', ''), k.kind
  from public.attendance_daily d
  cross join (values ('in', time '09:00'), ('out', time '16:00')) as k(kind, at)
 where d.track = 'ojt' and d.planned_hours > 0 and d.day = (now() at time zone 'Asia/Seoul')::date
   and extract(isodow from now() at time zone 'Asia/Seoul') between 1 and 5
   and (now() at time zone 'Asia/Seoul')::time >= k.at
on conflict do nothing;
